//! Just enough MQTT 3.1.1 to talk to a Bambu Lab printer: CONNECT, SUBSCRIBE,
//! PUBLISH at QoS 0/1, and PINGREQ. No session persistence, no retained message
//! handling, no QoS 2.
//!
//! Writes are serialised with a mutex so a keepalive task can share the
//! connection with whoever is driving the read loop.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tls = @import("tls_stream.zig");
const log = @import("../log.zig");

pub const Trust = tls.Trust;

const PacketType = enum(u4) {
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
};

pub const Qos = enum(u2) { at_most_once = 0, at_least_once = 1 };

pub const ConnectError = tls.ConnectError || error{
    /// The broker rejected the credentials. For cloud MQTT this usually means
    /// the access token has expired; log in again.
    NotAuthorized,
    /// The broker rejected the connection for a reason other than credentials.
    ConnectionRefused,
    ProtocolError,
    WriteFailed,
    ReadFailed,
    EndOfStream,
    Canceled,
};

pub const ReadError = error{
    ProtocolError,
    /// A packet larger than `max_packet_len` arrived. We refuse to buffer it
    /// rather than let a bad peer exhaust memory.
    PacketTooLarge,
    ReadFailed,
    EndOfStream,
    WriteFailed,
    OutOfMemory,
    Canceled,
};

pub const WriteError = error{ WriteFailed, Canceled };

/// A received application message. Owns its backing allocation.
pub const Message = struct {
    topic: []const u8,
    payload: []const u8,
    buffer: []u8,

    pub fn deinit(msg: Message, gpa: Allocator) void {
        gpa.free(msg.buffer);
    }
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    stream: *tls.TlsStream,
    write_mutex: Io.Mutex,
    next_packet_id: u16,
    keep_alive_seconds: u16,

    /// A full `pushall` report from an X1 with four AMS units is well under
    /// 64 KiB; 1 MiB is generous headroom without being a DoS vector.
    pub const max_packet_len = 1024 * 1024;

    pub const Options = struct {
        host: []const u8,
        port: u16 = 8883,
        client_id: []const u8,
        username: []const u8,
        password: []const u8,
        /// Seconds. The client pings at half this interval. Zero disables
        /// keepalive entirely, which also tells the broker not to drop us for
        /// inactivity.
        keep_alive_seconds: u16 = 30,
        trust: Trust = .system_ca,
    };

    pub fn connect(gpa: Allocator, io: Io, options: Options) ConnectError!*Client {
        log.debug("mqtt: dialing {s}:{d} (trust {s})", .{
            options.host,
            options.port,
            @tagName(options.trust),
        });
        const stream = try tls.TlsStream.connect(gpa, io, options.host, options.port, options.trust);
        errdefer stream.close();
        log.debug("mqtt: tls established", .{});

        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .write_mutex = .init,
            .next_packet_id = 1,
            .keep_alive_seconds = options.keep_alive_seconds,
        };

        try self.sendConnect(options);
        try self.readConnAck();
        return self;
    }

    /// Sends DISCONNECT, tears down TLS and frees everything.
    pub fn close(self: *Client) void {
        self.writeControl(.disconnect, 0, &.{}) catch {};
        self.stream.close();
        self.gpa.destroy(self);
    }

    fn sendConnect(self: *Client, options: Options) ConnectError!void {
        // Brokers reject a set username flag with a zero-length username, so
        // only advertise credentials we actually have. MQTT 3.1.1 also forbids
        // a password without a username.
        const has_username = options.username.len != 0;
        const has_password = has_username and options.password.len != 0;

        // 10 bytes of variable header, then the length-prefixed payload strings.
        var remaining: usize = 10 + 2 + options.client_id.len;
        if (has_username) remaining += 2 + options.username.len;
        if (has_password) remaining += 2 + options.password.len;

        var flags: u8 = 0x02; // clean session
        if (has_username) flags |= 0x80;
        if (has_password) flags |= 0x40;

        self.write_mutex.lock(self.io) catch return error.Canceled;
        defer self.write_mutex.unlock(self.io);

        log.debug("mqtt: CONNECT client_id={s} username={s}… ({d} chars) password={d} chars keepalive={d}s", .{
            options.client_id,
            log.prefix(options.username, 4),
            options.username.len,
            options.password.len,
            options.keep_alive_seconds,
        });

        const w = self.stream.writer();
        try writeFixedHeader(w, .connect, 0, remaining);
        try writeString(w, "MQTT");
        try w.writeByte(4); // protocol level 3.1.1
        try w.writeByte(flags);
        try w.writeInt(u16, options.keep_alive_seconds, .big);
        try writeString(w, options.client_id);
        if (has_username) try writeString(w, options.username);
        if (has_password) try writeString(w, options.password);
        try self.stream.flush();
    }

    fn readConnAck(self: *Client) ConnectError!void {
        const r = self.stream.reader();
        const header = try r.takeByte();
        if (@as(u4, @truncate(header >> 4)) != @intFromEnum(PacketType.connack)) {
            return error.ProtocolError;
        }
        const remaining = readRemainingLength(r) catch return error.ProtocolError;
        if (remaining != 2) return error.ProtocolError;
        _ = try r.takeByte(); // session present flag
        const return_code = try r.takeByte();
        log.debug("mqtt: CONNACK return code {d}", .{return_code});
        return switch (return_code) {
            0 => {},
            // 4 = bad user name or password, 5 = not authorized
            4, 5 => error.NotAuthorized,
            else => error.ConnectionRefused,
        };
    }

    /// Subscribes at QoS 0. Does not wait for the SUBACK; it is consumed and
    /// discarded by `nextMessage`.
    pub fn subscribe(self: *Client, topic_filter: []const u8) WriteError!void {
        const remaining = 2 + 2 + topic_filter.len + 1;

        self.write_mutex.lock(self.io) catch return error.Canceled;
        defer self.write_mutex.unlock(self.io);

        const w = self.stream.writer();
        // SUBSCRIBE has mandatory fixed-header flags of 0b0010.
        try writeFixedHeader(w, .subscribe, 0x2, remaining);
        try w.writeInt(u16, self.takePacketId(), .big);
        try writeString(w, topic_filter);
        try w.writeByte(@intFromEnum(Qos.at_most_once));
        try self.stream.flush();
    }

    pub fn publish(self: *Client, topic: []const u8, payload: []const u8, qos: Qos) WriteError!void {
        const id_len: usize = if (qos == .at_most_once) 0 else 2;
        const remaining = 2 + topic.len + id_len + payload.len;

        self.write_mutex.lock(self.io) catch return error.Canceled;
        defer self.write_mutex.unlock(self.io);

        const w = self.stream.writer();
        try writeFixedHeader(w, .publish, @as(u4, @intFromEnum(qos)) << 1, remaining);
        try writeString(w, topic);
        if (qos != .at_most_once) try w.writeInt(u16, self.takePacketId(), .big);
        try w.writeAll(payload);
        try self.stream.flush();
    }

    pub fn ping(self: *Client) WriteError!void {
        try self.writeControl(.pingreq, 0, &.{});
    }

    fn writeControl(self: *Client, t: PacketType, flags: u4, body: []const u8) WriteError!void {
        self.write_mutex.lock(self.io) catch return error.Canceled;
        defer self.write_mutex.unlock(self.io);

        const w = self.stream.writer();
        try writeFixedHeader(w, t, flags, body.len);
        try w.writeAll(body);
        try self.stream.flush();
    }

    /// Blocks until the next application message arrives. Acknowledgements,
    /// PINGRESPs and anything else we do not care about are handled internally.
    ///
    /// The returned `Message` must be released with `Message.deinit`.
    pub fn nextMessage(self: *Client, gpa: Allocator) ReadError!Message {
        const r = self.stream.reader();
        while (true) {
            const header = try r.takeByte();
            const packet_type: u4 = @truncate(header >> 4);
            const remaining = readRemainingLength(r) catch return error.ProtocolError;
            if (remaining > max_packet_len) return error.PacketTooLarge;

            if (packet_type != @intFromEnum(PacketType.publish)) {
                // PINGRESP, SUBACK, PUBACK and friends: nothing actionable.
                log.debug("mqtt: recv {s} ({d} bytes), ignored", .{
                    if (std.enums.fromInt(PacketType, packet_type)) |t| @tagName(t) else "unknown",
                    remaining,
                });
                try r.discardAll(remaining);
                continue;
            }

            const buffer = try gpa.alloc(u8, remaining);
            errdefer gpa.free(buffer);
            try r.readSliceAll(buffer);

            if (buffer.len < 2) return error.ProtocolError;
            const topic_len = std.mem.readInt(u16, buffer[0..2], .big);
            var offset: usize = 2 + @as(usize, topic_len);
            if (offset > buffer.len) return error.ProtocolError;
            const topic = buffer[2..offset];

            const qos: u2 = @truncate((header >> 1) & 0x3);
            if (qos != 0) {
                if (offset + 2 > buffer.len) return error.ProtocolError;
                const packet_id = std.mem.readInt(u16, buffer[offset..][0..2], .big);
                offset += 2;
                if (qos == 1) {
                    var ack: [2]u8 = undefined;
                    std.mem.writeInt(u16, &ack, packet_id, .big);
                    try self.writeControl(.puback, 0, &ack);
                }
            }

            return .{ .topic = topic, .payload = buffer[offset..], .buffer = buffer };
        }
    }

    /// Pings at half the negotiated keepalive interval until canceled. Intended
    /// to be run via `Io.Group.concurrent` alongside the read loop.
    pub fn keepAliveLoop(self: *Client) Io.Cancelable!void {
        if (self.keep_alive_seconds == 0) return;
        const interval: Io.Duration = .{
            .nanoseconds = @divTrunc(@as(i96, self.keep_alive_seconds) * std.time.ns_per_s, 2),
        };
        while (true) {
            try self.io.sleep(interval, .awake);
            self.ping() catch return;
        }
    }

    fn takePacketId(self: *Client) u16 {
        const id = self.next_packet_id;
        // Packet identifier 0 is not allowed.
        self.next_packet_id = if (id == std.math.maxInt(u16)) 1 else id + 1;
        return id;
    }
};

fn writeFixedHeader(
    w: *Io.Writer,
    packet_type: PacketType,
    flags: u4,
    remaining_length: usize,
) error{WriteFailed}!void {
    try w.writeByte(@as(u8, @intFromEnum(packet_type)) << 4 | flags);
    var buf: [4]u8 = undefined;
    try w.writeAll(encodeRemainingLength(&buf, remaining_length));
}

fn writeString(w: *Io.Writer, s: []const u8) error{WriteFailed}!void {
    try w.writeInt(u16, @intCast(s.len), .big);
    try w.writeAll(s);
}

/// MQTT's variable byte integer: 7 bits of payload per byte, high bit is a
/// continuation flag. Maximum four bytes.
fn encodeRemainingLength(buf: *[4]u8, value_in: usize) []const u8 {
    std.debug.assert(value_in <= 268_435_455);
    var value = value_in;
    var i: usize = 0;
    while (true) {
        buf[i] = @intCast(value % 128);
        value /= 128;
        if (value > 0) {
            buf[i] |= 0x80;
            i += 1;
        } else {
            return buf[0 .. i + 1];
        }
    }
}

fn readRemainingLength(r: *Io.Reader) (Io.Reader.Error || error{ProtocolError})!u32 {
    var multiplier: u32 = 1;
    var value: u32 = 0;
    for (0..4) |_| {
        const byte = try r.takeByte();
        value += @as(u32, byte & 0x7f) * multiplier;
        if (byte & 0x80 == 0) return value;
        multiplier *= 128;
    }
    return error.ProtocolError;
}

test encodeRemainingLength {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0}, encodeRemainingLength(&buf, 0));
    try std.testing.expectEqualSlices(u8, &.{127}, encodeRemainingLength(&buf, 127));
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, encodeRemainingLength(&buf, 128));
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x7F }, encodeRemainingLength(&buf, 16383));
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x01 }, encodeRemainingLength(&buf, 16384));
}

test readRemainingLength {
    const cases = [_]struct { bytes: []const u8, value: u32 }{
        .{ .bytes = &.{0}, .value = 0 },
        .{ .bytes = &.{127}, .value = 127 },
        .{ .bytes = &.{ 0x80, 0x01 }, .value = 128 },
        .{ .bytes = &.{ 0xFF, 0xFF, 0xFF, 0x7F }, .value = 268_435_455 },
    };
    for (cases) |case| {
        var reader: Io.Reader = .fixed(case.bytes);
        try std.testing.expectEqual(case.value, try readRemainingLength(&reader));
    }

    var bad: Io.Reader = .fixed(&.{ 0x80, 0x80, 0x80, 0x80 });
    try std.testing.expectError(error.ProtocolError, readRemainingLength(&bad));
}
