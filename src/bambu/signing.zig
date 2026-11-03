//! RSA-SHA256 envelopes for Bambu's authorization-control firmware.
//!
//! The printer verifies the exact payload bytes, not a canonicalised JSON
//! document. We therefore serialise the command once, sign that string, and
//! reuse the same bytes alongside the signature header. Only `print` commands need
//! this envelope; chamber-light and status commands remain unsigned.
//!
//! Protocol references:
//!   https://github.com/Doridian/OpenBambuAPI/blob/main/cloud-x509-auth.md
//!   https://github.com/schwarztim/bambu-mcp (MIT)
//! Current credentials are provisioned separately into the private state
//! directory. No application signing credential is compiled into the binary.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Certificate = std.crypto.Certificate;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Modulus = std.crypto.ff.Modulus(4096);
const Fe = Modulus.Fe;

// Public, expired Bambu Connect key from the MIT bambu-mcp reference, used
// only as a deterministic RSA test fixture. Never loaded by production code.
const test_private_key_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDQNp2NfkajwcWH
    \\PIqosa08P1ZwETPr1veZCMqieQxWtYw97wp+JCxX4yBrBcAwid7o7PHI9KQVzPRM
    \\f0uXspaDUdSljrfJ/YwGEz7+GJz4+ml1UbWXBePyzXW1+N2hIGGn7BcNuA0v8rMY
    \\uvVgiIIQNjLErgGcCWmMHLwsMMQ7LNprUZZKsSNB4HaQDH7cQZmYBN/O45np6l+K
    \\VuLdzXdDpZcOM7bNO6smev822WPGDuKBo1iVfQbUe10X4dCNwkBR3QGpScVvg8gg
    \\tRYZDYue/qc4Xaj806RZPttknWfxdvfZgoOmAiwnyQ5K3+mzNYHgQZAOC2ydkK4J
    \\s+ZizK3lAgMBAAECggEAKwEcyXyrWmdLRQNcIDuSbD8ouzzSXIOp4BHQyH337nDQ
    \\5nnY0PTns79VksU9TMktIS7PQZJF0brjOmmQU2SvcbAVG5y+mRmlMhwHhrPOuB4A
    \\ahrWRrsQubV1+n/MRttJUEWS/WJmVuDp3NHAnI+VTYPkOHs4GeJXynik5PutjAr3
    \\tYmr3kaw0Wo/hYAXTKsI/R5aenC7jH8ZSyVcZ/j+bOSH5sT5/JY122AYmkQOFE7s
    \\JA0EfYJaJEwiuBWKOfRLQVEHhOFodUBZdGQcWeW3uFb88aYKN8QcKTO8/f6e4r8w
    \\QojgK3QMj1zmfS7xid6XCOVa17ary2hZHAEPnjcigQKBgQDQnm4TlbVTsM+CbFUS
    \\1rOIJRzPdnH3Y7x3IcmVKZt81eNktsdu56A4U6NEkFQqk4tVTT4TYja/hwgXmm6w
    \\J+w0WwZd445Bxj8PmaEr6Z/NSMYbCsi8pRelKWmlIMwD2YhtY/1xXD37zpOgN8oQ
    \\ryTKZR2gljbPxdfhKS7YerLp2wKBgQD/gJt3Ds69j1gMDLnnPctjmhsPRXh7PQ0e
    \\E9lqgFkx/vNuCuyRs6ymic2rBZmkdlpjsTJFmz1bwOzIvSRoH6kp0Mfyo6why5kr
    \\upDf7zz+hlvaFewme8aDeV3ex9Wvt73D66nwAy5ABOgn+66vZJeo0Iq/tnCwK3a/
    \\evTL9BOzPwKBgEUi7AnziEc3Bl4Lttnqa08INZcPgs9grzmv6dVUF6J0Y8qhxFAd
    \\1Pw1w5raVfpSMU/QrGzSFKC+iFECLgKVCHOFYwPEgQWNRKLP4BjkcMAgiP63QTU7
    \\ZS2oHsnJp7Ly6YKPK5Pg5O3JVSU4t+91i7TDc+EfRwTuZQ/KjSrS5u4XAoGBAP06
    \\v9reSDVELuWyb0Yqzrxm7k7ScbjjJ28aCTAvCTguEaKNHS7DP2jHx5mrMT35N1j7
    \\NHIcjFG2AnhqTf0M9CJHlQR9B4tvON5ISHJJsNAq5jpd4/G4V2XTEiBNOxKvL1tQ
    \\5NrGrD4zHs0R+25GarGcDwg3j7RrP4REHv9NZ4ENAoGAY7Nuz6xKu2XUwuZtJP7O
    \\kjsoDS7bjP95ddrtsRq5vcVjJ04avnjsr+Se9WDA//t7+eSeHjm5eXD7u0NtdqZo
    \\WtSm8pmWySOPXMn9QQmdzKHg1NOxer//f1KySVunX1vftTStjsZH7dRCtBEePcqg
    \\z5Av6MmEFDojtwTqvEZuhBM=
    \\-----END PRIVATE KEY-----
;

pub const InitError = error{ InvalidPrivateKey, OutOfMemory };
pub const SignError = error{ InvalidPayload, SigningFailed, OutOfMemory };

pub const Signer = struct {
    gpa: Allocator,
    modulus: Modulus,
    /// PKCS#1 private exponent, big-endian. Kept out of logs and wiped on free.
    private_exponent: []u8,
    modulus_len: usize,
    cert_id: []const u8 = "test-certificate",
    cert_pem: []const u8 = "",
    crl_pem: []const u8 = "",
    material_arena: ?std.heap.ArenaAllocator = null,

    pub fn load(gpa: Allocator, io: std.Io, dir: []const u8) !Signer {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const key_path = try std.fs.path.join(a, &.{ dir, "slicer_key.pem" });
        const key = try std.Io.Dir.cwd().readFileAlloc(io, key_path, a, .limited(16 * 1024));
        defer @memset(key, 0);
        var signer = try Signer.init(gpa, key);
        errdefer signer.deinit();
        signer.cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "slicer_cert.pem" }), a, .limited(32 * 1024));
        signer.crl_pem = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "slicer_crl.pem" }), a, .limited(32 * 1024));
        const id = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "slicer_cert_id.txt" }), a, .limited(1024));
        signer.cert_id = std.mem.trim(u8, id, " \r\n\t");
        if (signer.cert_id.len == 0 or !std.mem.startsWith(u8, signer.cert_pem, "-----BEGIN CERTIFICATE-----") or
            std.mem.indexOf(u8, signer.crl_pem, "-----BEGIN X509 CRL-----") == null)
            return error.InvalidPrivateKey;
        signer.material_arena = arena;
        return signer;
    }

    /// Parses an unencrypted PKCS#8 PEM RSA private key.
    pub fn init(gpa: Allocator, pem: []const u8) InitError!Signer {
        const der = try decodePkcs8(gpa, pem);
        defer {
            @memset(der, 0);
            gpa.free(der);
        }

        const outer = try element(der, 0);
        try expectTag(outer, .sequence);
        var cursor = try child(der, outer);
        try expectTag(cursor, .integer);
        const algorithm = try next(der, &cursor);
        try expectTag(algorithm, .sequence);
        const private_key = try next(der, &cursor);
        try expectTag(private_key, .octetstring);

        const rsa = try element(der, private_key.slice.start);
        try expectTag(rsa, .sequence);
        if (rsa.slice.end != private_key.slice.end) return error.InvalidPrivateKey;
        var rsa_cursor = try child(der, rsa);
        try expectTag(rsa_cursor, .integer);
        const modulus_elem = try next(der, &rsa_cursor);
        try expectTag(modulus_elem, .integer);
        const public_exponent = try next(der, &rsa_cursor);
        try expectTag(public_exponent, .integer);
        const private_exponent = try next(der, &rsa_cursor);
        try expectTag(private_exponent, .integer);

        const modulus_bytes = unsignedInteger(der, modulus_elem);
        if (modulus_bytes.len < 64 or modulus_bytes.len > 512) return error.InvalidPrivateKey;
        const modulus = Modulus.fromBytes(modulus_bytes, .big) catch return error.InvalidPrivateKey;
        const exponent = unsignedInteger(der, private_exponent);
        if (exponent.len == 0) return error.InvalidPrivateKey;

        return .{
            .gpa = gpa,
            .modulus = modulus,
            .private_exponent = try gpa.dupe(u8, exponent),
            .modulus_len = modulus_bytes.len,
        };
    }

    pub fn deinit(self: *Signer) void {
        @memset(self.private_exponent, 0);
        self.gpa.free(self.private_exponent);
        if (self.material_arena) |*arena| arena.deinit();
    }

    /// Wraps an already serialised `{"print":{...}}` payload. `user_id` is a
    /// top-level sibling of `print`, inside both the signature and wire bytes.
    pub fn signCommand(self: *const Signer, gpa: Allocator, payload: []const u8, user_id: []const u8) SignError![]u8 {
        if (!std.mem.startsWith(u8, payload, "{\"print\":") or
            payload.len < 2 or payload[payload.len - 1] != '}')
            return error.InvalidPayload;

        const quoted_user_id = try std.json.Stringify.valueAlloc(gpa, user_id, .{});
        defer gpa.free(quoted_user_id);
        const body = try std.fmt.allocPrint(gpa, "{s},\"user_id\":{s}}}", .{
            payload[0 .. payload.len - 1],
            quoted_user_id,
        });
        defer gpa.free(body);

        const signature = try self.sign(body);
        defer self.gpa.free(signature);
        const encoded_len = std.base64.standard.Encoder.calcSize(signature.len);
        const sign_string = try gpa.alloc(u8, encoded_len);
        defer gpa.free(sign_string);
        _ = std.base64.standard.Encoder.encode(sign_string, signature);

        const header = try std.json.Stringify.valueAlloc(gpa, .{
            .sign_ver = "v1.0",
            .sign_alg = "RSA_SHA256",
            .sign_string = sign_string,
            .cert_id = self.cert_id,
            .payload_len = body.len,
        }, .{});
        defer gpa.free(header);

        return std.fmt.allocPrint(gpa, "{s},\"header\":{s}}}", .{ body[0 .. body.len - 1], header });
    }

    /// RSASSA-PKCS1-v1_5 with SHA-256 over `message`.
    fn sign(self: *const Signer, message: []const u8) SignError![]const u8 {
        const digest_info_prefix = [_]u8{
            0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
            0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
            0x00, 0x04, 0x20,
        };
        if (self.modulus_len < digest_info_prefix.len + Sha256.digest_length + 11)
            return error.SigningFailed;

        var encoded: [512]u8 = undefined;
        const em = encoded[0..self.modulus_len];
        @memset(em, 0xff);
        em[0] = 0;
        em[1] = 1;
        const digest_info_at = self.modulus_len - digest_info_prefix.len - Sha256.digest_length;
        em[digest_info_at - 1] = 0;
        @memcpy(em[digest_info_at..][0..digest_info_prefix.len], &digest_info_prefix);
        Sha256.hash(message, em[digest_info_at + digest_info_prefix.len ..][0..Sha256.digest_length], .{});

        const base = Fe.fromBytes(self.modulus, em, .big) catch return error.SigningFailed;
        const signature_fe = self.modulus.powWithEncodedExponent(base, self.private_exponent, .big) catch
            return error.SigningFailed;

        const signature = self.gpa.alloc(u8, self.modulus_len) catch return error.OutOfMemory;
        errdefer self.gpa.free(signature);
        signature_fe.toBytes(signature, .big) catch return error.SigningFailed;
        return signature;
    }
};

fn decodePkcs8(gpa: Allocator, pem: []const u8) InitError![]u8 {
    const begin_marker = "-----BEGIN PRIVATE KEY-----";
    const end_marker = "-----END PRIVATE KEY-----";
    const begin = std.mem.indexOf(u8, pem, begin_marker) orelse return error.InvalidPrivateKey;
    const content_start = begin + begin_marker.len;
    const end = std.mem.indexOfPos(u8, pem, content_start, end_marker) orelse return error.InvalidPrivateKey;
    const encoded = pem[content_start..end];
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const output = try gpa.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    errdefer gpa.free(output);
    const len = decoder.decode(output, encoded) catch return error.InvalidPrivateKey;
    return gpa.realloc(output, len) catch return error.OutOfMemory;
}

fn element(bytes: []const u8, index: usize) InitError!Certificate.der.Element {
    if (index > bytes.len or bytes.len - index < 2) return error.InvalidPrivateKey;
    var start = index + 2;
    const first_length = bytes[index + 1];
    var length: usize = first_length;
    if (first_length & 0x80 != 0) {
        const count = first_length & 0x7f;
        if (count == 0 or count > 4 or bytes.len - start < count) return error.InvalidPrivateKey;
        length = 0;
        for (bytes[start..][0..count]) |byte| length = (length << 8) | byte;
        start += count;
    }
    if (length > bytes.len - start) return error.InvalidPrivateKey;
    return .{
        .identifier = @bitCast(bytes[index]),
        .slice = .{ .start = @intCast(start), .end = @intCast(start + length) },
    };
}

fn expectTag(value: Certificate.der.Element, tag: Certificate.der.Tag) InitError!void {
    if (value.identifier.tag != tag) return error.InvalidPrivateKey;
}

fn child(bytes: []const u8, parent: Certificate.der.Element) InitError!Certificate.der.Element {
    return element(bytes, parent.slice.start);
}

fn next(bytes: []const u8, current: *Certificate.der.Element) InitError!Certificate.der.Element {
    current.* = try element(bytes, current.slice.end);
    return current.*;
}

fn unsignedInteger(bytes: []const u8, value: Certificate.der.Element) []const u8 {
    const raw = bytes[value.slice.start..value.slice.end];
    var offset: usize = 0;
    while (offset + 1 < raw.len and raw[offset] == 0) : (offset += 1) {}
    return raw[offset..];
}

test "signed command verifies and preserves the signed payload" {
    var signer = try Signer.init(std.testing.allocator, test_private_key_pem);
    defer signer.deinit();

    const payload = "{\"print\":{\"sequence_id\":\"20001\",\"command\":\"print_speed\",\"param\":\"2\"}}";
    const body = "{\"print\":{\"sequence_id\":\"20001\",\"command\":\"print_speed\",\"param\":\"2\"},\"user_id\":\"123\"}";
    const wire = try signer.signCommand(std.testing.allocator, payload, "123");
    defer std.testing.allocator.free(wire);

    try std.testing.expect(std.mem.startsWith(u8, wire, "{\"print\":"));
    const header_at = std.mem.lastIndexOf(u8, wire, ",\"header\":").?;
    try std.testing.expectEqualStrings(body[0 .. body.len - 1], wire[0..header_at]);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, wire, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("123", root.get("user_id").?.string);
    const header = root.get("header").?.object;
    try std.testing.expectEqual(@as(i64, @intCast(body.len)), header.get("payload_len").?.integer);
    try std.testing.expectEqualStrings("test-certificate", header.get("cert_id").?.string);

    const encoded = header.get("sign_string").?.string;
    var signature: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 256), signer.modulus_len);
    try std.base64.standard.Decoder.decode(&signature, encoded);

    const public_key: Certificate.rsa.PublicKey = .{
        .n = signer.modulus,
        .e = try Fe.fromBytes(signer.modulus, &.{ 1, 0, 1 }, .big),
    };
    try Certificate.rsa.PKCS1v1_5Signature.verify(256, signature, body, public_key, Sha256);
}

test "invalid private keys and non-print payloads are rejected" {
    try std.testing.expectError(error.InvalidPrivateKey, Signer.init(std.testing.allocator, "not a key"));
    var signer = try Signer.init(std.testing.allocator, test_private_key_pem);
    defer signer.deinit();
    try std.testing.expectError(error.InvalidPayload, signer.signCommand(std.testing.allocator, "{\"system\":{}}", "123"));
    try std.testing.expectError(error.InvalidPrivateKey, element(&.{ 0x30, 0x84, 0xff, 0xff, 0xff, 0xff }, 0));
    try std.testing.expectError(error.InvalidPrivateKey, element(&.{ 0x30, 0x84 }, 0));
    try std.testing.expectError(error.InvalidPrivateKey, element(&.{ 0x30, 0x80 }, 0));
    try std.testing.expectError(error.InvalidPrivateKey, element(&.{}, 0));
}
