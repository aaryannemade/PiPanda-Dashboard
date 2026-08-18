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

    fn lockAuth(self: *Context) void {
        self.auth_mutex.lock(self.io) catch {};
    }
    fn unlockAuth(self: *Context) void {
        self.auth_mutex.unlock(self.io);
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
    camera,
    light,
    auth_status,
    auth_login,
    auth_code,
    auth_tfa,
    auth_devices,
    auth_select,
    auth_logout,
    unknown,
};

fn route(target: []const u8) Route {
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
    if (std.mem.eql(u8, path, "/api/v1/health")) return .health;
    if (std.mem.eql(u8, path, "/api/v1/dashboard")) return .dashboard;
    if (std.mem.eql(u8, path, "/api/v1/printer/state")) return .raw_state;
    if (std.mem.eql(u8, path, "/api/v1/camera")) return .camera;
    if (std.mem.eql(u8, path, "/api/v1/controls/light")) return .light;
    if (std.mem.eql(u8, path, "/api/v1/auth/status")) return .auth_status;
    if (std.mem.eql(u8, path, "/api/v1/auth/login")) return .auth_login;
    if (std.mem.eql(u8, path, "/api/v1/auth/code")) return .auth_code;
    if (std.mem.eql(u8, path, "/api/v1/auth/tfa")) return .auth_tfa;
    if (std.mem.eql(u8, path, "/api/v1/auth/devices")) return .auth_devices;
    if (std.mem.eql(u8, path, "/api/v1/auth/select")) return .auth_select;
    if (std.mem.eql(u8, path, "/api/v1/auth/logout")) return .auth_logout;
    return .unknown;
}

fn serveRequest(request: *std.http.Server.Request, context: *Context) !void {
    if (request.head.method == .OPTIONS) {
        return request.respond("", .{
            .status = .no_content,
            .extra_headers = &cors_headers,
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
        .unknown => return respondError(request, .not_found, "not_found", "endpoint not found"),
    }
}

fn serveDashboard(request: *std.http.Server.Request, context: *Context) !void {
    context.lockAuth();
    const session = context.session;
    context.unlockAuth();

    const active = session orelse
        return respondError(request, .service_unavailable, "not_connected", "not logged in or no printer selected");

    const body = try active.dashboardJson(context.gpa, .{
        .device_id = active.device_id,
        .name = context.options.printer_name,
        .model = context.options.printer_model,
        .camera_url = context.options.camera_url,
        .online = context.online.load(.acquire),
    });
    defer context.gpa.free(body);
    return respondJson(request, body, .ok);
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

    context.store.delete(context.gpa) catch |err| switch (err) {
        error.NotFound => {},
        else => return respondError(request, .internal_server_error, "logout_failed", "could not remove stored credentials"),
    };

    return respondJson(request, "{\"logged_out\":true}", .ok);
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
    .{ .name = "access-control-allow-origin", .value = "*" },
};

const cors_headers = [_]std.http.Header{
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, HEAD, POST, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "content-type" },
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
                .{ .name = "access-control-allow-origin", .value = "*" },
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
    try std.testing.expectEqual(Route.light, route("/api/v1/controls/light"));
    try std.testing.expectEqual(Route.auth_login, route("/api/v1/auth/login"));
    try std.testing.expectEqual(Route.auth_status, route("/api/v1/auth/status"));
    try std.testing.expectEqual(Route.auth_devices, route("/api/v1/auth/devices"));
    try std.testing.expectEqual(Route.unknown, route("/api/v1/nope"));
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
