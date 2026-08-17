//! Accumulated printer state.
//!
//! The P1 series does not resend the whole status object: `print.push_status`
//! carries only the fields that changed since the last report, so a consumer has
//! to maintain the accumulated document itself. (The X1 sends the full object
//! every time, which is a special case of the same thing.)
//!
//! Rather than mirror Bambu's ~150-field schema into Zig structs — which would
//! silently drop anything they add in a firmware update — the accumulated state
//! is kept as a JSON object and reports are deep-merged into it. Typed access is
//! provided by `Snapshot` for the handful of fields the dashboard renders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const Status = struct {
    gpa: Allocator,
    /// Owns every key and value in `fields`.
    arena: *std.heap.ArenaAllocator,
    fields: ObjectMap,
    /// Merging replaces values without freeing the old ones, so the arena grows
    /// monotonically. We periodically rebuild it.
    merges_since_compact: u32 = 0,

    /// Chosen so a printer reporting every second compacts roughly every eight
    /// minutes.
    const compact_interval = 512;

    pub fn init(gpa: Allocator) Allocator.Error!Status {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        return .{
            .gpa = gpa,
            .arena = arena,
            .fields = .empty,
        };
    }

    pub fn deinit(self: *Status) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
        self.* = undefined;
    }

    pub const Report = enum {
        /// A `print` object: status was updated.
        print,
        /// Something we do not track (`info`, `mc_print`, `system`, `camera`...).
        other,
    };

    pub const ApplyError = error{ InvalidJson, OutOfMemory };

    /// Merges one MQTT report payload into the accumulated state.
    pub fn apply(self: *Status, payload: []const u8) ApplyError!Report {
        // The parse is transient; only the merged subset is retained.
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();

        const parsed = std.json.parseFromSliceLeaky(
            Value,
            scratch.allocator(),
            payload,
            .{},
        ) catch return error.InvalidJson;

        const root = switch (parsed) {
            .object => |o| o,
            else => return error.InvalidJson,
        };

        const print = switch (root.get("print") orelse return .other) {
            .object => |o| o,
            else => return .other,
        };

        try deepMerge(&self.fields, print, self.arena.allocator());

        self.merges_since_compact += 1;
        if (self.merges_since_compact >= compact_interval) try self.compact();
        return .print;
    }

    /// Rebuilds the accumulated state in a fresh arena, dropping the garbage
    /// left behind by overwritten values.
    fn compact(self: *Status) Allocator.Error!void {
        const fresh = try self.gpa.create(std.heap.ArenaAllocator);
        errdefer self.gpa.destroy(fresh);
        fresh.* = .init(self.gpa);
        errdefer fresh.deinit();

        var rebuilt: ObjectMap = .empty;
        try deepMerge(&rebuilt, self.fields, fresh.allocator());

        self.arena.deinit();
        self.gpa.destroy(self.arena);

        self.arena = fresh;
        self.fields = rebuilt;
        self.merges_since_compact = 0;
    }

    /// Serialises the accumulated state. Caller owns the result.
    pub fn toJson(self: *const Status, gpa: Allocator) Allocator.Error![]u8 {
        return std.json.Stringify.valueAlloc(gpa, Value{ .object = self.fields }, .{});
    }

    pub const DashboardMeta = struct {
        device_id: []const u8,
        name: []const u8,
        model: []const u8,
        camera_url: []const u8,
        online: bool,
    };

    /// Serialises the stable, frontend-facing projection of the accumulated
    /// printer document. Unsupported Handy cloud features are explicit so the
    /// frontend never has to infer support from a missing value.
    pub fn dashboardJson(
        self: *const Status,
        gpa: Allocator,
        meta: DashboardMeta,
    ) Allocator.Error![]u8 {
        const snap = self.snapshot();
        return std.json.Stringify.valueAlloc(gpa, .{
            .api_version = 1,
            .printer = .{
                .id = meta.device_id,
                .name = meta.name,
                .model = meta.model,
                .online = meta.online,
                .state = snap.gcode_state,
                .wifi_signal = snap.wifi_signal,
                .error_code = snap.print_error,
                .active_alerts = snap.active_hms_count,
            },
            .camera = .{
                .available = meta.camera_url.len != 0,
                .player_url = optionalString(meta.camera_url),
                .stream_name = "p1s",
            },
            .job = .{
                .name = snap.subtask_name,
                .profile = @as(?[]const u8, null),
                .thumbnail_url = @as(?[]const u8, null),
                .state = snap.gcode_state,
                .result = jobResult(snap.gcode_state),
                .progress_percent = snap.print_percent,
                .remaining_minutes = snap.remaining_minutes,
                .layer = snap.layer,
                .total_layers = snap.total_layers,
                .actions = .{
                    .print_again = false,
                    .rating = false,
                },
            },
            .controls = .{
                .temperatures = .{
                    .nozzle = .{ .current = snap.nozzle_temp, .target = snap.nozzle_target },
                    .bed = .{ .current = snap.bed_temp, .target = snap.bed_target },
                    .chamber = .{ .current = @as(?f64, null), .target = @as(?f64, null) },
                },
                .fans = .{
                    .cooling_percent = snap.cooling_fan_percent,
                    .aux_percent = snap.aux_fan_percent,
                    .chamber_percent = snap.chamber_fan_percent,
                },
                .light = .{ .available = true, .on = snap.chamber_light_on },
                .motion = .{ .available = false },
                .extruder = .{
                    .available = false,
                    .nozzle_diameter = snap.nozzle_diameter,
                },
            },
            .filament = .{
                // Keep these dynamic subdocuments intact. Bambu adds fields to
                // AMS trays across firmware versions and the frontend can use
                // the documented common fields without losing newer ones.
                .ams = self.valueOrNull("ams"),
                .external_spool = self.valueOrNull("vt_tray"),
                .library = .{ .available = false, .roll_count = @as(?usize, null) },
            },
            .capabilities = .{
                .light_control = true,
                .motion_control = false,
                .extruder_control = false,
                .print_again = false,
                .job_rating = false,
                .filament_library = false,
            },
        }, .{});
    }

    pub fn snapshot(self: *const Status) Snapshot {
        return .{
            .gcode_state = self.string("gcode_state"),
            .subtask_name = self.string("subtask_name"),
            .print_percent = self.int("mc_percent"),
            .remaining_minutes = self.int("mc_remaining_time"),
            .layer = self.int("layer_num"),
            .total_layers = self.int("total_layer_num"),
            .nozzle_temp = self.float("nozzle_temper"),
            .nozzle_target = self.float("nozzle_target_temper"),
            .bed_temp = self.float("bed_temper"),
            .bed_target = self.float("bed_target_temper"),
            // P1S firmware reports chamber_temper=5 despite having no chamber
            // probe. Preserve it in the raw document, but do not present it as
            // a measured value in the typed snapshot.
            .cooling_fan_percent = fanPercent(self.string("cooling_fan_speed")),
            .aux_fan_percent = fanPercent(self.string("big_fan1_speed")),
            .chamber_fan_percent = fanPercent(self.string("big_fan2_speed")),
            .wifi_signal = self.string("wifi_signal"),
            .speed_level = self.int("spd_lvl"),
            .print_error = self.int("print_error"),
            .chamber_light_on = self.lightOn("chamber_light"),
            .active_hms_count = self.arrayLen("hms"),
            .nozzle_diameter = self.string("nozzle_diameter"),
        };
    }

    fn string(self: *const Status, name: []const u8) ?[]const u8 {
        return switch (self.fields.get(name) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    fn int(self: *const Status, name: []const u8) ?i64 {
        return switch (self.fields.get(name) orelse return null) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            // Bambu is inconsistent about quoting numbers.
            .string, .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
            else => null,
        };
    }

    fn float(self: *const Status, name: []const u8) ?f64 {
        return switch (self.fields.get(name) orelse return null) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            .string, .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    fn arrayLen(self: *const Status, name: []const u8) ?usize {
        return switch (self.fields.get(name) orelse return null) {
            .array => |a| a.items.len,
            else => null,
        };
    }

    fn valueOrNull(self: *const Status, name: []const u8) Value {
        return self.fields.get(name) orelse .null;
    }

    /// `lights_report` is an array of `{ node, mode }` pairs.
    fn lightOn(self: *const Status, node: []const u8) ?bool {
        const list = switch (self.fields.get("lights_report") orelse return null) {
            .array => |a| a,
            else => return null,
        };
        for (list.items) |item| {
            const entry = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const entry_node = switch (entry.get("node") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, entry_node, node)) continue;
            const mode = switch (entry.get("mode") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            return !std.mem.eql(u8, mode, "off");
        }
        return null;
    }
};

fn optionalString(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}

fn jobResult(state: ?[]const u8) ?[]const u8 {
    const value = state orelse return null;
    if (std.mem.eql(u8, value, "FINISH")) return "success";
    if (std.mem.eql(u8, value, "FAILED")) return "failed";
    return null;
}

pub const Snapshot = struct {
    gcode_state: ?[]const u8 = null,
    subtask_name: ?[]const u8 = null,
    print_percent: ?i64 = null,
    remaining_minutes: ?i64 = null,
    layer: ?i64 = null,
    total_layers: ?i64 = null,
    nozzle_temp: ?f64 = null,
    nozzle_target: ?f64 = null,
    bed_temp: ?f64 = null,
    bed_target: ?f64 = null,
    cooling_fan_percent: ?u8 = null,
    aux_fan_percent: ?u8 = null,
    chamber_fan_percent: ?u8 = null,
    wifi_signal: ?[]const u8 = null,
    speed_level: ?i64 = null,
    print_error: ?i64 = null,
    chamber_light_on: ?bool = null,
    active_hms_count: ?usize = null,
    nozzle_diameter: ?[]const u8 = null,

    pub fn isPrinting(s: Snapshot) bool {
        const state = s.gcode_state orelse return false;
        return std.mem.eql(u8, state, "RUNNING") or std.mem.eql(u8, state, "PREPARE");
    }
};

/// Fan speeds are reported as a stringified 0-255 value.
fn fanPercent(raw: ?[]const u8) ?u8 {
    const text = raw orelse return null;
    const value = std.fmt.parseInt(u16, text, 10) catch return null;
    return @intCast(@min(100, (value * 100 + 127) / 255));
}

/// Recursively merges `src` into `dst`. Nested objects are merged key by key;
/// arrays and scalars are replaced wholesale, because the printer always resends
/// a whole array when any element of it changes.
fn deepMerge(dst: *ObjectMap, src: ObjectMap, arena: Allocator) Allocator.Error!void {
    for (src.keys(), src.values()) |key, value| {
        if (dst.getPtr(key)) |existing| {
            if (existing.* == .object and value == .object) {
                try deepMerge(&existing.object, value.object, arena);
                continue;
            }
            existing.* = try deepCopy(value, arena);
            continue;
        }
        try dst.put(arena, try arena.dupe(u8, key), try deepCopy(value, arena));
    }
}

fn deepCopy(value: Value, arena: Allocator) Allocator.Error!Value {
    return switch (value) {
        .null, .bool, .integer, .float => value,
        .number_string => |s| .{ .number_string = try arena.dupe(u8, s) },
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .array => |a| blk: {
            var out: std.json.Array = .init(arena);
            try out.ensureTotalCapacity(a.items.len);
            for (a.items) |item| out.appendAssumeCapacity(try deepCopy(item, arena));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: ObjectMap = .empty;
            try out.ensureTotalCapacity(arena, o.count());
            for (o.keys(), o.values()) |k, v| {
                out.putAssumeCapacity(try arena.dupe(u8, k), try deepCopy(v, arena));
            }
            break :blk .{ .object = out };
        },
    };
}

test "partial reports accumulate" {
    var status = try Status.init(std.testing.allocator);
    defer status.deinit();

    try std.testing.expectEqual(Status.Report.print, try status.apply(
        \\{"print":{"gcode_state":"IDLE","nozzle_temper":25.0,"layer_num":0,
        \\ "ipcam":{"resolution":"1080p","timelapse":"disable"}}}
    ));

    // A P1 partial update: only the changed fields are present.
    try std.testing.expectEqual(Status.Report.print, try status.apply(
        \\{"print":{"gcode_state":"RUNNING","layer_num":12,
        \\ "ipcam":{"timelapse":"enable"}}}
    ));

    const snap = status.snapshot();
    try std.testing.expectEqualStrings("RUNNING", snap.gcode_state.?);
    try std.testing.expectEqual(@as(i64, 12), snap.layer.?);
    // Untouched by the second report, so it must survive.
    try std.testing.expectEqual(@as(f64, 25.0), snap.nozzle_temp.?);

    // Nested objects merge rather than replace.
    const ipcam = status.fields.get("ipcam").?.object;
    try std.testing.expectEqualStrings("1080p", ipcam.get("resolution").?.string);
    try std.testing.expectEqualStrings("enable", ipcam.get("timelapse").?.string);
}

test "non-print reports are ignored" {
    var status = try Status.init(std.testing.allocator);
    defer status.deinit();

    try std.testing.expectEqual(Status.Report.other, try status.apply(
        \\{"mc_print":{"command":"push_info","param":"[LINK] ok"}}
    ));
    try std.testing.expectEqual(@as(usize, 0), status.fields.count());
}

test "compaction preserves state" {
    var status = try Status.init(std.testing.allocator);
    defer status.deinit();

    for (0..Status.compact_interval + 1) |i| {
        var buf: [128]u8 = undefined;
        const payload = try std.fmt.bufPrint(
            &buf,
            "{{\"print\":{{\"layer_num\":{d},\"ams\":{{\"tray_now\":\"{d}\"}}}}}}",
            .{ i, i % 4 },
        );
        _ = try status.apply(payload);
    }

    try std.testing.expect(status.merges_since_compact < Status.compact_interval);
    const snap = status.snapshot();
    try std.testing.expectEqual(@as(i64, Status.compact_interval), snap.layer.?);
}

test fanPercent {
    try std.testing.expectEqual(@as(u8, 0), fanPercent("0").?);
    try std.testing.expectEqual(@as(u8, 100), fanPercent("255").?);
    try std.testing.expectEqual(@as(u8, 50), fanPercent("127").?);
    try std.testing.expect(fanPercent(null) == null);
    try std.testing.expect(fanPercent("") == null);
}

test "dashboard projection exposes supported and unavailable Handy fields" {
    var status = try Status.init(std.testing.allocator);
    defer status.deinit();

    _ = try status.apply(
        \\{"print":{"gcode_state":"FINISH","subtask_name":"Benchy","mc_percent":100,
        \\ "nozzle_temper":38,"nozzle_target_temper":0,"lights_report":[{"node":"chamber_light","mode":"on"}],
        \\ "ams":{"tray_now":"0","ams":[{"id":"0","humidity":"3","tray":[{"id":"0","tray_type":"PLA","tray_color":"FF6A00FF"}]}]}}}
    );

    const json = try status.dashboardJson(std.testing.allocator, .{
        .device_id = "01P00A",
        .name = "Panda",
        .model = "P1S",
        .camera_url = "/camera/p1s",
        .online = true,
    });
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("Panda", root.get("printer").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("success", root.get("job").?.object.get("result").?.string);
    try std.testing.expect(root.get("controls").?.object.get("light").?.object.get("on").?.bool);
    try std.testing.expect(!root.get("capabilities").?.object.get("motion_control").?.bool);
    try std.testing.expectEqualStrings(
        "PLA",
        root.get("filament").?.object.get("ams").?.object.get("ams").?.array.items[0].object
            .get("tray").?.array.items[0].object.get("tray_type").?.string,
    );
}
