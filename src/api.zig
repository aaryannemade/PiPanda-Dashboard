//! HTTP API consumed by the dashboard frontend.
//!
//! The server binds and serves immediately, even with no stored credentials.
//! Authentication happens over the API (see the `/api/v1/auth/*` routes), which
//! mirror the CLI login state machine in `main.zig`. Once a token and a selected
//! printer exist, a supervisor task establishes the live printer session and the
//! dashboard endpoints start returning real data.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const printer = @import("bambu/printer.zig");
const cloud = @import("bambu/cloud.zig");
const credentials = @import("bambu/credentials.zig");
const homeassistant = @import("homeassistant.zig");
const log = @import("log.zig");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    printer_name: []const u8 = "Panda",
    printer_model: []const u8 = "P1S",
    camera_url: []const u8 = "http://127.0.0.1:1984/stream.html?src=p1s&mode=webrtc",
    /// Talk to the printer directly instead of via the cloud once logged in.
    lan: bool = false,
    /// Printer address for LAN mode, from `$PIPANDA_PRINTER_HOST`.
    printer_host: ?[]const u8 = null,
};

/// A login in progress that could not complete in one step. The frontend holds
/// the opaque flow id and posts the follow-up (code or authenticator digits).
const PendingLogin = struct {
    /// `verify_code` accounts get an emailed/texted code; `tfa` accounts use an
    /// authenticator app.
    kind: enum { verify_code, tfa },
    account: []const u8,
    region: cloud.Region,
    /// Only set for `tfa`.
    tfa_key: ?[]const u8 = null,

    fn deinit(self: *PendingLogin, gpa: Allocator) void {
        gpa.free(self.account);
        if (self.tfa_key) |key| gpa.free(key);
    }
};

/// The plate render and slicing profile for the current job.
///
/// Neither is in the printer's MQTT document. Both come from the cloud task
/// record, whose `cover` URL is presigned and expires after 30 minutes, so the
/// image is downloaded once per job and served from memory for as long as that
/// job is on the bed. One 512x512 PNG is roughly 35 KB.
const Thumbnail = struct {
    /// Job name this cache was filled for. A change is what triggers a refresh.
    job: ?[]u8 = null,
    bytes: ?[]u8 = null,
    content_type: []const u8 = "application/octet-stream",
    /// `/api/v1/job/thumbnail?v=<task id>`. Versioned so a new print busts the
    /// browser cache while an unchanged one is never re-fetched.
    url: ?[]u8 = null,
    profile: ?[]u8 = null,
    /// ETag value including quotes, matching `url`'s version.
    etag: ?[]u8 = null,
    /// Ticks to wait before retrying after a failed lookup, so a printer that
    /// is offline or an account with no history does not cause a cloud request
    /// every tick for the rest of the print.
    retry_in: u32 = 0,

    fn clear(self: *Thumbnail, gpa: Allocator) void {
        if (self.job) |v| gpa.free(v);
        if (self.bytes) |v| gpa.free(v);
        if (self.url) |v| gpa.free(v);
        if (self.profile) |v| gpa.free(v);
        if (self.etag) |v| gpa.free(v);
        self.* = .{};
    }
};

/// Everything the server needs to run the printer session and to log in. The
/// session pointer and the pending login are both mutable at runtime and are
/// guarded by `auth_mutex`.
const Context = struct {
    gpa: Allocator,
    io: Io,
    options: Options,
    store: credentials.Store,
    online: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    auth_mutex: Io.Mutex = .init,
    /// The live printer session, or null until credentials exist and a session
    /// has been established. Owned here.
    session: ?*printer.Session = null,
    /// A one-shot login arena/flow. `null` when there is no login in progress.
    pending: ?PendingLogin = null,
    /// Set by the supervisor when credentials appear so it can (re)connect.
    session_wanted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Guards `thumb`. Never held across a network call: the refresh task does
    /// its cloud IO unlocked and takes this only to swap the result in.
    thumb_mutex: Io.Mutex = .init,
    thumb: Thumbnail = .{},

    /// Serializes config mutation and bounds expensive `/api/states` fetches to
    /// one at a time. Without this, several open tabs can each allocate an
    /// 8 MiB HA response tree concurrently on the 512 MiB Pi.
    ha_mutex: Io.Mutex = .init,

    fn lockAuth(self: *Context) void {
        self.auth_mutex.lock(self.io) catch {};
    }
    fn unlockAuth(self: *Context) void {
        self.auth_mutex.unlock(self.io);
    }

    fn lockThumb(self: *Context) void {
        self.thumb_mutex.lock(self.io) catch {};
    }
    fn unlockThumb(self: *Context) void {
        self.thumb_mutex.unlock(self.io);
    }

    fn lockHa(self: *Context) void {
        self.ha_mutex.lock(self.io) catch {};
    }
    fn unlockHa(self: *Context) void {
        self.ha_mutex.unlock(self.io);
    }
};

pub fn serve(
    gpa: Allocator,
    io: Io,
    store: credentials.Store,
    options: Options,
) !void {
    const address = try Io.net.IpAddress.parse(options.host, options.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var context: Context = .{
        .gpa = gpa,
        .io = io,
        .options = options,
        .store = store,
    };
    defer {
        context.lockAuth();
        if (context.session) |session| session.close();
        if (context.pending) |*p| p.deinit(gpa);
        context.unlockAuth();
        context.lockThumb();
        context.thumb.clear(gpa);
        context.unlockThumb();
    }

    // If a token and a printer are already on disk, ask the supervisor to bring
    // the session up straight away; otherwise it idles until login completes.
    if (hasStoredSession(&context)) context.session_wanted.store(true, .release);

    var tasks: Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, superviseSession, .{&context});

    std.log.info("dashboard API listening on http://{s}:{d}", .{ options.host, options.port });
    while (true) {
        const stream = try listener.accept(io);
        tasks.concurrent(io, accept, .{ &context, stream }) catch |err| {
            stream.close(io);
            return err;
        };
    }
}

/// True when the store holds a token and a selected printer, i.e. enough to
/// connect without any further interaction.
fn hasStoredSession(context: *Context) bool {
    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const creds = context.store.load(arena_state.allocator()) catch return false;
    return creds.device_id != null;
}

/// Owns the printer session lifecycle. Waits until a session is wanted, connects
/// from the stored credentials, then runs keepalive and the status pump until
/// the connection drops, and loops.
fn superviseSession(context: *Context) void {
    while (true) {
        while (!context.session_wanted.load(.acquire)) {
            // Nothing to do until someone logs in and selects a printer.
            sleepMs(context.io, 250) catch return;
        }

        const session = connectFromStore(context) catch |err| {
            std.log.warn("could not establish printer session: {t}", .{err});
            context.online.store(false, .release);
            // Back off before retrying so a bad token does not spin.
            sleepMs(context.io, 2_000) catch return;
            continue;
        };

        context.lockAuth();
        if (context.session) |old| old.close();
        context.session = session;
        context.unlockAuth();
        context.online.store(true, .release);
        std.log.info("printer session established", .{});

        runSession(context, session);

        // The session dropped. Detach it so requests stop using a dead pointer.
        context.online.store(false, .release);
        context.lockAuth();
        if (context.session == session) {
            context.session = null;
            session.close();
        }
        context.unlockAuth();

        // Retry only if credentials still describe a printer.
        if (!hasStoredSession(context)) context.session_wanted.store(false, .release);
        sleepMs(context.io, 2_000) catch return;
    }
}

/// Sleeps for `ms` milliseconds, propagating cancellation.
fn sleepMs(io: Io, ms: u64) Io.Cancelable!void {
    const duration: Io.Duration = .{ .nanoseconds = @intCast(ms * std.time.ns_per_ms) };
    try io.sleep(duration, .awake);
}

/// Runs keepalive and the pump for one session until either stops.
fn runSession(context: *Context, session: *printer.Session) void {
    var group: Io.Group = .init;
    defer group.cancel(context.io);

    group.concurrent(context.io, keepAliveLoop, .{ context, session }) catch return;
    group.concurrent(context.io, thumbnailLoop, .{ context, session }) catch return;
    // The pump runs inline so this returns as soon as the stream stops.
    while (true) _ = session.pump() catch |err| {
        if (err != error.Canceled) std.log.err("printer status stream stopped: {t}", .{err});
        return;
    };
}

fn keepAliveLoop(context: *Context, session: *printer.Session) void {
    session.keepAlive() catch |err| {
        if (err != error.Canceled) std.log.err("printer keepalive stopped: {t}", .{err});
    };
    _ = context;
}

/// How often the job name is compared against the cached thumbnail's.
const thumbnail_tick_ms = 5_000;
/// Ticks to wait after a failed lookup before trying that job again.
const thumbnail_retry_ticks = 12;

/// Keeps the cached plate render in step with whatever the printer is doing.
///
/// Polling the job name is nearly free (a mutex and a string compare); the
/// cloud is only consulted when the name actually changes, which is once per
/// print. The alternative — resolving the cover inside the dashboard handler —
/// would put a cloud round trip in the path of a request the frontend makes
/// every second.
fn thumbnailLoop(context: *Context, session: *printer.Session) void {
    while (true) {
        refreshThumbnail(context, session) catch |err| {
            if (err == error.Canceled) return;
        };
        sleepMs(context.io, thumbnail_tick_ms) catch return;
    }
}

fn refreshThumbnail(context: *Context, session: *printer.Session) !void {
    const gpa = context.gpa;

    const job = try session.subtaskName(gpa);
    defer if (job) |name| gpa.free(name);

    // Decide whether there is anything to do while holding the lock briefly.
    // A job that has gone away leaves the last print's thumbnail in place: the
    // dashboard keeps showing what came off the bed, which is what Handy does.
    context.lockThumb();
    const current = job orelse {
        context.unlockThumb();
        return;
    };
    if (context.thumb.job) |cached| {
        if (std.mem.eql(u8, cached, current)) {
            context.unlockThumb();
            return;
        }
    }
    if (context.thumb.retry_in > 0) {
        context.thumb.retry_in -= 1;
        context.unlockThumb();
        return;
    }
    // A *different* job is starting, so whatever is cached belongs to the
    // previous print. Drop it now rather than risk rendering the last print's
    // plate against this print's name if the lookup below fails.
    context.thumb.clear(gpa);
    context.unlockThumb();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No credentials is the normal state for a LAN-only install that never
    // logged in. It is not an error, but it does mean no thumbnail.
    const creds = context.store.load(arena) catch return;
    const device_id = creds.device_id orelse return;

    var client: cloud.Client = .init(gpa, context.io, creds.region);
    defer client.deinit();

    const task = client.latestTask(arena, creds.access_token, device_id) catch |err| {
        log.debug("thumbnail: task lookup failed: {t}", .{err});
        return backOffThumbnail(context);
    } orelse {
        // The account has no history for this printer: nothing to fetch, and
        // nothing that retrying will fix until the job changes again.
        log.debug("thumbnail: no cloud task for the current job", .{});
        return backOffThumbnail(context);
    };

    const bytes = client.downloadCover(arena, task.cover_url) catch |err| {
        log.debug("thumbnail: cover download failed: {t}", .{err});
        return backOffThumbnail(context);
    };

    // Allocated outside the arena so they outlive this call.
    const owned_bytes = try gpa.dupe(u8, bytes);
    errdefer gpa.free(owned_bytes);
    const owned_job = try gpa.dupe(u8, current);
    errdefer gpa.free(owned_job);
    const owned_profile: ?[]u8 = if (jobProfile(task, current)) |p| try gpa.dupe(u8, p) else null;
    errdefer if (owned_profile) |v| gpa.free(v);
    const url = try std.fmt.allocPrint(gpa, "/api/v1/job/thumbnail?v={d}", .{task.id});
    errdefer gpa.free(url);
    const etag = try std.fmt.allocPrint(gpa, "\"{d}\"", .{task.id});

    context.lockThumb();
    defer context.unlockThumb();
    context.thumb.clear(gpa);
    context.thumb = .{
        .job = owned_job,
        .bytes = owned_bytes,
        .content_type = cloud.imageContentType(owned_bytes) orelse "application/octet-stream",
        .url = url,
        .profile = owned_profile,
        .etag = etag,
    };
    std.log.info("job thumbnail cached: task {d}, {d} bytes", .{ task.id, owned_bytes.len });
}

/// The subtitle shown under the job name.
///
/// The task's `title` is normally the job name repeated verbatim, which would
/// render the same string twice, so the model name is preferred and anything
/// matching the job name is dropped.
fn jobProfile(task: cloud.Client.Task, job_name: []const u8) ?[]const u8 {
    const candidate = if (task.design_title.len != 0) task.design_title else task.title;
    if (candidate.len == 0) return null;
    if (std.mem.eql(u8, std.mem.trim(u8, candidate, " "), std.mem.trim(u8, job_name, " "))) return null;
    return candidate;
}

fn backOffThumbnail(context: *Context) void {
    context.lockThumb();
    defer context.unlockThumb();
    context.thumb.retry_in = thumbnail_retry_ticks;
}

/// Connects a fresh session from whatever is on disk. Caller owns the result.
fn connectFromStore(context: *Context) !*printer.Session {
    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const creds = try context.store.load(arena);
    const device_id = creds.device_id orelse return error.NoPrinterSelected;

    // The device id has to outlive the arena; the session keeps a reference.
    const owned_device_id = try context.gpa.dupe(u8, device_id);
    errdefer context.gpa.free(owned_device_id);

    if (!context.options.lan) {
        return printer.Session.connect(context.gpa, context.io, owned_device_id, .{ .cloud = .{
            .region = creds.region,
            .username = try context.gpa.dupe(u8, creds.mqtt_username),
            .access_token = try context.gpa.dupe(u8, creds.access_token),
        } });
    }

    const access_code = creds.device_access_code orelse return error.NoAccessCode;
    const host = context.options.printer_host orelse return error.NoPrinterHost;
    return printer.Session.connect(context.gpa, context.io, owned_device_id, .{ .lan = .{
        .host = try context.gpa.dupe(u8, host),
        .access_code = try context.gpa.dupe(u8, access_code),
    } });
}

fn accept(context: *Context, stream: Io.net.Stream) void {
    defer stream.close(context.io);

    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var conn_reader = stream.reader(context.io, &recv_buffer);
    var conn_writer = stream.writer(context.io, &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.warn("invalid HTTP request: {t}", .{err});
                return;
            },
        };
        serveRequest(&request, context) catch |err| {
            // Reading a request body invalidates the parsed header strings.
            std.log.warn("HTTP request failed: {t}", .{err});
            return;
        };
    }
}

const Route = enum {
    health,
    dashboard,
    raw_state,
    job_thumbnail,
    camera,
    light,
    auth_status,
    auth_login,
    auth_code,
    auth_tfa,
    auth_devices,
    auth_select,
    auth_logout,
    ha_config,
    ha_test,
    ha_disconnect,
    ha_entities,
    ha_control,
    unknown,
};

fn route(target: []const u8) Route {
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
    if (std.mem.eql(u8, path, "/api/v1/health")) return .health;
    if (std.mem.eql(u8, path, "/api/v1/dashboard")) return .dashboard;
    if (std.mem.eql(u8, path, "/api/v1/printer/state")) return .raw_state;
    if (std.mem.eql(u8, path, "/api/v1/job/thumbnail")) return .job_thumbnail;
    if (std.mem.eql(u8, path, "/api/v1/camera")) return .camera;
    if (std.mem.eql(u8, path, "/api/v1/controls/light")) return .light;
    if (std.mem.eql(u8, path, "/api/v1/auth/status")) return .auth_status;
    if (std.mem.eql(u8, path, "/api/v1/auth/login")) return .auth_login;
    if (std.mem.eql(u8, path, "/api/v1/auth/code")) return .auth_code;
    if (std.mem.eql(u8, path, "/api/v1/auth/tfa")) return .auth_tfa;
    if (std.mem.eql(u8, path, "/api/v1/auth/devices")) return .auth_devices;
    if (std.mem.eql(u8, path, "/api/v1/auth/select")) return .auth_select;
    if (std.mem.eql(u8, path, "/api/v1/auth/logout")) return .auth_logout;
    if (std.mem.eql(u8, path, "/api/v1/integrations/homeassistant")) return .ha_config;
    if (std.mem.eql(u8, path, "/api/v1/integrations/homeassistant/test")) return .ha_test;
    if (std.mem.eql(u8, path, "/api/v1/integrations/homeassistant/disconnect")) return .ha_disconnect;
    if (std.mem.eql(u8, path, "/api/v1/integrations/homeassistant/entities")) return .ha_entities;
    if (std.mem.eql(u8, path, "/api/v1/integrations/homeassistant/control")) return .ha_control;
    return .unknown;
}

fn serveRequest(request: *std.http.Server.Request, context: *Context) !void {
    // A POST carrying neither Content-Length nor Transfer-Encoding has an empty
    // body (RFC 9110 §8.6). std's Server does not accept that implicitly: if a
    // handler answers such a request without reading the body first, its
    // `discardBody` hits `assert(transfer_encoding != .none or content_length
    // != null)` and panics the whole daemon. Browsers always send
    // `Content-Length: 0`, but `curl -X POST` does not, so saying the length out
    // loud here is what keeps a hand-driven request from killing the server.
    if (request.head.method.requestHasBody() and
        request.head.transfer_encoding == .none and
        request.head.content_length == null)
    {
        request.head.content_length = 0;
    }

    if (request.head.method == .OPTIONS) {
        return request.respond("", .{
            .status = .no_content,
        });
    }

    switch (route(request.head.target)) {
        .health => {
            if (request.head.method != .GET and request.head.method != .HEAD)
                return methodNotAllowed(request, "GET, HEAD, OPTIONS");
            const online = context.online.load(.acquire);
            const body = try std.json.Stringify.valueAlloc(context.gpa, .{
                .status = if (online) "ok" else "degraded",
                .printer_online = online,
            }, .{});
            defer context.gpa.free(body);
            return respondJson(request, body, .ok);
        },
        .dashboard => {
            if (request.head.method != .GET and request.head.method != .HEAD)
                return methodNotAllowed(request, "GET, HEAD, OPTIONS");
            return serveDashboard(request, context);
        },
        .raw_state => {
            if (request.head.method != .GET and request.head.method != .HEAD)
                return methodNotAllowed(request, "GET, HEAD, OPTIONS");
            return serveRawState(request, context);
        },
        .job_thumbnail => {
            if (request.head.method != .GET and request.head.method != .HEAD)
                return methodNotAllowed(request, "GET, HEAD, OPTIONS");
            return serveThumbnail(request, context);
        },
        .camera => {
            if (request.head.method != .GET and request.head.method != .HEAD)
                return methodNotAllowed(request, "GET, HEAD, OPTIONS");
            const body = try std.json.Stringify.valueAlloc(context.gpa, .{
                .available = context.options.camera_url.len != 0,
                .player_url = if (context.options.camera_url.len == 0)
                    @as(?[]const u8, null)
                else
                    context.options.camera_url,
                .stream_name = "p1s",
                .transport = "webrtc",
            }, .{});
            defer context.gpa.free(body);
            return respondJson(request, body, .ok);
        },
        .light => {
            if (request.head.method != .POST)
                return methodNotAllowed(request, "POST, OPTIONS");
            return setLight(request, context);
        },
        .auth_status => {
            if (request.head.method != .GET and request.head.method != .HEAD)
                return methodNotAllowed(request, "GET, HEAD, OPTIONS");
            return authStatus(request, context);
        },
        .auth_login => {
            if (request.head.method != .POST)
                return methodNotAllowed(request, "POST, OPTIONS");
            return authLogin(request, context);
        },
        .auth_code => {
            if (request.head.method != .POST)
                return methodNotAllowed(request, "POST, OPTIONS");
            return authCode(request, context);
        },
        .auth_tfa => {
            if (request.head.method != .POST)
                return methodNotAllowed(request, "POST, OPTIONS");
            return authTfa(request, context);
        },
        .auth_devices => {
            if (request.head.method != .GET and request.head.method != .HEAD)
                return methodNotAllowed(request, "GET, HEAD, OPTIONS");
            return authDevices(request, context);
        },
        .auth_select => {
            if (request.head.method != .POST)
                return methodNotAllowed(request, "POST, OPTIONS");
            return authSelect(request, context);
        },
        .auth_logout => {
            if (request.head.method != .POST)
                return methodNotAllowed(request, "POST, OPTIONS");
            return authLogout(request, context);
        },
        .ha_config => switch (request.head.method) {
            .GET, .HEAD => return haConfig(request, context),
            .POST => return haSave(request, context),
            else => return methodNotAllowed(request, "GET, HEAD, POST, OPTIONS"),
        },
        .ha_test => {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST, OPTIONS");
            return haTest(request, context);
        },
        .ha_disconnect => {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST, OPTIONS");
            return haDisconnect(request, context);
        },
        .ha_entities => {
            if (request.head.method != .GET and request.head.method != .HEAD)
                return methodNotAllowed(request, "GET, HEAD, OPTIONS");
            return haEntities(request, context);
        },
        .ha_control => {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST, OPTIONS");
            return haControl(request, context);
        },
        .unknown => return respondError(request, .not_found, "not_found", "endpoint not found"),
    }
}

fn serveDashboard(request: *std.http.Server.Request, context: *Context) !void {
    context.lockAuth();
    const session = context.session;
    context.unlockAuth();

    const active = session orelse
        return respondError(request, .service_unavailable, "not_connected", "not logged in or no printer selected");

    // Held across the projection so the refresh task cannot free these strings
    // mid-serialisation. Both critical sections are free of IO, so this cannot
    // stall: the cloud fetch happens before the refresh task takes the lock.
    context.lockThumb();
    defer context.unlockThumb();

    const body = try active.dashboardJson(context.gpa, .{
        .device_id = active.device_id,
        .name = context.options.printer_name,
        .model = context.options.printer_model,
        .camera_url = context.options.camera_url,
        .online = context.online.load(.acquire),
        .thumbnail_url = context.thumb.url,
        .job_profile = context.thumb.profile,
    });
    defer context.gpa.free(body);
    return respondJson(request, body, .ok);
}

/// Serves the cached plate render. The bytes are copied out under the lock so a
/// slow client cannot hold up the refresh task while the response drains.
fn serveThumbnail(request: *std.http.Server.Request, context: *Context) !void {
    context.lockThumb();
    const cached = context.thumb.bytes;
    const content_type = context.thumb.content_type;
    const body = if (cached) |bytes| try context.gpa.dupe(u8, bytes) else null;
    const etag = if (context.thumb.etag) |tag| try context.gpa.dupe(u8, tag) else null;
    context.unlockThumb();

    defer if (body) |b| context.gpa.free(b);
    defer if (etag) |e| context.gpa.free(e);

    const bytes = body orelse return respondError(
        request,
        .not_found,
        "no_thumbnail",
        "no plate render for the current job",
    );

    const tag = etag orelse "";
    if (requestHeader(request, "if-none-match")) |candidate| {
        if (tag.len != 0 and std.mem.eql(u8, candidate, tag)) {
            return request.respond("", .{
                .status = .not_modified,
                .extra_headers = &.{
                    .{ .name = "etag", .value = tag },
                    .{ .name = "cache-control", .value = thumbnail_cache_control },
                },
            });
        }
    }

    return request.respond(bytes, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            // The URL carries the task id, so a cached copy is only ever valid
            // for the print it was fetched for.
            .{ .name = "cache-control", .value = thumbnail_cache_control },
            .{ .name = "etag", .value = tag },
        },
    });
}

const thumbnail_cache_control = "public, max-age=86400, immutable";

fn requestHeader(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn hasJsonContentType(request: *std.http.Server.Request) bool {
    const raw = requestHeader(request, "content-type") orelse return false;
    const media_type = std.mem.trim(
        u8,
        raw[0 .. std.mem.indexOfScalar(u8, raw, ';') orelse raw.len],
        " \t",
    );
    return std.ascii.eqlIgnoreCase(media_type, "application/json");
}

fn serveRawState(request: *std.http.Server.Request, context: *Context) !void {
    context.lockAuth();
    const session = context.session;
    context.unlockAuth();

    const active = session orelse
        return respondError(request, .service_unavailable, "not_connected", "not logged in or no printer selected");

    const body = try active.statusJson(context.gpa);
    defer context.gpa.free(body);
    return respondJson(request, body, .ok);
}

const LightBody = struct {
    on: ?bool = null,
    mode: ?printer.Session.LedMode = null,
};

fn parseLightBody(arena: Allocator, body: []const u8) !printer.Session.LedMode {
    const value = std.json.parseFromSliceLeaky(LightBody, arena, body, .{
        .ignore_unknown_fields = false,
    }) catch return error.InvalidBody;
    if (value.mode) |mode| return mode;
    if (value.on) |on| return if (on) .on else .off;
    return error.InvalidBody;
}

fn setLight(request: *std.http.Server.Request, context: *Context) !void {
    const body = readBody(request, context, 1024) catch |err| return switch (err) {
        error.BodyTooLarge => respondErrorClose(request, .payload_too_large, "body_too_large", "request body exceeds 1 KiB"),
        else => respondErrorClose(request, .bad_request, "invalid_body", "could not read request body"),
    };
    defer context.gpa.free(body);

    var arena: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena.deinit();
    const mode = parseLightBody(arena.allocator(), body) catch
        return respondError(request, .unprocessable_entity, "invalid_body", "expected {\"on\":true} or {\"mode\":\"on|off|flashing\"}");

    context.lockAuth();
    const session = context.session;
    context.unlockAuth();

    const active = session orelse
        return respondError(request, .service_unavailable, "not_connected", "not logged in or no printer selected");

    active.setChamberLight(mode) catch
        return respondError(request, .service_unavailable, "printer_unavailable", "could not publish light command");
    const response = try std.json.Stringify.valueAlloc(context.gpa, .{
        .accepted = true,
        .mode = @tagName(mode),
    }, .{});
    defer context.gpa.free(response);
    return respondJson(request, response, .accepted);
}

// --- Authentication -------------------------------------------------------

/// Reports whether the server is authenticated and whether a printer is
/// selected, so the settings page can render the right state on load.
fn authStatus(request: *std.http.Server.Request, context: *Context) !void {
    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    context.lockAuth();
    const pending_kind: ?[]const u8 = if (context.pending) |p| switch (p.kind) {
        .verify_code => "code",
        .tfa => "tfa",
    } else null;
    const connected = context.session != null;
    context.unlockAuth();

    const maybe_creds: ?credentials.Credentials = context.store.load(arena) catch null;
    const authenticated = maybe_creds != null;

    const body = try std.json.Stringify.valueAlloc(context.gpa, .{
        .authenticated = authenticated,
        .account = if (maybe_creds) |c| c.account else null,
        .device_id = if (maybe_creds) |c| c.device_id else null,
        .device_selected = if (maybe_creds) |c| c.device_id != null else false,
        .connected = connected,
        .online = context.online.load(.acquire),
        .pending = pending_kind,
    }, .{});
    defer context.gpa.free(body);
    return respondJson(request, body, .ok);
}

const LoginBody = struct {
    account: []const u8,
    password: ?[]const u8 = null,
    region: ?[]const u8 = null,
    /// Skip the password and go straight to the emailed/texted code flow, for
    /// accounts created without a password.
    code_login: bool = false,
};

fn parseRegion(name: ?[]const u8) cloud.Region {
    const value = name orelse return .global;
    return if (std.mem.eql(u8, value, "china")) .china else .global;
}

/// Step one of login. Returns one of: `{"result":"authenticated"}`,
/// `{"result":"code_required"}` or `{"result":"tfa_required"}`.
fn authLogin(request: *std.http.Server.Request, context: *Context) !void {
    const raw = readBody(request, context, 4096) catch |err| return switch (err) {
        error.BodyTooLarge => respondErrorClose(request, .payload_too_large, "body_too_large", "request body exceeds 4 KiB"),
        else => respondErrorClose(request, .bad_request, "invalid_body", "could not read request body"),
    };
    defer context.gpa.free(raw);

    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = std.json.parseFromSliceLeaky(LoginBody, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return respondError(request, .unprocessable_entity, "invalid_body", "expected {\"account\":\"…\",\"password\":\"…\"}");

    if (body.account.len == 0)
        return respondError(request, .unprocessable_entity, "invalid_body", "account must not be empty");

    const region = parseRegion(body.region);

    var client: cloud.Client = .init(context.gpa, context.io, region);
    defer client.deinit();

    // Emailed-code path, either requested outright or with no password supplied.
    if (body.code_login or body.password == null or body.password.?.len == 0) {
        client.requestLoginCode(arena, body.account) catch |err|
            return respondCloudError(request, err);
        try setPending(context, .{
            .kind = .verify_code,
            .account = try context.gpa.dupe(u8, body.account),
            .region = region,
        });
        return respondJson(request, "{\"result\":\"code_required\"}", .ok);
    }

    const outcome = client.login(arena, body.account, body.password.?) catch |err|
        return respondCloudError(request, err);

    switch (outcome) {
        .token => |token| {
            finishLogin(context, &client, arena, body.account, region, token) catch |err|
                return respondFinishLoginError(request, err);
            return respondJson(request, "{\"result\":\"authenticated\"}", .ok);
        },
        .code_required => {
            client.requestLoginCode(arena, body.account) catch |err|
                return respondCloudError(request, err);
            try setPending(context, .{
                .kind = .verify_code,
                .account = try context.gpa.dupe(u8, body.account),
                .region = region,
            });
            return respondJson(request, "{\"result\":\"code_required\"}", .ok);
        },
        .tfa_required => |tfa_key| {
            try setPending(context, .{
                .kind = .tfa,
                .account = try context.gpa.dupe(u8, body.account),
                .region = region,
                .tfa_key = try context.gpa.dupe(u8, tfa_key),
            });
            return respondJson(request, "{\"result\":\"tfa_required\"}", .ok);
        },
    }
}

const CodeBody = struct { code: []const u8 };

/// Step two for accounts that log in with an emailed/texted code.
fn authCode(request: *std.http.Server.Request, context: *Context) !void {
    const raw = readBody(request, context, 1024) catch |err| return switch (err) {
        error.BodyTooLarge => respondErrorClose(request, .payload_too_large, "body_too_large", "request body exceeds 1 KiB"),
        else => respondErrorClose(request, .bad_request, "invalid_body", "could not read request body"),
    };
    defer context.gpa.free(raw);

    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = std.json.parseFromSliceLeaky(CodeBody, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return respondError(request, .unprocessable_entity, "invalid_body", "expected {\"code\":\"…\"}");

    // Snapshot the pending login under the lock.
    context.lockAuth();
    const pending = context.pending;
    context.unlockAuth();
    const flow = pending orelse
        return respondError(request, .conflict, "no_pending_login", "no login is awaiting a code");
    if (flow.kind != .verify_code)
        return respondError(request, .conflict, "no_pending_login", "this login is not awaiting a code");

    const account = try arena.dupe(u8, flow.account);
    const region = flow.region;

    var client: cloud.Client = .init(context.gpa, context.io, region);
    defer client.deinit();

    const token = client.loginWithCode(arena, account, body.code) catch |err|
        return respondCloudError(request, err);

    finishLogin(context, &client, arena, account, region, token) catch |err|
        return respondFinishLoginError(request, err);
    clearPending(context);
    return respondJson(request, "{\"result\":\"authenticated\"}", .ok);
}

/// Step two for accounts with an authenticator app enrolled.
fn authTfa(request: *std.http.Server.Request, context: *Context) !void {
    const raw = readBody(request, context, 1024) catch |err| return switch (err) {
        error.BodyTooLarge => respondErrorClose(request, .payload_too_large, "body_too_large", "request body exceeds 1 KiB"),
        else => respondErrorClose(request, .bad_request, "invalid_body", "could not read request body"),
    };
    defer context.gpa.free(raw);

    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = std.json.parseFromSliceLeaky(CodeBody, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return respondError(request, .unprocessable_entity, "invalid_body", "expected {\"code\":\"…\"}");

    context.lockAuth();
    const pending = context.pending;
    context.unlockAuth();
    const flow = pending orelse
        return respondError(request, .conflict, "no_pending_login", "no login is awaiting a code");
    if (flow.kind != .tfa or flow.tfa_key == null)
        return respondError(request, .conflict, "no_pending_login", "this login is not awaiting an authenticator code");

    const account = try arena.dupe(u8, flow.account);
    const tfa_key = try arena.dupe(u8, flow.tfa_key.?);
    const region = flow.region;

    var client: cloud.Client = .init(context.gpa, context.io, region);
    defer client.deinit();

    const token = client.loginWithTfaCode(arena, tfa_key, body.code) catch |err|
        return respondCloudError(request, err);

    finishLogin(context, &client, arena, account, region, token) catch |err|
        return respondFinishLoginError(request, err);
    clearPending(context);
    return respondJson(request, "{\"result\":\"authenticated\"}", .ok);
}

/// Resolves the MQTT username, persists the token, and auto-selects the printer
/// if the account has exactly one. Auto-selection also kicks the supervisor.
fn finishLogin(
    context: *Context,
    client: *cloud.Client,
    arena: Allocator,
    account: []const u8,
    region: cloud.Region,
    access_token: []const u8,
) !void {
    const mqtt_username = try client.mqttUsername(arena, access_token);

    var creds: credentials.Credentials = .{
        .account = account,
        .access_token = access_token,
        .mqtt_username = mqtt_username,
        .region = region,
    };

    const devices = client.devices(arena, access_token) catch &.{};
    if (devices.len == 1) {
        creds.device_id = devices[0].dev_id;
        creds.device_access_code = devices[0].dev_access_code;
    }

    try context.store.save(context.gpa, creds);

    if (creds.device_id != null) context.session_wanted.store(true, .release);
    log.debug("api login: account={s} devices={d}", .{ account, devices.len });
}

/// Lists the printers bound to the logged-in account so the frontend can offer a
/// selector when there is more than one.
fn authDevices(request: *std.http.Server.Request, context: *Context) !void {
    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const creds = context.store.load(arena) catch
        return respondError(request, .unauthorized, "not_authenticated", "not logged in");

    var client: cloud.Client = .init(context.gpa, context.io, creds.region);
    defer client.deinit();

    const devices = client.devices(arena, creds.access_token) catch |err|
        return respondCloudError(request, err);

    var out: Io.Writer.Allocating = .init(context.gpa);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("devices");
    try stringify.beginArray();
    for (devices) |d| {
        try stringify.write(.{
            .dev_id = d.dev_id,
            .name = d.name,
            .online = d.online,
            .model = d.dev_product_name,
            .selected = creds.device_id != null and std.mem.eql(u8, creds.device_id.?, d.dev_id),
        });
    }
    try stringify.endArray();
    try stringify.endObject();
    return respondJson(request, out.written(), .ok);
}

const SelectBody = struct { device_id: []const u8 };

/// Records which printer to watch, refreshes its LAN access code, and brings the
/// session up.
fn authSelect(request: *std.http.Server.Request, context: *Context) !void {
    const raw = readBody(request, context, 1024) catch |err| return switch (err) {
        error.BodyTooLarge => respondErrorClose(request, .payload_too_large, "body_too_large", "request body exceeds 1 KiB"),
        else => respondErrorClose(request, .bad_request, "invalid_body", "could not read request body"),
    };
    defer context.gpa.free(raw);

    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = std.json.parseFromSliceLeaky(SelectBody, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return respondError(request, .unprocessable_entity, "invalid_body", "expected {\"device_id\":\"…\"}");

    var creds = context.store.load(arena) catch
        return respondError(request, .unauthorized, "not_authenticated", "not logged in");

    var client: cloud.Client = .init(context.gpa, context.io, creds.region);
    defer client.deinit();

    // Look up the chosen device to cache its LAN access code for LAN mode.
    const devices = client.devices(arena, creds.access_token) catch |err|
        return respondCloudError(request, err);
    var access_code: ?[]const u8 = null;
    var found = false;
    for (devices) |d| {
        if (std.mem.eql(u8, d.dev_id, body.device_id)) {
            found = true;
            access_code = d.dev_access_code;
            break;
        }
    }
    if (!found)
        return respondError(request, .not_found, "unknown_device", "no such printer on this account");

    creds.device_id = body.device_id;
    creds.device_access_code = access_code;
    context.store.save(context.gpa, creds) catch
        return respondError(request, .internal_server_error, "save_failed", "could not persist selection");

    // Reconnect against the newly selected printer.
    context.lockAuth();
    if (context.session) |old| {
        old.close();
        context.session = null;
    }
    context.unlockAuth();
    context.online.store(false, .release);
    context.session_wanted.store(true, .release);

    return respondJson(request, "{\"selected\":true}", .ok);
}

/// Discards the stored credentials and tears down the live session.
fn authLogout(request: *std.http.Server.Request, context: *Context) !void {
    context.session_wanted.store(false, .release);
    context.lockAuth();
    if (context.session) |session| {
        session.close();
        context.session = null;
    }
    if (context.pending) |*p| {
        p.deinit(context.gpa);
        context.pending = null;
    }
    context.unlockAuth();
    context.online.store(false, .release);

    // Otherwise the next account to log in inherits this one's plate render.
    context.lockThumb();
    context.thumb.clear(context.gpa);
    context.unlockThumb();

    context.store.delete(context.gpa) catch |err| switch (err) {
        error.NotFound => {},
        else => return respondError(request, .internal_server_error, "logout_failed", "could not remove stored credentials"),
    };

    return respondJson(request, "{\"logged_out\":true}", .ok);
}

// --- Home Assistant integration -------------------------------------------

/// The Home Assistant config lives beside the Bambu credentials but in its own
/// file, so signing out of Bambu Lab leaves the home automation setup alone.
fn haStore(context: *Context) homeassistant.Store {
    return .{ .io = context.io, .dir = context.store.dir };
}

/// Reports the stored configuration. The token is deliberately absent: it is a
/// full-access credential for the user's home and the settings page has no
/// reason to read one back.
fn haConfig(request: *std.http.Server.Request, context: *Context) !void {
    context.lockHa();
    defer context.unlockHa();
    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config: ?homeassistant.Config = haStore(context).load(arena) catch |err| switch (err) {
        error.NotFound => null,
        // A corrupt file should show up in the UI as "not configured" rather
        // than as a dead settings page.
        error.Corrupt => null,
        else => return respondError(request, .internal_server_error, "config_unreadable", "could not read the Home Assistant configuration"),
    };

    const body = try std.json.Stringify.valueAlloc(context.gpa, .{
        .configured = config != null,
        .base_url = if (config) |c| c.base_url else null,
        .entities = if (config) |c| c.entities else homeassistant.Entities{},
    }, .{});
    defer context.gpa.free(body);
    return respondJson(request, body, .ok);
}

const HomeAssistantBody = struct {
    base_url: []const u8,
    /// Optional so the entity lists can be edited without re-pasting the token.
    /// Absent or empty means "keep the stored one"; there is no way to read a
    /// token back out of the API, so the settings page cannot send it back.
    token: ?[]const u8 = null,
    entities: homeassistant.Entities = .{},
};

/// Validates and stores the configuration.
///
/// The connection is probed before anything is written, so a typo in the URL or
/// a revoked token is reported immediately instead of being discovered later by
/// a feature that quietly does nothing.
fn haSave(request: *std.http.Server.Request, context: *Context) !void {
    context.lockHa();
    defer context.unlockHa();
    if (!hasJsonContentType(request))
        return respondError(request, .unsupported_media_type, "content_type_required", "expected Content-Type: application/json");
    // Room for a token plus three full entity groups.
    const raw = readBody(request, context, 16 * 1024) catch |err| return switch (err) {
        error.BodyTooLarge => respondErrorClose(request, .payload_too_large, "body_too_large", "request body exceeds 16 KiB"),
        else => respondErrorClose(request, .bad_request, "invalid_body", "could not read request body"),
    };
    defer context.gpa.free(raw);

    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(HomeAssistantBody, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return respondError(
        request,
        .unprocessable_entity,
        "invalid_body",
        "expected {\"base_url\":\"…\",\"token\":\"…\",\"entities\":{\"light\":[],\"temperature\":[],\"fan\":[]}}",
    );

    const base_url = homeassistant.normalizeBaseUrl(arena, parsed.base_url) catch
        return respondError(request, .unprocessable_entity, "invalid_url", "expected an http:// or https:// address such as http://homeassistant.local:8123");

    const existing: ?homeassistant.Config = haStore(context).load(arena) catch null;
    const supplied = std.mem.trim(u8, parsed.token orelse "", " \t\r\n");
    const token = if (supplied.len != 0)
        supplied
    else if (existing) |stored|
        if (std.mem.eql(u8, stored.base_url, base_url))
            stored.token
        else
            return respondError(request, .unprocessable_entity, "missing_token", "the access token must be entered again when changing the Home Assistant URL")
    else
        return respondError(request, .unprocessable_entity, "missing_token", "a long-lived access token is required");

    homeassistant.validateEntities(parsed.entities) catch |err| return switch (err) {
        error.InvalidEntityId => respondError(request, .unprocessable_entity, "invalid_entity_id", "entity ids must look like light.kitchen_ceiling"),
        error.TooManyEntities => respondError(request, .unprocessable_entity, "too_many_entities", "too many entities in one group"),
        error.DuplicateEntity => respondError(request, .unprocessable_entity, "duplicate_entity", "an entity id can only appear once across all groups"),
        else => respondError(request, .internal_server_error, "invalid_entities", "could not validate the entity list"),
    };

    var client: homeassistant.Client = .init(context.gpa, context.io);
    defer client.deinit();
    client.probe(arena, base_url, token) catch |err| return respondHomeAssistantError(request, err);

    haStore(context).save(context.gpa, .{
        .base_url = base_url,
        .token = token,
        .entities = parsed.entities,
    }) catch return respondError(request, .internal_server_error, "save_failed", "could not write the Home Assistant configuration");

    std.log.info("home assistant configured at {s} ({d} entities)", .{ base_url, parsed.entities.total() });

    const body = try std.json.Stringify.valueAlloc(context.gpa, .{
        .saved = true,
        .base_url = base_url,
        .entities = parsed.entities,
    }, .{});
    defer context.gpa.free(body);
    return respondJson(request, body, .ok);
}

/// Re-probes the stored configuration so the settings page can offer a "test
/// connection" button without making the user re-enter the token.
fn haTest(request: *std.http.Server.Request, context: *Context) !void {
    context.lockHa();
    defer context.unlockHa();
    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = haStore(context).load(arena) catch |err| return switch (err) {
        error.NotFound, error.Corrupt => respondError(request, .conflict, "not_configured", "Home Assistant is not configured"),
        else => respondError(request, .internal_server_error, "config_unreadable", "could not read the Home Assistant configuration"),
    };

    var client: homeassistant.Client = .init(context.gpa, context.io);
    defer client.deinit();
    client.probe(arena, config.base_url, config.token) catch |err| return respondHomeAssistantError(request, err);

    return respondJson(request, "{\"ok\":true}", .ok);
}

fn haDisconnect(request: *std.http.Server.Request, context: *Context) !void {
    context.lockHa();
    defer context.unlockHa();
    haStore(context).delete(context.gpa) catch |err| switch (err) {
        error.NotFound => {},
        else => return respondError(request, .internal_server_error, "disconnect_failed", "could not remove the Home Assistant configuration"),
    };
    return respondJson(request, "{\"disconnected\":true}", .ok);
}

/// Reads the configured entities on demand. This endpoint is intentionally
/// separate from `/dashboard`: Home Assistant being slow or offline must not
/// interfere with the printer's one-second status poll.
fn haEntities(request: *std.http.Server.Request, context: *Context) !void {
    context.lockHa();
    defer context.unlockHa();
    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = haStore(context).load(arena) catch |err| return switch (err) {
        error.NotFound, error.Corrupt => respondError(request, .conflict, "not_configured", "Home Assistant is not configured"),
        else => respondError(request, .internal_server_error, "config_unreadable", "could not read the Home Assistant configuration"),
    };

    var client: homeassistant.Client = .init(context.gpa, context.io);
    defer client.deinit();
    const entities = client.states(arena, config) catch |err|
        return respondHomeAssistantApiError(request, err);

    const body = try std.json.Stringify.valueAlloc(context.gpa, .{ .entities = entities }, .{});
    defer context.gpa.free(body);
    return respondJson(request, body, .ok);
}

const HomeAssistantControlBody = struct {
    group: homeassistant.EntityGroup,
    entity_id: []const u8,
    on: ?bool = null,
    percentage: ?u8 = null,
};

/// Sends a tightly-scoped service call. An entity must be in the stored group;
/// arbitrary entity ids and arbitrary HA service names never cross this API.
fn haControl(request: *std.http.Server.Request, context: *Context) !void {
    context.lockHa();
    defer context.unlockHa();
    if (!hasJsonContentType(request))
        return respondError(request, .unsupported_media_type, "content_type_required", "expected Content-Type: application/json");
    const raw = readBody(request, context, 4 * 1024) catch |err| return switch (err) {
        error.BodyTooLarge => respondErrorClose(request, .payload_too_large, "body_too_large", "request body exceeds 4 KiB"),
        else => respondErrorClose(request, .bad_request, "invalid_body", "could not read request body"),
    };
    defer context.gpa.free(raw);

    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const command = std.json.parseFromSliceLeaky(HomeAssistantControlBody, arena, raw, .{
        .ignore_unknown_fields = false,
    }) catch return respondError(request, .unprocessable_entity, "invalid_body", "expected a group, entity_id, and on or percentage value");

    if (command.on == null and command.percentage == null)
        return respondError(request, .unprocessable_entity, "missing_action", "expected an on or percentage value");
    if (command.percentage) |value| if (value > 100)
        return respondError(request, .unprocessable_entity, "invalid_percentage", "percentage must be between 0 and 100");
    if (command.group == .temperature)
        return respondError(request, .unprocessable_entity, "read_only", "temperature entities are read-only");

    const config = haStore(context).load(arena) catch |err| return switch (err) {
        error.NotFound, error.Corrupt => respondError(request, .conflict, "not_configured", "Home Assistant is not configured"),
        else => respondError(request, .internal_server_error, "config_unreadable", "could not read the Home Assistant configuration"),
    };
    if (homeassistant.configuredGroup(config.entities, command.entity_id) != command.group)
        return respondError(request, .forbidden, "entity_not_configured", "that entity is not configured in this group");

    const domain = homeassistant.entityDomain(command.entity_id) orelse
        return respondError(request, .unprocessable_entity, "invalid_entity_id", "invalid Home Assistant entity id");

    var client: homeassistant.Client = .init(context.gpa, context.io);
    defer client.deinit();

    if (command.on == false) {
        client.callService(arena, config, domain, "turn_off", .{
            .entity_id = command.entity_id,
        }) catch |err| return respondHomeAssistantApiError(request, err);
    } else if (command.percentage) |percentage| {
        switch (command.group) {
            .light => {
                if (!std.mem.eql(u8, domain, "light"))
                    return respondError(request, .unprocessable_entity, "brightness_unsupported", "only light.* entities support brightness");
                client.callService(arena, config, domain, "turn_on", .{
                    .entity_id = command.entity_id,
                    .brightness_pct = percentage,
                }) catch |err| return respondHomeAssistantApiError(request, err);
            },
            .fan => {
                if (!std.mem.eql(u8, domain, "fan"))
                    return respondError(request, .unprocessable_entity, "percentage_unsupported", "only fan.* entities support percentage control");
                client.callService(arena, config, domain, "set_percentage", .{
                    .entity_id = command.entity_id,
                    .percentage = percentage,
                }) catch |err| return respondHomeAssistantApiError(request, err);
            },
            .temperature => unreachable,
        }
    } else {
        client.callService(arena, config, domain, "turn_on", .{
            .entity_id = command.entity_id,
        }) catch |err| return respondHomeAssistantApiError(request, err);
    }

    return respondJson(request, "{\"accepted\":true}", .accepted);
}

fn respondHomeAssistantError(request: *std.http.Server.Request, err: homeassistant.ProbeError) !void {
    return switch (err) {
        error.Unauthorized => respondError(request, .bad_gateway, "ha_unauthorized", "Home Assistant rejected the access token"),
        error.Unreachable => respondError(request, .bad_gateway, "ha_unreachable", "could not reach Home Assistant at that address (a self-signed https certificate will fail here; use http:// on a local network)"),
        error.NotHomeAssistant => respondError(request, .bad_gateway, "ha_unexpected_response", "that address answered, but not like a Home Assistant API"),
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn respondHomeAssistantApiError(request: *std.http.Server.Request, err: homeassistant.ApiError) !void {
    return switch (err) {
        error.Unauthorized => respondError(request, .bad_gateway, "ha_unauthorized", "Home Assistant rejected the access token"),
        error.Unreachable => respondError(request, .bad_gateway, "ha_unreachable", "could not reach Home Assistant"),
        error.NotHomeAssistant, error.InvalidResponse => respondError(request, .bad_gateway, "ha_unexpected_response", "Home Assistant returned an unexpected response"),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Replaces the pending login, freeing any previous one.
fn setPending(context: *Context, pending: PendingLogin) !void {
    context.lockAuth();
    defer context.unlockAuth();
    if (context.pending) |*old| old.deinit(context.gpa);
    context.pending = pending;
}

fn clearPending(context: *Context) void {
    context.lockAuth();
    defer context.unlockAuth();
    if (context.pending) |*p| {
        p.deinit(context.gpa);
        context.pending = null;
    }
}

/// Maps a `finishLogin` failure, which combines cloud errors with the token
/// store's write errors, to an HTTP response.
fn respondFinishLoginError(request: *std.http.Server.Request, err: anyerror) !void {
    return switch (err) {
        error.AccessDenied => respondError(request, .internal_server_error, "save_failed", "could not write the token store"),
        error.Unexpected => respondError(request, .internal_server_error, "save_failed", "could not persist credentials"),
        error.OutOfMemory => error.OutOfMemory,
        else => respondCloudError(request, @errorCast(err)),
    };
}

/// Maps a cloud login error to an HTTP response.
fn respondCloudError(request: *std.http.Server.Request, err: cloud.Error) !void {
    return switch (err) {
        error.InvalidCredentials => respondError(request, .unauthorized, "invalid_credentials", "the cloud rejected those credentials"),
        error.LoginCodeRequired => respondError(request, .unprocessable_entity, "code_required", "this account requires a login code"),
        error.LoginCodeExpired => respondError(request, .unprocessable_entity, "code_expired", "that code had expired; a new one has been sent"),
        error.LoginCodeIncorrect => respondError(request, .unprocessable_entity, "code_incorrect", "that verification code was not correct"),
        error.TfaCodeRequired => respondError(request, .unprocessable_entity, "tfa_required", "this account uses an authenticator app"),
        error.BlockedByCloudflare => respondError(request, .service_unavailable, "cloudflare_blocked", "Cloudflare blocked the request; try again shortly"),
        error.UnexpectedResponse => respondError(request, .bad_gateway, "unexpected_response", "the cloud API returned something unexpected"),
        error.HttpRequestFailed => respondError(request, .bad_gateway, "cloud_unreachable", "could not reach the Bambu Lab cloud"),
        error.OutOfMemory => error.OutOfMemory,
    };
}

// --- HTTP helpers ---------------------------------------------------------

const ReadBodyError = error{ BodyTooLarge, ReadFailed, OutOfMemory };

/// Reads and returns the full request body, capped at `limit` bytes. Caller
/// owns the returned slice.
fn readBody(request: *std.http.Server.Request, context: *Context, limit: usize) ReadBodyError![]u8 {
    if ((request.head.content_length orelse 0) > limit) return error.BodyTooLarge;

    var transfer_buffer: [4096]u8 = undefined;
    const reader = request.readerExpectContinue(&transfer_buffer) catch return error.ReadFailed;
    return reader.allocRemaining(context.gpa, .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => error.BodyTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "cache-control", .value = "no-store" },
};

fn respondJson(request: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    return request.respond(body, .{ .status = status, .extra_headers = &json_headers });
}

fn methodNotAllowed(request: *std.http.Server.Request, allow: []const u8) !void {
    return request.respond(
        "{\"error\":{\"code\":\"method_not_allowed\",\"message\":\"method not allowed\"}}",
        .{
            .status = .method_not_allowed,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "allow", .value = allow },
            },
        },
    );
}

fn respondError(
    request: *std.http.Server.Request,
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
) !void {
    return respondErrorKeepAlive(request, status, code, message, true);
}

fn respondErrorClose(
    request: *std.http.Server.Request,
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
) !void {
    return respondErrorKeepAlive(request, status, code, message, false);
}

fn respondErrorKeepAlive(
    request: *std.http.Server.Request,
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
    keep_alive: bool,
) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var stringify: std.json.Stringify = .{ .writer = &writer };
    try stringify.write(.{ .@"error" = .{ .code = code, .message = message } });
    return request.respond(writer.buffered(), .{
        .status = status,
        .keep_alive = keep_alive,
        .extra_headers = &json_headers,
    });
}

test route {
    try std.testing.expectEqual(Route.dashboard, route("/api/v1/dashboard"));
    try std.testing.expectEqual(Route.dashboard, route("/api/v1/dashboard?refresh=false"));
    try std.testing.expectEqual(Route.job_thumbnail, route("/api/v1/job/thumbnail"));
    // The version query is what busts the browser cache between prints.
    try std.testing.expectEqual(Route.job_thumbnail, route("/api/v1/job/thumbnail?v=1176981973"));
    try std.testing.expectEqual(Route.light, route("/api/v1/controls/light"));
    try std.testing.expectEqual(Route.auth_login, route("/api/v1/auth/login"));
    try std.testing.expectEqual(Route.auth_status, route("/api/v1/auth/status"));
    try std.testing.expectEqual(Route.auth_devices, route("/api/v1/auth/devices"));
    try std.testing.expectEqual(Route.ha_config, route("/api/v1/integrations/homeassistant"));
    try std.testing.expectEqual(Route.ha_test, route("/api/v1/integrations/homeassistant/test"));
    try std.testing.expectEqual(Route.ha_disconnect, route("/api/v1/integrations/homeassistant/disconnect"));
    try std.testing.expectEqual(Route.ha_entities, route("/api/v1/integrations/homeassistant/entities"));
    try std.testing.expectEqual(Route.ha_control, route("/api/v1/integrations/homeassistant/control"));
    try std.testing.expectEqual(Route.unknown, route("/api/v1/nope"));
}

test jobProfile {
    const job = "1plate 4color AMS0.16mm layer, 2 walls, 7% infill ";
    // The real shape of a MakerWorld print: title repeats the job name, so the
    // model name is the only useful subtitle.
    try std.testing.expectEqualStrings("Goofy series – SNAIL Movable Eyes", jobProfile(.{
        .id = 1,
        .title = job,
        .design_title = "Goofy series – SNAIL Movable Eyes",
        .cover_url = "https://example/cover.png",
    }, job).?);
    // A plate sliced from scratch has no design; the title would only duplicate
    // the name, trailing space and all.
    try std.testing.expect(jobProfile(.{
        .id = 1,
        .title = job,
        .design_title = "",
        .cover_url = "https://example/cover.png",
    }, job) == null);
    // A title that genuinely differs is still better than nothing.
    try std.testing.expectEqualStrings("Benchy plate", jobProfile(.{
        .id = 1,
        .title = "Benchy plate",
        .design_title = "",
        .cover_url = "https://example/cover.png",
    }, job).?);
}

test parseLightBody {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqual(printer.Session.LedMode.on, try parseLightBody(arena.allocator(), "{\"on\":true}"));
    try std.testing.expectEqual(printer.Session.LedMode.off, try parseLightBody(arena.allocator(), "{\"on\":false}"));
    try std.testing.expectEqual(printer.Session.LedMode.flashing, try parseLightBody(arena.allocator(), "{\"mode\":\"flashing\"}"));
    try std.testing.expectError(error.InvalidBody, parseLightBody(arena.allocator(), "{}"));
    try std.testing.expectError(error.InvalidBody, parseLightBody(arena.allocator(), "{\"on\":1}"));
}

test parseRegion {
    try std.testing.expectEqual(cloud.Region.global, parseRegion(null));
    try std.testing.expectEqual(cloud.Region.global, parseRegion("global"));
    try std.testing.expectEqual(cloud.Region.china, parseRegion("china"));
}
