//! A TLS connection over TCP, packaged so it can be handed to protocol code as
//! a plain `Io.Reader`/`Io.Writer` pair.
//!
//! `std.http.Client` already does this internally for HTTPS, but MQTT needs the
//! same thing without the HTTP layer on top, so we assemble it by hand.

const std = @import("std");
const Io = std.Io;
const tls = std.crypto.tls;
const Allocator = std.mem.Allocator;

/// How much to trust the peer's certificate.
pub const Trust = union(enum) {
    /// Verify the chain against the system CA bundle and check that the
    /// certificate was issued for `host`. Correct for `api.bambulab.com` and
    /// the cloud MQTT brokers.
    system_ca,
    /// Accept a self-signed certificate and skip host verification entirely.
    ///
    /// This is required for LAN mode: the printer presents a Bambu-issued
    /// certificate that does not carry the IP address you dialled, so there is
    /// nothing to verify against. It means a device on your LAN can
    /// impersonate the printer. Only use it for the local transport.
    insecure_self_signed,
};

pub const ConnectError = error{
    /// The handshake failed. Deliberately coarse: the underlying error set is
    /// ~50 entries wide and callers cannot act on the distinction.
    TlsHandshakeFailed,
    ConnectionRefused,
    NameResolutionFailed,
    NetworkUnreachable,
    ConnectionTimedOut,
    OutOfMemory,
    InvalidHostName,
    Unexpected,
    Canceled,
};

/// Heap-allocated because `tls.Client` holds pointers into the socket reader
/// and writer stored alongside it, so the whole thing must not move once the
/// handshake has run.
pub const TlsStream = struct {
    gpa: Allocator,
    io: Io,
    socket: Io.net.Stream,
    socket_reader: Io.net.Stream.Reader,
    socket_writer: Io.net.Stream.Writer,
    ca_bundle: std.crypto.Certificate.Bundle,
    ca_lock: Io.RwLock,
    client: tls.Client,
    scratch: []u8,

    /// The TLS record layer needs a whole encrypted record in the buffer at
    /// once, so both socket buffers are sized to the maximum record length.
    const socket_buf_len = tls.Client.min_buffer_len;
    /// Plaintext inbound. The extra headroom above a single record lets protocol
    /// code peek across record boundaries.
    const plain_read_len = tls.Client.min_buffer_len + 32 * 1024;
    const plain_write_len = 16 * 1024;
    const scratch_len = socket_buf_len * 2 + plain_read_len + plain_write_len;

    pub fn connect(
        gpa: Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        trust: Trust,
    ) ConnectError!*TlsStream {
        const host_name = Io.net.HostName.init(host) catch return error.InvalidHostName;

        const self = try gpa.create(TlsStream);
        errdefer gpa.destroy(self);

        const scratch = try gpa.alloc(u8, scratch_len);
        errdefer gpa.free(scratch);

        const socket = host_name.connect(io, port, .{ .mode = .stream }) catch |err| switch (err) {
            error.Canceled, error.Unexpected => |e| return e,
            error.ConnectionRefused => return error.ConnectionRefused,
            error.NetworkUnreachable, error.NetworkDown, error.HostUnreachable => return error.NetworkUnreachable,
            error.Timeout => return error.ConnectionTimedOut,
            else => return error.NameResolutionFailed,
        };
        errdefer socket.close(io);

        const now: Io.Timestamp = .now(io, .real);

        var ca_bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer ca_bundle.deinit(gpa);
        if (trust == .system_ca) {
            // Drops expired roots as it goes, hence the timestamp.
            ca_bundle.rescan(gpa, io, now) catch return error.TlsHandshakeFailed;
        }

        var rest = scratch;
        const socket_read_buf = takeSlice(&rest, socket_buf_len);
        const socket_write_buf = takeSlice(&rest, socket_buf_len);
        const plain_read_buf = takeSlice(&rest, plain_read_len);
        const plain_write_buf = takeSlice(&rest, plain_write_len);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .socket = socket,
            .socket_reader = socket.reader(io, socket_read_buf),
            .socket_writer = socket.writer(io, socket_write_buf),
            .ca_bundle = ca_bundle,
            .ca_lock = .init,
            .client = undefined,
            .scratch = scratch,
        };

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);

        self.client = tls.Client.init(
            &self.socket_reader.interface,
            &self.socket_writer.interface,
            .{
                .host = switch (trust) {
                    .system_ca => .{ .explicit = host },
                    .insecure_self_signed => .no_verification,
                },
                .ca = switch (trust) {
                    .system_ca => .{ .bundle = .{
                        .gpa = gpa,
                        .io = io,
                        .lock = &self.ca_lock,
                        .bundle = &self.ca_bundle,
                    } },
                    .insecure_self_signed => .self_signed,
                },
                .read_buffer = plain_read_buf,
                .write_buffer = plain_write_buf,
                .entropy = &entropy,
                .realtime_now = now,
                // MQTT frames carry their own length, but we do not track a
                // total byte count, so refuse to treat a truncated stream as a
                // clean close.
                .allow_truncation_attacks = false,
            },
        ) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.TlsHandshakeFailed,
        };

        return self;
    }

    /// Plaintext stream from the peer.
    pub fn reader(self: *TlsStream) *Io.Reader {
        return &self.client.reader;
    }

    /// Plaintext stream to the peer. Buffered; call `flush`.
    pub fn writer(self: *TlsStream) *Io.Writer {
        return &self.client.writer;
    }

    /// Pushes buffered plaintext through the record layer and onto the socket.
    pub fn flush(self: *TlsStream) error{WriteFailed}!void {
        try self.client.writer.flush();
        self.socket_writer.interface.flush() catch return error.WriteFailed;
    }

    pub fn close(self: *TlsStream) void {
        // Best effort: send close_notify so the peer sees a clean shutdown.
        self.client.end() catch {};
        self.socket_writer.interface.flush() catch {};
        self.socket.close(self.io);
        self.ca_bundle.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.free(self.scratch);
        gpa.destroy(self);
    }
};

fn takeSlice(rest: *[]u8, n: usize) []u8 {
    const out = rest.*[0..n];
    rest.* = rest.*[n..];
    return out;
}
