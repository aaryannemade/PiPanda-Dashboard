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
    },
};

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    device_id: []const u8,
    client: *mqtt.Client,
    status: Status,
    /// Topics, built once at connect time.
    report_topic: []const u8,
    request_topic: []const u8,
    status_mutex: Io.Mutex,
    command_mutex: Io.Mutex,
    sequence_id: u32 = 1,
    /// Scratch for rendering `sequence_id`, so callers do not have to manage an
    /// allocation for every command.
    sequence_buf: [12]u8 = undefined,
    /// Diagnostic hook: if set, every raw report payload is written here
    /// verbatim before being merged.
    raw_sink: ?*Io.Writer = null,

    pub const ConnectError = mqtt.ConnectError || error{OutOfMemory};

    pub fn connect(
        gpa: Allocator,
        io: Io,
        device_id: []const u8,
        transport: Transport,
    ) ConnectError!*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        const report_topic = try std.fmt.allocPrint(gpa, "device/{s}/report", .{device_id});
        errdefer gpa.free(report_topic);
        const request_topic = try std.fmt.allocPrint(gpa, "device/{s}/request", .{device_id});
        errdefer gpa.free(request_topic);

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
            .client = client,
            .status = try Status.init(gpa),
            .report_topic = report_topic,
            .request_topic = request_topic,
            .status_mutex = .init,
            .command_mutex = .init,
        };
        errdefer self.status.deinit();

        log.debug("session: transport={s} device={s} topic={s}", .{
            @tagName(transport),
            device_id,
            report_topic,
        });

        try client.subscribe(report_topic);
        // The P1 only sends deltas, so the accumulated document starts empty
        // until we ask for everything once.
        try self.requestFullStatus();

        return self;
    }

    pub fn close(self: *Session) void {
        self.status.deinit();
        self.client.close();
        self.gpa.free(self.report_topic);
        self.gpa.free(self.request_topic);
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

    pub const CommandError = mqtt.WriteError || error{OutOfMemory};

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

    fn sendCommand(self: *Session, payload: anytype) CommandError!void {
        const json = try std.json.Stringify.valueAlloc(self.gpa, payload, .{});
        defer self.gpa.free(json);
        // QoS 1 so control commands are not silently dropped.
        try self.client.publish(self.request_topic, json, .at_least_once);
    }

    /// The firmware wants `sequence_id` as a decimal string.
    fn takeSequenceId(self: *Session) []const u8 {
        const id = self.sequence_id;
        self.sequence_id +%= 1;
        return std.fmt.bufPrint(&self.sequence_buf, "{d}", .{id}) catch unreachable;
    }
};
