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
            .chamber_temp = self.float("chamber_temper"),
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

pub const Snapshot = struct {
    gcode_state: ?[]const u8,
    subtask_name: ?[]const u8,
    print_percent: ?i64,
    remaining_minutes: ?i64,
    layer: ?i64,
    total_layers: ?i64,
    nozzle_temp: ?f64,
    nozzle_target: ?f64,
    bed_temp: ?f64,
    bed_target: ?f64,
    chamber_temp: ?f64,
    cooling_fan_percent: ?u8,
    aux_fan_percent: ?u8,
    chamber_fan_percent: ?u8,
    wifi_signal: ?[]const u8,
    speed_level: ?i64,
    print_error: ?i64,
    chamber_light_on: ?bool,
    active_hms_count: ?usize,
    nozzle_diameter: ?[]const u8,

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
