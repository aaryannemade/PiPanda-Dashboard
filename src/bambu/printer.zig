//! A live session with one printer: MQTT transport plus the accumulated status
//! document, plus the handful of commands the dashboard needs to send.
//!
//! Two transports, same protocol on top:
//!
//!   * `.cloud` — `us.mqtt.bambulab.com:8883`, authenticated with the account's
//!     access token. Works from anywhere, dies when the token expires.
//!   * `.lan`   — the printer's own broker on port 8883, authenticated with the
//!     LAN access code. Lower latency, no token expiry, no internet dependency,
//!     but requires "LAN Mode Liveview" to be reachable and a self-signed
//!     certificate to be accepted. This is the better option for a Pi sitting on
//!     the same network as the printer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = @import("../log.zig");
const mqtt = @import("../net/mqtt.zig");
const cloud = @import("cloud.zig");
const status_mod = @import("status.zig");
const signing = @import("signing.zig");

pub const Status = status_mod.Status;
pub const Snapshot = status_mod.Snapshot;

pub const Transport = union(enum) {
    cloud: struct {
        region: cloud.Region,
        /// `u_<uid>`.
        username: []const u8,
        access_token: []const u8,
    },
    lan: struct {
        host: []const u8,
        access_code: []const u8,
        /// Cloud MQTT username (`u_<uid>`), reused for signed LAN commands.
        user_id: []const u8,
    },
};

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    device_id: []const u8,
    /// Numeric Bambu account id, without the MQTT username's `u_` prefix.
    user_id: []const u8,
    client: *mqtt.Client,
    status: Status,
    signer: ?signing.Signer,
    /// Topics, built once at connect time.
    report_topic: []const u8,
    request_topic: []const u8,
    status_mutex: Io.Mutex,
    command_mutex: Io.Mutex,
    acknowledgement: Acknowledgement = .{},
    certificate_sequence: ?u32 = null,
    certificate_result: enum { pending, accepted, rejected } = .pending,
    /// Signed firmware expects application-style sequence ids. Starting in
    /// Studio's 20000-29999 window also avoids the signed-frame floor.
    sequence_id: u32 = 20_000,
    /// Scratch for rendering `sequence_id`, so callers do not have to manage an
    /// allocation for every command.
    sequence_buf: [12]u8 = undefined,
    /// Diagnostic hook: if set, every raw report payload is written here
    /// verbatim before being merged.
    raw_sink: ?*Io.Writer = null,

    pub const ConnectError = mqtt.ConnectError || signing.SignError;

    pub fn connect(
        gpa: Allocator,
        io: Io,
        device_id: []const u8,
        transport: Transport,
        state_dir: []const u8,
    ) ConnectError!*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        const report_topic = try std.fmt.allocPrint(gpa, "device/{s}/report", .{device_id});
        errdefer gpa.free(report_topic);
        const request_topic = try std.fmt.allocPrint(gpa, "device/{s}/request", .{device_id});
        errdefer gpa.free(request_topic);

        var signer = signing.Signer.load(gpa, io, state_dir) catch |err| switch (err) {
            error.FileNotFound => null,
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                // Bad signing material must not break monitoring/light control.
                std.log.warn("signing credentials unavailable ({t}); run just signing-setup and restart to enable signed controls", .{err});
                break :blk null;
            },
        };
        errdefer if (signer) |*s| s.deinit();
        const user_id = try gpa.dupe(u8, switch (transport) {
            .cloud => |c| withoutUserPrefix(c.username),
            .lan => |l| withoutUserPrefix(l.user_id),
        });
        errdefer gpa.free(user_id);
        var status = try Status.init(gpa);
        errdefer status.deinit();

        // The broker treats a duplicate client id as a takeover and kicks the
        // other session, so keep it unique-ish per process.
        var client_id_buf: [64]u8 = undefined;
        const now_ns: u96 = @bitCast(Io.Timestamp.now(io, .real).nanoseconds);
        const client_id = std.fmt.bufPrint(
            &client_id_buf,
            "pipanda-{x}",
            .{@as(u64, @truncate(now_ns))},
        ) catch unreachable;

        const options: mqtt.Client.Options = switch (transport) {
            .cloud => |c| .{
                .host = c.region.mqttHost(),
                .client_id = client_id,
                .username = c.username,
                .password = c.access_token,
                .trust = .system_ca,
            },
            .lan => |l| .{
                .host = l.host,
                .client_id = client_id,
                .username = "bblp",
                .password = l.access_code,
                // The printer's certificate is self-signed and issued for a
                // name that never matches the address you dial.
                .trust = .insecure_self_signed,
            },
        };

        const client = try mqtt.Client.connect(gpa, io, options);
        errdefer client.close();

        self.* = .{
            .gpa = gpa,
            .io = io,
            .device_id = device_id,
            .user_id = user_id,
            .client = client,
            .status = status,
            .signer = signer,
            .report_topic = report_topic,
            .request_topic = request_topic,
            .status_mutex = .init,
            .command_mutex = .init,
            .sequence_id = 20_000 + @as(u32, @intCast(now_ns % 10_000)),
        };

        log.debug("session: transport={s} device={s} topic={s}", .{
            @tagName(transport),
            device_id,
            report_topic,
        });

        try client.subscribe(report_topic);
        // Signed commands are accepted only while the app certificate is in
        // the printer's RAM trust store. Re-install on every connection; the
        // printer clears it on reboot. This bootstrap command is unsigned.
        if (self.signer != null) try self.installAppCertificate();
        // The P1 only sends deltas, so the accumulated document starts empty
        // until we ask for everything once.
        try self.requestFullStatus();

        return self;
    }

    pub fn close(self: *Session) void {
        if (self.signer) |*s| s.deinit();
        self.status.deinit();
        self.client.close();
        self.gpa.free(self.report_topic);
        self.gpa.free(self.request_topic);
        self.gpa.free(self.user_id);
        self.gpa.destroy(self);
    }

    pub const Event = enum { status_updated, other_report };

    pub const PumpError = mqtt.ReadError || error{InvalidJson};

    /// Blocks until the next report arrives and folds it into `status`.
    pub fn pump(self: *Session) PumpError!Event {
        while (true) {
            const message = try self.client.nextMessage(self.gpa);
            defer message.deinit(self.gpa);

            // We only subscribed to one topic, but be explicit.
            if (!std.mem.eql(u8, message.topic, self.report_topic)) continue;

            log.debug("report: {d} bytes", .{message.payload.len});
            if (self.raw_sink) |sink| {
                sink.print("{s}\n", .{message.payload}) catch {};
                sink.flush() catch {};
            }

            self.status_mutex.lock(self.io) catch return error.Canceled;
            defer self.status_mutex.unlock(self.io);
            // Match replies before deep-merging: a later push_status changes
            // command/sequence_id while stale err_code fields can remain.
            // Avoid a second JSON parse on ordinary status deltas on the Pi.
            if (self.certificate_sequence != null or (self.acknowledgement.sequence_id != null and !self.acknowledgement.done)) {
                const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, message.payload, .{}) catch null;
                if (parsed) |p| {
                    defer p.deinit();
                    self.acknowledgement.observe(p.value);
                    if (self.certificate_sequence) |id| {
                        var certificate_ack: Acknowledgement = .{ .sequence_id = id, .command = "app_cert_install" };
                        certificate_ack.observeSection(p.value, "security");
                        if (certificate_ack.done) {
                            self.certificate_result = if (certificate_ack.error_code == 0) .accepted else .rejected;
                            self.certificate_sequence = null;
                            log.debug("app certificate registration: {s}", .{@tagName(self.certificate_result)});
                        }
                    }
                }
            }
            return switch (try self.status.apply(message.payload)) {
                .print => .status_updated,
                .other => .other_report,
            };
        }
    }

    /// Runs the MQTT keepalive. Intended for `Io.Group.concurrent`.
    pub fn keepAlive(self: *Session) Io.Cancelable!void {
        return self.client.keepAliveLoop();
    }

    pub const CommandError = mqtt.WriteError || signing.SignError;
    pub const PrintCommandError = CommandError || error{
        PrinterRejectedCommand,
        CommandTimedOut,
        CommandSigningRequired,
        AppCertificateNotTrusted,
        InvalidCommandSignature,
    };

    /// Asks for the complete status object.
    ///
    /// Bambu's own guidance is not to do this more than once every five minutes
    /// on a P1: the MCU is slow enough that serialising the whole document
    /// visibly stutters a print.
    pub fn requestFullStatus(self: *Session) CommandError!void {
        self.command_mutex.lock(self.io) catch return error.Canceled;
        defer self.command_mutex.unlock(self.io);
        try self.sendCommand(.{ .pushing = .{
            .sequence_id = self.takeSequenceId(),
            .command = "pushall",
            .version = 1,
            .push_target = 1,
        } });
    }

    fn installAppCertificate(self: *Session) CommandError!void {
        const signer = self.signer orelse return;
        self.command_mutex.lock(self.io) catch return error.Canceled;
        defer self.command_mutex.unlock(self.io);
        const sequence_id = self.takeSequenceId();
        self.certificate_sequence = std.fmt.parseInt(u32, sequence_id, 10) catch unreachable;
        try self.sendCommand(.{ .security = .{
            .sequence_id = sequence_id,
            .command = "app_cert_install",
            .app_cert = signer.cert_pem,
            .crl = signer.crl_pem,
        } });
    }

    pub const LedMode = enum { on, off, flashing };

    /// Chamber light control. This is the hook the Home Assistant side will use
    /// to keep the printer light in sync with the room lights.
    pub fn setChamberLight(self: *Session, mode: LedMode) CommandError!void {
        self.command_mutex.lock(self.io) catch return error.Canceled;
        defer self.command_mutex.unlock(self.io);
        try self.sendCommand(.{
            .system = .{
                .sequence_id = self.takeSequenceId(),
                .command = "ledctrl",
                .led_node = "chamber_light",
                .led_mode = @tagName(mode),
                // Required by the firmware even when not flashing.
                .led_on_time = 500,
                .led_off_time = 500,
                .loop_times = 0,
                .interval_time = 0,
            },
        });
    }

    pub const PrintAction = enum { pause, @"resume", stop };

    /// Pauses, resumes or cancels the current job, as Bambu Handy does. The
    /// firmware ignores an action that does not fit the current state, such as
    /// resuming a running print.
    pub fn controlPrint(self: *Session, action: PrintAction) PrintCommandError!void {
        self.command_mutex.lock(self.io) catch return error.Canceled;
        defer self.command_mutex.unlock(self.io);
        const sequence_id = self.takeSequenceId();
        try self.expectAcknowledgement(sequence_id, @tagName(action));
        try self.sendCommand(.{ .print = .{
            .sequence_id = sequence_id,
            .command = @tagName(action),
            .param = "",
        } });
        try self.waitForAcknowledgement();
    }

    /// The four speed profiles. Tag values are what the firmware reports back
    /// as `spd_lvl`.
    pub const SpeedLevel = enum(u8) {
        silent = 1,
        standard = 2,
        sport = 3,
        ludicrous = 4,
    };

    pub fn setPrintSpeed(self: *Session, level: SpeedLevel) PrintCommandError!void {
        self.command_mutex.lock(self.io) catch return error.Canceled;
        defer self.command_mutex.unlock(self.io);
        var param_buf: [3]u8 = undefined;
        const param = std.fmt.bufPrint(&param_buf, "{d}", .{@intFromEnum(level)}) catch unreachable;
        const sequence_id = self.takeSequenceId();
        try self.expectAcknowledgement(sequence_id, "print_speed");
        try self.sendCommand(.{
            .print = .{
                .sequence_id = sequence_id,
                .command = "print_speed",
                // The firmware wants the level as a string, like `sequence_id`.
                .param = param,
            },
        });
        try self.waitForAcknowledgement();
    }

    fn expectAcknowledgement(self: *Session, id: []const u8, command: []const u8) PrintCommandError!void {
        if (self.signer != null) {
            const start = Io.Timestamp.now(self.io, .awake);
            while (true) {
                try self.status_mutex.lock(self.io);
                const result = self.certificate_result;
                self.status_mutex.unlock(self.io);
                if (result == .accepted) break;
                if (result == .rejected or Io.Timestamp.now(self.io, .awake).nanoseconds - start.nanoseconds >= 8 * std.time.ns_per_s)
                    return error.AppCertificateNotTrusted;
                try self.io.sleep(.fromMilliseconds(50), .awake);
            }
        }
        try self.status_mutex.lock(self.io);
        defer self.status_mutex.unlock(self.io);
        self.acknowledgement = .{
            .sequence_id = std.fmt.parseInt(u32, id, 10) catch unreachable,
            .command = command,
        };
    }

    fn waitForAcknowledgement(self: *Session) PrintCommandError!void {
        defer {
            self.status_mutex.lockUncancelable(self.io);
            self.acknowledgement = .{};
            self.status_mutex.unlock(self.io);
        }
        const start = Io.Timestamp.now(self.io, .awake);
        while (true) {
            try self.status_mutex.lock(self.io);
            const ack = self.acknowledgement;
            self.status_mutex.unlock(self.io);
            if (ack.done) {
                return switch (ack.error_code) {
                    0 => {},
                    84033543 => error.CommandSigningRequired,
                    84033545 => error.AppCertificateNotTrusted,
                    84033546...84033548 => error.InvalidCommandSignature,
                    else => error.PrinterRejectedCommand,
                };
            }
            if (Io.Timestamp.now(self.io, .awake).nanoseconds - start.nanoseconds >= 8 * std.time.ns_per_s)
                return error.CommandTimedOut;
            try self.io.sleep(.fromMilliseconds(50), .awake);
        }
    }

    /// Toggles the printer's own timelapse capture. pipanda records its own
    /// footage from the Pi camera, so this is mainly here to turn Bambu's
    /// version off.
    pub fn setPrinterTimelapse(self: *Session, enabled: bool) CommandError!void {
        self.command_mutex.lock(self.io) catch return error.Canceled;
        defer self.command_mutex.unlock(self.io);
        try self.sendCommand(.{ .camera = .{
            .sequence_id = self.takeSequenceId(),
            .command = "ipcam_timelapse",
            .control = if (enabled) "enable" else "disable",
        } });
    }

    pub fn statusJson(self: *Session, gpa: Allocator) ![]u8 {
        self.status_mutex.lock(self.io) catch return error.Canceled;
        defer self.status_mutex.unlock(self.io);
        return self.status.toJson(gpa);
    }

    pub fn dashboardJson(
        self: *Session,
        gpa: Allocator,
        meta: Status.DashboardMeta,
    ) ![]u8 {
        self.status_mutex.lock(self.io) catch return error.Canceled;
        defer self.status_mutex.unlock(self.io);
        return self.status.dashboardJson(gpa, meta);
    }

    /// The current job name, duplicated so it survives the next status merge
    /// (which frees the accumulated document's arena every 512 reports).
    /// Null when the printer has never reported a job. Caller owns the result.
    pub fn subtaskName(self: *Session, gpa: Allocator) !?[]u8 {
        self.status_mutex.lock(self.io) catch return error.Canceled;
        defer self.status_mutex.unlock(self.io);
        const name = self.status.snapshot().subtask_name orelse return null;
        return try gpa.dupe(u8, name);
    }

    fn sendCommand(self: *Session, payload: anytype) CommandError!void {
        const unsigned = try std.json.Stringify.valueAlloc(self.gpa, payload, .{});
        defer self.gpa.free(unsigned);

        // Authorization-control firmware rejects unsigned `print` commands.
        // Other command families, including ledctrl and pushall, stay as-is.
        const wire = if (self.signer != null and std.mem.startsWith(u8, unsigned, "{\"print\":"))
            try self.signer.?.signCommand(self.gpa, unsigned, self.user_id)
        else
            try self.gpa.dupe(u8, unsigned);
        defer self.gpa.free(wire);

        // QoS 1 so control commands are not silently dropped.
        try self.client.publish(self.request_topic, wire, .at_least_once);
    }

    /// The firmware wants `sequence_id` as a decimal string.
    fn takeSequenceId(self: *Session) []const u8 {
        const id = self.sequence_id;
        self.sequence_id +%= 1;
        return std.fmt.bufPrint(&self.sequence_buf, "{d}", .{id}) catch unreachable;
    }
};

fn withoutUserPrefix(username: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, username, "u_")) username[2..] else username;
}

const Acknowledgement = struct {
    sequence_id: ?u32 = null,
    command: []const u8 = "",
    done: bool = false,
    error_code: i64 = 0,

    fn observe(self: *Acknowledgement, root: std.json.Value) void {
        self.observeSection(root, "print");
    }

    fn observeSection(self: *Acknowledgement, root: std.json.Value, section: []const u8) void {
        if (self.sequence_id == null or self.done or root != .object) return;
        const print = root.object.get(section) orelse return;
        if (print != .object) return;
        const command = print.object.get("command") orelse return;
        if (command != .string or !std.mem.eql(u8, command.string, self.command)) return;
        const id = print.object.get("sequence_id") orelse return;
        const number: u32 = switch (id) {
            .string => std.fmt.parseInt(u32, id.string, 10) catch return,
            .integer => std.math.cast(u32, id.integer) orelse return,
            else => return,
        };
        if (number != self.sequence_id.?) return;
        if (print.object.get("err_code")) |code| {
            if (code == .integer and code.integer != 0) {
                self.error_code = code.integer;
                self.done = true;
                return;
            }
        }
        const result = print.object.get("result") orelse return;
        if (result != .string) return;
        const success = std.ascii.eqlIgnoreCase(result.string, "success") or
            std.ascii.eqlIgnoreCase(result.string, "succeed") or
            std.ascii.eqlIgnoreCase(result.string, "ok");
        self.error_code = if (success) 0 else -1;
        self.done = true;
    }
};

test "command acknowledgements match both command and sequence, not merged status" {
    var ack: Acknowledgement = .{ .sequence_id = 20001, .command = "print_speed" };
    const reports = [_][]const u8{
        "{\"print\":{\"command\":\"push_status\",\"sequence_id\":\"20001\",\"err_code\":84033543}}",
        "{\"print\":{\"command\":\"print_speed\",\"sequence_id\":\"20000\",\"result\":\"success\"}}",
        "{\"print\":{\"command\":\"print_speed\",\"sequence_id\":\"20001\",\"err_code\":84033545}}",
    };
    for (reports, 0..) |report, i| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
        defer parsed.deinit();
        ack.observe(parsed.value);
        try std.testing.expectEqual(i == 2, ack.done);
    }
    try std.testing.expectEqual(@as(i64, 84033545), ack.error_code);
    ack = .{ .sequence_id = 20002, .command = "pause" };
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"print\":{\"command\":\"pause\",\"sequence_id\":20002,\"result\":\"SUCCESS\"}}", .{});
    defer parsed.deinit();
    ack.observe(parsed.value);
    try std.testing.expect(ack.done);
    try std.testing.expectEqual(@as(i64, 0), ack.error_code);

    ack = .{ .sequence_id = 20003, .command = "app_cert_install" };
    const cert_report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"security\":{\"command\":\"app_cert_install\",\"sequence_id\":\"20003\",\"result\":\"SUCCESS\"}}", .{});
    defer cert_report.deinit();
    ack.observeSection(cert_report.value, "security");
    try std.testing.expect(ack.done);
    try std.testing.expectEqual(@as(i64, 0), ack.error_code);
}
