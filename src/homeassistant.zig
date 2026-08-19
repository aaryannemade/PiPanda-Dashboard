//! Home Assistant integration: on-disk configuration and connection checks.
//!
//! Scope is deliberately narrow. This module stores where Home Assistant lives,
//! a long-lived access token, and which entities the user cares about, grouped
//! into lights, temperatures and fans. It does not read entity state and does
//! not drive anything on the dashboard yet.
//!
//! The token is a bearer credential with full API access to the user's home, so
//! it is treated like the Bambu token: written `0600`, never logged, and never
//! returned over the HTTP API.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = @import("log.zig");
const credentials = @import("bambu/credentials.zig");

/// A cap on each entity group. Nothing in Home Assistant enforces a limit, but
/// this bounds both the config file and the JSON the dashboard has to hand back
/// on a 512 MB Pi.
pub const max_entities_per_group = 64;

/// Entity ids the user has assigned to each role.
///
/// The grouping is the user's, not Home Assistant's: a bulb might be exposed as
/// `light.desk` or as `switch.desk_plug`, and a temperature might come from a
/// `sensor.*` or a `climate.*`. Only the shape of an id is validated, so any
/// domain the user's setup actually uses is accepted.
pub const Entities = struct {
    light: []const []const u8 = &.{},
    temperature: []const []const u8 = &.{},
    fan: []const []const u8 = &.{},

    pub fn total(self: Entities) usize {
        return self.light.len + self.temperature.len + self.fan.len;
    }
};

pub const Config = struct {
    /// Origin with no trailing slash, e.g. `http://homeassistant.local:8123`.
    base_url: []const u8,
    /// Long-lived access token. Never logged, never serialised to a client.
    token: []const u8,
    entities: Entities = .{},
};

pub const ValidationError = error{
    /// Not an absolute `http://` or `https://` URL, or it has no host.
    InvalidUrl,
    /// Not `domain.object_id` in Home Assistant's character set.
    InvalidEntityId,
    /// More than `max_entities_per_group` in one group.
    TooManyEntities,
    DuplicateEntity,
    /// Empty token.
    MissingToken,
    OutOfMemory,
};

/// Trims a user-entered base URL to a bare origin.
///
/// Home Assistant is usually typed in with a trailing slash, and sometimes with
/// the `/lovelace` path still attached from a copy-paste out of the browser bar.
/// Only the scheme, host and port are kept, so `{base}/api/...` is always well
/// formed. The result is allocated in `arena`.
pub fn normalizeBaseUrl(arena: Allocator, raw: []const u8) ValidationError![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidUrl;

    const uri = std.Uri.parse(trimmed) catch return error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https"))
        return error.InvalidUrl;

    const host = uri.host orelse return error.InvalidUrl;
    const host_text = switch (host) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    if (host_text.len == 0) return error.InvalidUrl;

    return if (uri.port) |port|
        std.fmt.allocPrint(arena, "{s}://{s}:{d}", .{ uri.scheme, host_text, port })
    else
        std.fmt.allocPrint(arena, "{s}://{s}", .{ uri.scheme, host_text });
}

/// Home Assistant entity ids are `domain.object_id`, both parts lowercase
/// alphanumerics and underscores. Rejecting anything else here turns a typo into
/// an error at save time rather than an entity that silently never resolves.
pub fn validEntityId(id: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, id, '.') orelse return false;
    const domain = id[0..dot];
    const object_id = id[dot + 1 ..];
    if (domain.len == 0 or object_id.len == 0) return false;
    // A second dot would mean a nested id, which does not exist.
    if (std.mem.indexOfScalar(u8, object_id, '.') != null) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

pub fn validateEntities(entities: Entities) ValidationError!void {
    for ([_][]const []const u8{ entities.light, entities.temperature, entities.fan }) |group| {
        if (group.len > max_entities_per_group) return error.TooManyEntities;
        for (group) |entity| if (!validEntityId(entity)) return error.InvalidEntityId;
    }
    const groups = [_][]const []const u8{ entities.light, entities.temperature, entities.fan };
    for (groups, 0..) |group, group_index| {
        for (group, 0..) |entity, entity_index| {
            // Check the remainder of this group and every later group. One id
            // in two roles is ambiguous because control authorization needs a
            // single group.
            for (group[entity_index + 1 ..]) |other|
                if (std.mem.eql(u8, entity, other)) return error.DuplicateEntity;
            for (groups[group_index + 1 ..]) |later| {
                for (later) |other|
                    if (std.mem.eql(u8, entity, other)) return error.DuplicateEntity;
            }
        }
    }
}

pub const LoadError = error{
    NotFound,
    /// The file exists but is not a configuration we understand.
    Corrupt,
    OutOfMemory,
    AccessDenied,
    Unexpected,
};

/// Configuration file, kept beside the Bambu credentials in the state
/// directory. It is a separate file on purpose: signing out of Bambu Lab must
/// not discard the user's Home Assistant setup, and the two credentials have
/// nothing to do with each other.
pub const Store = struct {
    io: Io,
    /// Directory holding the configuration file. Owned by the caller.
    dir: []const u8,

    const file_name = "homeassistant.json";

    pub fn path(self: Store, arena: Allocator) Allocator.Error![]const u8 {
        return std.fs.path.join(arena, &.{ self.dir, file_name });
    }

    /// Everything returned is allocated in `arena`.
    pub fn load(self: Store, arena: Allocator) LoadError!Config {
        const full_path = try self.path(arena);
        const bytes = Io.Dir.cwd().readFileAlloc(
            self.io,
            full_path,
            arena,
            .limited(64 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            error.OutOfMemory => return error.OutOfMemory,
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            else => return error.Unexpected,
        };

        const parsed = std.json.parseFromSliceLeaky(Config, arena, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return error.Corrupt;

        if (parsed.base_url.len == 0 or parsed.token.len == 0) return error.Corrupt;
        return parsed;
    }

    pub const SaveError = error{ OutOfMemory, AccessDenied, Unexpected };

    pub fn save(self: Store, gpa: Allocator, config: Config) SaveError!void {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, self.dir) catch |err| switch (err) {
            // Same DynamicUser StateDirectory symlink case as the credentials
            // store: an existing symlink reports NotDir but is fine to write
            // through.
            error.PathAlreadyExists, error.NotDir => {},
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            else => {
                std.log.err("could not prepare state directory '{s}': {t}", .{ self.dir, err });
                return error.Unexpected;
            },
        };

        const json = try std.json.Stringify.valueAlloc(gpa, config, .{ .whitespace = .indent_2 });
        defer gpa.free(json);

        const full_path = try self.path(gpa);
        defer gpa.free(full_path);

        var atomic_file = cwd.createFileAtomic(self.io, full_path, .{
            .permissions = credentials.private_file,
            .make_path = true,
            .replace = true,
        }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            else => {
                std.log.err("could not write Home Assistant config in '{s}': {t}", .{ self.dir, err });
                return error.Unexpected;
            },
        };
        defer atomic_file.deinit(self.io);

        var buffer: [4096]u8 = undefined;
        var writer = atomic_file.file.writer(self.io, &buffer);
        writer.interface.writeAll(json) catch return error.Unexpected;
        writer.flush() catch return error.Unexpected;
        atomic_file.replace(self.io) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            else => {
                std.log.err("could not replace Home Assistant config in '{s}': {t}", .{ self.dir, err });
                return error.Unexpected;
            },
        };
    }

    pub const DeleteError = error{ NotFound, OutOfMemory, AccessDenied, Unexpected };

    pub fn delete(self: Store, gpa: Allocator) DeleteError!void {
        const full_path = try self.path(gpa);
        defer gpa.free(full_path);

        Io.Dir.cwd().deleteFile(self.io, full_path) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            else => return error.Unexpected,
        };
    }
};

pub const ProbeError = error{
    /// The token was rejected. Long-lived tokens do not expire on their own but
    /// can be revoked from the user's Home Assistant profile.
    Unauthorized,
    /// Could not reach the host at all: wrong address, down, or — most often on
    /// a home network — an `https://` URL with a self-signed certificate, which
    /// this client does not accept.
    Unreachable,
    /// Reached something, but it does not answer like Home Assistant.
    NotHomeAssistant,
    OutOfMemory,
};

pub const ApiError = ProbeError || error{InvalidResponse};

pub const EntityGroup = enum { light, temperature, fan };

/// Small, stable view of a Home Assistant state for the dashboard. Raw HA
/// attributes are intentionally not exposed: they vary by integration and can
/// contain device-specific data the UI neither needs nor understands.
pub const EntityState = struct {
    entity_id: []const u8,
    group: EntityGroup,
    name: []const u8,
    state: []const u8,
    available: bool,
    unit: ?[]const u8,
    value: ?f64,
    on: ?bool,
    brightness_percent: ?u8,
    supports_brightness: bool,
    percentage: ?u8,
    supports_percentage: bool,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    http: std.http.Client,

    pub fn init(gpa: Allocator, io: Io) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .http = .{
                .allocator = gpa,
                .io = io,
                // Must stay null: a non-null `now` makes std.http.Client skip
                // loading the CA bundle and every TLS handshake then fails with
                // TlsCertificateNotVerified. Same trap as `cloud.Client`.
                .now = null,
            },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    /// Confirms the URL points at a Home Assistant that accepts the token.
    ///
    /// `GET /api/` is the cheapest authenticated endpoint: it answers
    /// `{"message": "API running."}` without touching any integration.
    pub fn probe(
        self: *Client,
        arena: Allocator,
        base_url: []const u8,
        token: []const u8,
    ) ProbeError!void {
        const url = try std.fmt.allocPrint(arena, "{s}/api/", .{base_url});
        const uri = std.Uri.parse(url) catch return error.Unreachable;
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});

        var req = self.http.request(.GET, uri, .{
            .headers = .{
                .authorization = .{ .override = authorization },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
        }) catch return error.Unreachable;
        defer req.deinit();

        req.sendBodiless() catch return error.Unreachable;

        var redirect_buffer: [4 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.Unreachable;

        var transfer_buffer: [256]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);
        // The body is a one-line JSON object; anything larger is not the
        // endpoint we asked for.
        const body = body_reader.allocRemaining(arena, .limited(8 * 1024)) catch "";

        log.debug("home assistant probe {s} -> {d} ({d} bytes)", .{
            url,
            @intFromEnum(response.head.status),
            body.len,
        });

        return switch (response.head.status) {
            .ok => if (std.mem.indexOf(u8, body, "API running") != null) {} else error.NotHomeAssistant,
            .unauthorized, .forbidden => error.Unauthorized,
            else => error.NotHomeAssistant,
        };
    }

    /// Fetches Home Assistant's state registry once and projects only the
    /// configured entities. This runs when a modal opens or refreshes, never in
    /// the dashboard's one-second printer poll.
    pub fn states(
        self: *Client,
        arena: Allocator,
        config: Config,
    ) ApiError![]EntityState {
        const url = try std.fmt.allocPrint(arena, "{s}/api/states", .{config.base_url});
        const reply = try self.request(arena, .GET, url, config.token, null, .limited(8 * 1024 * 1024));
        if (reply.status == .unauthorized or reply.status == .forbidden) return error.Unauthorized;
        if (reply.status != .ok) return error.InvalidResponse;

        const parsed = std.json.parseFromSlice(std.json.Value, arena, reply.body, .{}) catch
            return error.InvalidResponse;
        const list = switch (parsed.value) {
            .array => |a| a,
            else => return error.InvalidResponse,
        };

        var out: std.ArrayList(EntityState) = .empty;
        try out.ensureTotalCapacity(arena, config.entities.total());
        const groups = [_]struct { group: EntityGroup, ids: []const []const u8 }{
            .{ .group = .light, .ids = config.entities.light },
            .{ .group = .temperature, .ids = config.entities.temperature },
            .{ .group = .fan, .ids = config.entities.fan },
        };
        // Preserve the order from Settings and include configured ids that HA
        // did not return. A missing entity is actionable information in the
        // modal; silently dropping it would make a typo look like an empty list.
        for (groups) |configured| {
            for (configured.ids) |entity_id| {
                const object = findState(list, entity_id) orelse {
                    out.appendAssumeCapacity(missingState(entity_id, configured.group));
                    continue;
                };
                out.appendAssumeCapacity(projectState(entity_id, configured.group, object));
            }
        }
        return out.items;
    }

    /// Calls one Home Assistant service. The caller is responsible for proving
    /// that the entity is configured and the service is allowed for its group.
    pub fn callService(
        self: *Client,
        arena: Allocator,
        config: Config,
        domain: []const u8,
        service: []const u8,
        body: anytype,
    ) ApiError!void {
        const url = try std.fmt.allocPrint(arena, "{s}/api/services/{s}/{s}", .{
            config.base_url,
            domain,
            service,
        });
        const json = try std.json.Stringify.valueAlloc(arena, body, .{});
        const reply = try self.request(arena, .POST, url, config.token, json, .limited(1024 * 1024));
        if (reply.status == .unauthorized or reply.status == .forbidden) return error.Unauthorized;
        if (@intFromEnum(reply.status) < 200 or @intFromEnum(reply.status) >= 300)
            return error.InvalidResponse;
    }

    const Reply = struct {
        status: std.http.Status,
        body: []const u8,
    };

    fn request(
        self: *Client,
        arena: Allocator,
        method: std.http.Method,
        url: []const u8,
        token: []const u8,
        json_body: ?[]const u8,
        limit: Io.Limit,
    ) ApiError!Reply {
        const uri = std.Uri.parse(url) catch return error.Unreachable;
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
        var req = self.http.request(method, uri, .{
            .headers = .{
                .authorization = .{ .override = authorization },
                .accept_encoding = .{ .override = "identity" },
                .content_type = if (json_body != null)
                    .{ .override = "application/json" }
                else
                    .omit,
            },
            .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
        }) catch return error.Unreachable;
        defer req.deinit();

        if (json_body) |json| {
            req.transfer_encoding = .{ .content_length = json.len };
            var body = req.sendBodyUnflushed(&.{}) catch return error.Unreachable;
            body.writer.writeAll(json) catch return error.Unreachable;
            body.end() catch return error.Unreachable;
            req.connection.?.flush() catch return error.Unreachable;
        } else {
            req.sendBodiless() catch return error.Unreachable;
        }

        var redirect_buffer: [4 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.Unreachable;
        var transfer_buffer: [256]u8 = undefined;
        const body = response.reader(&transfer_buffer).allocRemaining(arena, limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };

        log.debug("home assistant {s} {s} -> {d} ({d} bytes)", .{
            @tagName(method),
            url,
            @intFromEnum(response.head.status),
            body.len,
        });
        return .{ .status = response.head.status, .body = body };
    }
};

pub fn configuredGroup(entities: Entities, entity_id: []const u8) ?EntityGroup {
    for (entities.light) |id| if (std.mem.eql(u8, id, entity_id)) return .light;
    for (entities.temperature) |id| if (std.mem.eql(u8, id, entity_id)) return .temperature;
    for (entities.fan) |id| if (std.mem.eql(u8, id, entity_id)) return .fan;
    return null;
}

pub fn entityDomain(entity_id: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, entity_id, '.') orelse return null;
    return if (dot == 0) null else entity_id[0..dot];
}

fn findState(list: std.json.Array, entity_id: []const u8) ?std.json.ObjectMap {
    for (list.items) |item| {
        const object = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (std.mem.eql(u8, stringField(object, "entity_id") orelse continue, entity_id))
            return object;
    }
    return null;
}

fn missingState(entity_id: []const u8, group: EntityGroup) EntityState {
    return .{
        .entity_id = entity_id,
        .group = group,
        .name = entity_id,
        .state = "not found",
        .available = false,
        .unit = null,
        .value = null,
        .on = if (group == .light or group == .fan) false else null,
        .brightness_percent = null,
        .supports_brightness = false,
        .percentage = null,
        .supports_percentage = false,
    };
}

fn projectState(entity_id: []const u8, group: EntityGroup, object: std.json.ObjectMap) EntityState {
    const state = stringField(object, "state") orelse "unknown";
    const attributes = switch (object.get("attributes") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const name = stringField(attributes, "friendly_name") orelse entity_id;
    const brightness = numberField(attributes, "brightness");
    const percentage = numberField(attributes, "percentage");
    const supported_features = integerField(attributes, "supported_features") orelse 0;
    const available = !std.mem.eql(u8, state, "unavailable") and !std.mem.eql(u8, state, "unknown");

    return .{
        .entity_id = entity_id,
        .group = group,
        .name = name,
        .state = state,
        .available = available,
        .unit = stringField(attributes, "unit_of_measurement"),
        .value = if (group == .temperature) std.fmt.parseFloat(f64, state) catch null else null,
        .on = if (group == .light or group == .fan) std.mem.eql(u8, state, "on") else null,
        .brightness_percent = if (brightness) |v| percentFrom255(v) else null,
        .supports_brightness = group == .light and supportsBrightness(attributes),
        .percentage = if (percentage) |v| clampPercent(v) else null,
        // FanEntityFeature.SET_SPEED is bit 0 in Home Assistant.
        .supports_percentage = group == .fan and (supported_features & 1) != 0,
    };
}

fn supportsBrightness(attributes: std.json.ObjectMap) bool {
    if (attributes.get("brightness") != null) return true;
    const modes = switch (attributes.get("supported_color_modes") orelse .null) {
        .array => |a| a,
        else => return false,
    };
    for (modes.items) |mode| switch (mode) {
        .string => |s| if (!std.mem.eql(u8, s, "onoff")) return true,
        else => {},
    };
    return false;
}

fn percentFrom255(value: f64) u8 {
    return clampPercent(value * 100.0 / 255.0);
}

fn clampPercent(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 100)));
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (object.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn numberField(object: std.json.ObjectMap, name: []const u8) ?f64 {
    return switch (object.get(name) orelse return null) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .string, .number_string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => null,
    };
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (object.get(name) orelse return null) {
        .integer => |v| v,
        .string, .number_string => |v| std.fmt.parseInt(i64, v, 10) catch null,
        else => null,
    };
}

test normalizeBaseUrl {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "http://homeassistant.local:8123",
        try normalizeBaseUrl(arena, "http://homeassistant.local:8123"),
    );
    // Trailing slashes and pasted paths are the two common shapes.
    try std.testing.expectEqualStrings(
        "http://homeassistant.local:8123",
        try normalizeBaseUrl(arena, "  http://homeassistant.local:8123/  "),
    );
    try std.testing.expectEqualStrings(
        "https://ha.example.com",
        try normalizeBaseUrl(arena, "https://ha.example.com/lovelace/0"),
    );
    try std.testing.expectEqualStrings(
        "http://192.168.1.20:8123",
        try normalizeBaseUrl(arena, "http://192.168.1.20:8123"),
    );

    try std.testing.expectError(error.InvalidUrl, normalizeBaseUrl(arena, ""));
    // A bare host is ambiguous about scheme, so it is rejected rather than
    // guessed at.
    try std.testing.expectError(error.InvalidUrl, normalizeBaseUrl(arena, "homeassistant.local:8123"));
    try std.testing.expectError(error.InvalidUrl, normalizeBaseUrl(arena, "ftp://ha.example.com"));
}

test validEntityId {
    try std.testing.expect(validEntityId("light.kitchen_ceiling"));
    try std.testing.expect(validEntityId("sensor.office_temperature_2"));
    try std.testing.expect(validEntityId("fan.p1s_enclosure"));

    try std.testing.expect(!validEntityId("light"));
    try std.testing.expect(!validEntityId("light."));
    try std.testing.expect(!validEntityId(".kitchen"));
    try std.testing.expect(!validEntityId("light.kitchen.ceiling"));
    // Home Assistant ids are lowercase; accepting these would store an id that
    // never matches anything.
    try std.testing.expect(!validEntityId("Light.Kitchen"));
    try std.testing.expect(!validEntityId("light.kitchen ceiling"));
    try std.testing.expect(!validEntityId(""));
}

test validateEntities {
    try validateEntities(.{
        .light = &.{ "light.kitchen", "switch.desk_plug" },
        .temperature = &.{"sensor.office_temperature"},
        .fan = &.{"fan.enclosure"},
    });
    // An empty configuration is legitimate: the user may only care about one
    // group, or none yet.
    try validateEntities(.{});

    try std.testing.expectError(error.InvalidEntityId, validateEntities(.{
        .light = &.{"not-an-entity"},
    }));
    try std.testing.expectError(error.InvalidEntityId, validateEntities(.{
        .fan = &.{ "fan.ok", "FAN.Bad" },
    }));
    try std.testing.expectError(error.DuplicateEntity, validateEntities(.{
        .light = &.{"switch.desk"},
        .fan = &.{"switch.desk"},
    }));

    var many: [max_entities_per_group + 1][]const u8 = undefined;
    for (&many) |*slot| slot.* = "light.bulb";
    try std.testing.expectError(error.TooManyEntities, validateEntities(.{ .light = &many }));
}

test "state projection exposes supported controls" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"entity_id":"light.desk","state":"on","attributes":{"friendly_name":"Desk lamp","brightness":128,"supported_color_modes":["brightness"]}}
    , .{});
    defer parsed.deinit();

    const projected = projectState("light.desk", .light, parsed.value.object);
    try std.testing.expectEqualStrings("Desk lamp", projected.name);
    try std.testing.expect(projected.on.?);
    try std.testing.expect(projected.supports_brightness);
    try std.testing.expectEqual(@as(u8, 50), projected.brightness_percent.?);

    var fan_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"entity_id":"fan.office","state":"on","attributes":{"percentage":67,"supported_features":1}}
    , .{});
    defer fan_parsed.deinit();
    const fan = projectState("fan.office", .fan, fan_parsed.value.object);
    try std.testing.expect(fan.supports_percentage);
    try std.testing.expectEqual(@as(u8, 67), fan.percentage.?);
}

test "state projection handles readings and unavailable entities" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"entity_id":"sensor.office_temperature","state":"21.75","attributes":{"friendly_name":"Office","unit_of_measurement":"°C"}}
    , .{});
    defer parsed.deinit();

    const temperature = projectState("sensor.office_temperature", .temperature, parsed.value.object);
    try std.testing.expectApproxEqAbs(@as(f64, 21.75), temperature.value.?, 0.001);
    try std.testing.expectEqualStrings("°C", temperature.unit.?);

    const missing = missingState("light.missing", .light);
    try std.testing.expect(!missing.available);
    try std.testing.expectEqualStrings("not found", missing.state);
}
