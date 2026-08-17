//! Runtime-gated diagnostic logging.
//!
//! Separate from `std.log` levels because the useful/noisy split here is a
//! runtime decision (`--verbose`), not a build-mode one, and because everything
//! on these paths handles credentials that must never reach a log file.

const std = @import("std");

pub var enabled: bool = false;

/// Emitted at `info` level so `--verbose` works in release builds too.
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;
    std.log.info(fmt, args);
}

/// The leading bytes of a secret: enough to correlate two log lines or spot a
/// truncated paste, not enough to be worth anything on its own. Always pair it
/// with the full length so a wrong-length credential is visible.
pub fn prefix(secret: []const u8, n: usize) []const u8 {
    return secret[0..@min(n, secret.len)];
}

test prefix {
    try std.testing.expectEqualStrings("u_12", prefix("u_1234567", 4));
    // Must not read past a short secret.
    try std.testing.expectEqualStrings("ab", prefix("ab", 8));
    try std.testing.expectEqualStrings("", prefix("", 4));
}
