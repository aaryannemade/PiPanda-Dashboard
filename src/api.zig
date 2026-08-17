//! HTTP API consumed by the dashboard frontend.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const printer = @import("bambu/printer.zig");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    printer_name: []const u8 = "Panda",
    printer_model: []const u8 = "P1S",
    camera_url: []const u8 = "http://127.0.0.1:1984/stream.html?src=p1s&mode=webrtc",
};

const Context = struct {
    gpa: Allocator,
    io: Io,
    session: *printer.Session,
    options: Options,
    online: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

pub fn serve(
    gpa: Allocator,
    io: Io,
    session: *printer.Session,
    options: Options,
) !void {
    const address = try Io.net.IpAddress.parse(options.host, options.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var context: Context = .{
        .gpa = gpa,
        .io = io,
        .session = session,
        .options = options,
    };

    var tasks: Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, keepAliveLoop, .{&context});
    try tasks.concurrent(io, pumpLoop, .{&context});

    std.log.info("dashboard API listening on http://{s}:{d}", .{ options.host, options.port });
    while (true) {
        const stream = try listener.accept(io);
        tasks.concurrent(io, accept, .{ &context, stream }) catch |err| {
            stream.close(io);
            return err;
        };
    }
}

fn keepAliveLoop(context: *Context) void {
    defer context.online.store(false, .release);
    context.session.keepAlive() catch |err| {
        if (err != error.Canceled) std.log.err("printer keepalive stopped: {t}", .{err});
    };
}

fn pumpLoop(context: *Context) void {
    while (true) _ = context.session.pump() catch |err| {
        context.online.store(false, .release);
        std.log.err("printer status stream stopped: {t}", .{err});
        return;
    };
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
    unknown,
};

fn route(target: []const u8) Route {
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
    if (std.mem.eql(u8, path, "/api/v1/health")) return .health;
    if (std.mem.eql(u8, path, "/api/v1/dashboard")) return .dashboard;
    if (std.mem.eql(u8, path, "/api/v1/printer/state")) return .raw_state;
    if (std.mem.eql(u8, path, "/api/v1/camera")) return .camera;
    if (std.mem.eql(u8, path, "/api/v1/controls/light")) return .light;
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
            const body = try context.session.dashboardJson(context.gpa, .{
                .device_id = context.session.device_id,
                .name = context.options.printer_name,
                .model = context.options.printer_model,
                .camera_url = context.options.camera_url,
                .online = context.online.load(.acquire),
            });
            defer context.gpa.free(body);
            return respondJson(request, body, .ok);
        },
        .raw_state => {
            if (request.head.method != .GET and request.head.method != .HEAD)
                return methodNotAllowed(request, "GET, HEAD, OPTIONS");
            const body = try context.session.statusJson(context.gpa);
            defer context.gpa.free(body);
            return respondJson(request, body, .ok);
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
        .unknown => return respondError(request, .not_found, "not_found", "endpoint not found"),
    }
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
    if ((request.head.content_length orelse 0) > 1024)
        return respondErrorClose(request, .payload_too_large, "body_too_large", "request body exceeds 1 KiB");

    var transfer_buffer: [1024]u8 = undefined;
    const reader = try request.readerExpectContinue(&transfer_buffer);
    const body = reader.allocRemaining(context.gpa, .limited(1024)) catch |err| switch (err) {
        error.StreamTooLong => return respondErrorClose(request, .payload_too_large, "body_too_large", "request body exceeds 1 KiB"),
        else => return respondErrorClose(request, .bad_request, "invalid_body", "could not read request body"),
    };
    defer context.gpa.free(body);

    var arena: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena.deinit();
    const mode = parseLightBody(arena.allocator(), body) catch
        return respondError(request, .unprocessable_entity, "invalid_body", "expected {\"on\":true} or {\"mode\":\"on|off|flashing\"}");

    context.session.setChamberLight(mode) catch
        return respondError(request, .service_unavailable, "printer_unavailable", "could not publish light command");
    const response = try std.json.Stringify.valueAlloc(context.gpa, .{
        .accepted = true,
        .mode = @tagName(mode),
    }, .{});
    defer context.gpa.free(response);
    return respondJson(request, response, .accepted);
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
