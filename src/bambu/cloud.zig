//! Bambu Lab cloud HTTP API: authentication and device enumeration.
//!
//! Endpoints and the login state machine were taken from the Bambu Studio /
//! Orca network agent behaviour as documented by the OpenBambuAPI project and
//! as implemented by the Home Assistant `ha-bambulab` integration.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = @import("../log.zig");

pub const Region = enum {
    /// api.bambulab.com, us.mqtt.bambulab.com
    global,
    /// api.bambulab.cn, cn.mqtt.bambulab.com
    china,

    pub fn mqttHost(region: Region) []const u8 {
        return switch (region) {
            .global => "us.mqtt.bambulab.com",
            .china => "cn.mqtt.bambulab.com",
        };
    }
};

const Endpoint = enum {
    login,
    email_code,
    sms_code,
    tfa_login,
    preference,
    bind,

    /// The China region is the same API with `.com` swapped for `.cn`.
    fn url(e: Endpoint, region: Region) []const u8 {
        return switch (region) {
            .global => switch (e) {
                .login => "https://api.bambulab.com/v1/user-service/user/login",
                .email_code => "https://api.bambulab.com/v1/user-service/user/sendemail/code",
                .sms_code => "https://api.bambulab.com/v1/user-service/user/sendsmscode",
                .tfa_login => "https://bambulab.com/api/sign-in/tfa",
                .preference => "https://api.bambulab.com/v1/design-user-service/my/preference",
                .bind => "https://api.bambulab.com/v1/iot-service/api/user/bind",
            },
            .china => switch (e) {
                .login => "https://api.bambulab.cn/v1/user-service/user/login",
                .email_code => "https://api.bambulab.cn/v1/user-service/user/sendemail/code",
                .sms_code => "https://bambulab.cn/api/v1/user-service/user/sendsmscode",
                .tfa_login => "https://bambulab.cn/api/sign-in/tfa",
                .preference => "https://api.bambulab.cn/v1/design-user-service/my/preference",
                .bind => "https://api.bambulab.cn/v1/iot-service/api/user/bind",
            },
        };
    }
};

/// Bambu fronts the API with Cloudflare and rejects clients that do not look
/// like the official network agent. These are the headers Orca Slicer sends.
const agent_headers = [_]std.http.Header{
    .{ .name = "X-BBL-Client-Name", .value = "OrcaSlicer" },
    .{ .name = "X-BBL-Client-Type", .value = "slicer" },
    .{ .name = "X-BBL-Client-Version", .value = "01.09.05.51" },
    .{ .name = "X-BBL-Language", .value = "en-US" },
    .{ .name = "X-BBL-OS-Type", .value = "linux" },
    .{ .name = "X-BBL-OS-Version", .value = "6.2.0" },
    .{ .name = "X-BBL-Agent-Version", .value = "01.09.05.01" },
    .{ .name = "X-BBL-Executable-info", .value = "{}" },
    .{ .name = "X-BBL-Agent-OS-Type", .value = "linux" },
    .{ .name = "Accept", .value = "application/json" },
};

const user_agent = "bambu_network_agent/01.09.05.01";

pub const Error = error{
    /// Cloudflare returned a challenge or block page. There is no way around
    /// this from a plain HTTP client; retry later or authenticate elsewhere and
    /// copy the token over.
    BlockedByCloudflare,
    /// Credentials rejected.
    InvalidCredentials,
    /// The account requires an emailed/SMS login code. Call `requestLoginCode`
    /// then `loginWithCode`.
    LoginCodeRequired,
    /// The emailed code has expired; a fresh one has been sent.
    LoginCodeExpired,
    /// The emailed code was wrong.
    LoginCodeIncorrect,
    /// The account has an authenticator app enrolled. `tfa_key` on the result
    /// must be passed to `loginWithTfaCode`.
    TfaCodeRequired,
    /// The server answered with something we do not know how to interpret.
    UnexpectedResponse,
    HttpRequestFailed,
    OutOfMemory,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    region: Region,
    http: std.http.Client,

    pub fn init(gpa: Allocator, io: Io, region: Region) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .region = region,
            .http = .{
                .allocator = gpa,
                .io = io,
                // `now` must be left null. `std.http.Client.request` treats a
                // non-null `now` as "the CA bundle is already populated" and
                // skips loading it, which makes every handshake fail with
                // TlsCertificateNotVerified. It sets both on first use.
                .now = null,
            },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    const Reply = struct {
        status: std.http.Status,
        body: []const u8,
        /// Value of the `token` cookie, if the response set one. Only the TFA
        /// endpoint uses this.
        token_cookie: ?[]const u8,

        fn ok(reply: Reply) bool {
            return @intFromEnum(reply.status) >= 200 and @intFromEnum(reply.status) < 300;
        }
    };

    /// Issues one request. Everything returned is allocated in `arena`.
    fn send(
        self: *Client,
        arena: Allocator,
        method: std.http.Method,
        url: []const u8,
        json_body: ?[]const u8,
        bearer: ?[]const u8,
    ) Error!Reply {
        const uri = std.Uri.parse(url) catch return error.UnexpectedResponse;

        var extra: std.ArrayList(std.http.Header) = .empty;
        try extra.appendSlice(arena, &agent_headers);
        if (bearer) |token| {
            const value = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
            try extra.append(arena, .{ .name = "Authorization", .value = value });
        }

        var req = self.http.request(method, uri, .{
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .content_type = if (json_body != null)
                    .{ .override = "application/json" }
                else
                    .omit,
                // Match the official agent, and in doing so keep zstd off the
                // table so a fixed flate-sized decompression buffer is enough.
                .accept_encoding = .{ .override = "gzip, deflate" },
            },
            .extra_headers = extra.items,
            // The login endpoints are POSTs that must not be replayed against a
            // redirect target.
            .redirect_behavior = if (json_body == null) @enumFromInt(3) else .unhandled,
        }) catch return error.HttpRequestFailed;
        defer req.deinit();

        if (json_body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var body = req.sendBodyUnflushed(&.{}) catch return error.HttpRequestFailed;
            body.writer.writeAll(payload) catch return error.HttpRequestFailed;
            body.end() catch return error.HttpRequestFailed;
            req.connection.?.flush() catch return error.HttpRequestFailed;
        } else {
            req.sendBodiless() catch return error.HttpRequestFailed;
        }

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.HttpRequestFailed;

        // Grab the `token` cookie before the head is invalidated by starting
        // the body stream.
        var token_cookie: ?[]const u8 = null;
        var header_it = response.head.iterateHeaders();
        while (header_it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "set-cookie")) continue;
            if (parseCookie(header.value, "token")) |value| {
                token_cookie = try arena.dupe(u8, value);
            }
        }

        var collected: Io.Writer.Allocating = .init(arena);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        const body_reader = response.readerDecompressing(
            &transfer_buffer,
            &decompress,
            &decompress_buffer,
        );
        _ = body_reader.streamRemaining(&collected.writer) catch return error.HttpRequestFailed;

        const body = collected.written();

        log.debug("http {s} {s} -> {d} ({d} bytes, encoding {s})", .{
            @tagName(method),
            url,
            @intFromEnum(response.head.status),
            body.len,
            @tagName(response.head.content_encoding),
        });
        // Error bodies carry the actual reason and no credentials. Success
        // bodies carry the access token, so they are never logged.
        if (@intFromEnum(response.head.status) >= 400) {
            log.debug("  body: {s}", .{log.prefix(body, 512)});
        }

        if (response.head.status == .forbidden or response.head.status == .too_many_requests) {
            if (std.mem.indexOf(u8, body, "cloudflare") != null) return error.BlockedByCloudflare;
        }

        return .{
            .status = response.head.status,
            .body = body,
            .token_cookie = token_cookie,
        };
    }

    pub const LoginResult = union(enum) {
        /// Password login succeeded outright.
        token: []const u8,
        /// The account logs in with an emailed or texted code. The code has
        /// *not* been sent yet; call `requestLoginCode`.
        code_required,
        /// The account has an authenticator app. Prompt for the 6-digit code
        /// and pass it plus this key to `loginWithTfaCode`.
        tfa_required: []const u8,
    };

    /// Step one of authentication. Everything returned is allocated in `arena`.
    pub fn login(
        self: *Client,
        arena: Allocator,
        account: []const u8,
        password: []const u8,
    ) Error!LoginResult {
        const payload = try std.json.Stringify.valueAlloc(arena, .{
            .account = account,
            .password = password,
            .apiError = "",
        }, .{});

        const reply = try self.send(arena, .POST, Endpoint.login.url(self.region), payload, null);
        if (!reply.ok()) {
            if (reply.status == .unauthorized or reply.status == .bad_request) {
                return error.InvalidCredentials;
            }
            return error.HttpRequestFailed;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, arena, reply.body, .{}) catch
            return error.UnexpectedResponse;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.UnexpectedResponse,
        };

        if (stringField(obj, "accessToken")) |token| {
            if (token.len != 0) {
                log.debug("login: password accepted, token is {d} chars, jwt={}", .{
                    token.len,
                    std.mem.count(u8, token, ".") == 2,
                });
                return .{ .token = try arena.dupe(u8, token) };
            }
        }

        const login_type = stringField(obj, "loginType") orelse return error.UnexpectedResponse;
        log.debug("login: loginType={s}", .{login_type});
        if (std.mem.eql(u8, login_type, "verifyCode")) return .code_required;
        if (std.mem.eql(u8, login_type, "tfa")) {
            const key = stringField(obj, "tfaKey") orelse return error.UnexpectedResponse;
            return .{ .tfa_required = try arena.dupe(u8, key) };
        }
        return error.UnexpectedResponse;
    }

    /// Asks the cloud to send a fresh login code. Email accounts get an email,
    /// phone-number accounts get an SMS.
    pub fn requestLoginCode(self: *Client, arena: Allocator, account: []const u8) Error!void {
        const is_email = std.mem.indexOfScalar(u8, account, '@') != null;
        const endpoint: Endpoint = if (is_email) .email_code else .sms_code;
        const payload = if (is_email)
            try std.json.Stringify.valueAlloc(arena, .{
                .email = account,
                .type = "codeLogin",
            }, .{})
        else
            try std.json.Stringify.valueAlloc(arena, .{
                .phone = account,
                .type = "codeLogin",
            }, .{});

        const reply = try self.send(arena, .POST, endpoint.url(self.region), payload, null);
        if (!reply.ok()) return error.HttpRequestFailed;
    }

    /// Step two for accounts that log in with an emailed/texted code.
    pub fn loginWithCode(
        self: *Client,
        arena: Allocator,
        account: []const u8,
        code: []const u8,
    ) Error![]const u8 {
        const payload = try std.json.Stringify.valueAlloc(arena, .{
            .account = account,
            .code = code,
        }, .{});

        const reply = try self.send(arena, .POST, Endpoint.login.url(self.region), payload, null);

        const parsed = std.json.parseFromSlice(std.json.Value, arena, reply.body, .{}) catch
            return error.UnexpectedResponse;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.UnexpectedResponse,
        };

        if (reply.status == .bad_request) {
            // `code` here is the API's error code, not the login code.
            return switch (integerField(obj, "code") orelse -1) {
                // Expired. The cloud does not resend automatically.
                1 => blk: {
                    self.requestLoginCode(arena, account) catch {};
                    break :blk error.LoginCodeExpired;
                },
                2 => error.LoginCodeIncorrect,
                else => error.UnexpectedResponse,
            };
        }
        if (!reply.ok()) return error.HttpRequestFailed;

        const token = stringField(obj, "accessToken") orelse return error.UnexpectedResponse;
        if (token.len == 0) return error.UnexpectedResponse;
        return try arena.dupe(u8, token);
    }

    /// Step two for accounts with an authenticator app enrolled.
    ///
    /// Unlike every other endpoint, this one lives on the website host and
    /// returns the access token in a `token` cookie rather than in the body.
    pub fn loginWithTfaCode(
        self: *Client,
        arena: Allocator,
        tfa_key: []const u8,
        tfa_code: []const u8,
    ) Error![]const u8 {
        const payload = try std.json.Stringify.valueAlloc(arena, .{
            .tfaKey = tfa_key,
            .tfaCode = tfa_code,
        }, .{});

        const reply = try self.send(arena, .POST, Endpoint.tfa_login.url(self.region), payload, null);
        if (!reply.ok()) return error.InvalidCredentials;
        return reply.token_cookie orelse error.UnexpectedResponse;
    }

    /// The cloud MQTT username. Historically this was a claim inside the access
    /// token JWT; on newer tokens it has to be fetched from the preference API.
    pub fn mqttUsername(self: *Client, arena: Allocator, access_token: []const u8) Error![]const u8 {
        if (usernameFromJwt(arena, access_token)) |name| {
            log.debug("mqtt username from jwt claim: {s}…", .{log.prefix(name, 4)});
            return name;
        }
        log.debug("token carries no username claim, falling back to preference api", .{});

        const reply = try self.send(
            arena,
            .GET,
            Endpoint.preference.url(self.region),
            null,
            access_token,
        );
        if (!reply.ok()) return error.InvalidCredentials;

        const parsed = std.json.parseFromSlice(std.json.Value, arena, reply.body, .{}) catch
            return error.UnexpectedResponse;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.UnexpectedResponse,
        };
        const uid = integerField(obj, "uid") orelse return error.UnexpectedResponse;
        const name = try std.fmt.allocPrint(arena, "u_{d}", .{uid});
        log.debug("mqtt username from preference api: {s}…", .{log.prefix(name, 4)});
        return name;
    }

    pub const Device = struct {
        dev_id: []const u8,
        name: []const u8,
        online: bool,
        print_status: []const u8,
        dev_model_name: []const u8,
        dev_product_name: []const u8,
        /// The LAN access code. Also the password for local MQTT.
        dev_access_code: []const u8,
    };

    /// Printers bound to the account.
    pub fn devices(self: *Client, arena: Allocator, access_token: []const u8) Error![]Device {
        const reply = try self.send(arena, .GET, Endpoint.bind.url(self.region), null, access_token);
        if (!reply.ok()) return error.InvalidCredentials;

        const parsed = std.json.parseFromSlice(std.json.Value, arena, reply.body, .{}) catch
            return error.UnexpectedResponse;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.UnexpectedResponse,
        };
        const list = switch (obj.get("devices") orelse return error.UnexpectedResponse) {
            .array => |a| a,
            // An account with no printers returns null here.
            .null => return &.{},
            else => return error.UnexpectedResponse,
        };

        var out: std.ArrayList(Device) = .empty;
        try out.ensureTotalCapacity(arena, list.items.len);
        for (list.items) |item| {
            const d = switch (item) {
                .object => |o| o,
                else => continue,
            };
            log.debug("device: model={s} product={s} online={?} access_code={d} chars", .{
                stringField(d, "dev_model_name") orelse "?",
                stringField(d, "dev_product_name") orelse "?",
                switch (d.get("online") orelse .null) {
                    .bool => |b| b,
                    else => null,
                },
                (stringField(d, "dev_access_code") orelse @as([]const u8, "")).len,
            });
            out.appendAssumeCapacity(.{
                .dev_id = stringField(d, "dev_id") orelse continue,
                .name = stringField(d, "name") orelse "",
                .online = switch (d.get("online") orelse .null) {
                    .bool => |b| b,
                    else => false,
                },
                .print_status = stringField(d, "print_status") orelse "",
                .dev_model_name = stringField(d, "dev_model_name") orelse "",
                .dev_product_name = stringField(d, "dev_product_name") orelse "",
                // The API returns this with a trailing newline.
                .dev_access_code = std.mem.trim(
                    u8,
                    stringField(d, "dev_access_code") orelse "",
                    " \r\n\t",
                ),
            });
        }
        return out.items;
    }
};

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn integerField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (obj.get(name) orelse return null) {
        .integer => |i| i,
        .string, .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Extracts one cookie value out of a `Set-Cookie` header value.
fn parseCookie(header_value: []const u8, name: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, header_value, '=') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, header_value[0..eq], " "), name)) return null;
    const rest = header_value[eq + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    const value = std.mem.trim(u8, rest[0..end], " ");
    return if (value.len == 0) null else value;
}

/// Older access tokens are JWTs whose payload carries `"username":"u_1234567"`.
fn usernameFromJwt(arena: Allocator, token: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    const payload_b64 = parts.next() orelse return null;
    if (parts.next() == null) return null;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const len = decoder.calcSizeForSlice(payload_b64) catch return null;
    const buf = arena.alloc(u8, len) catch return null;
    decoder.decode(buf, payload_b64) catch return null;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, buf, .{}) catch return null;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const username = stringField(obj, "username") orelse return null;
    return if (username.len == 0) null else username;
}

test parseCookie {
    try std.testing.expectEqualStrings(
        "abc123",
        parseCookie("token=abc123; Path=/; HttpOnly", "token").?,
    );
    try std.testing.expect(parseCookie("other=abc123; Path=/", "token") == null);
    try std.testing.expect(parseCookie("token=; Path=/", "token") == null);
}

test usernameFromJwt {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // {"username":"u_1234567"} base64url, no padding.
    const token = "aaa.eyJ1c2VybmFtZSI6InVfMTIzNDU2NyJ9.bbb";
    try std.testing.expectEqualStrings("u_1234567", usernameFromJwt(arena, token).?);
    try std.testing.expect(usernameFromJwt(arena, "not-a-jwt") == null);
}
