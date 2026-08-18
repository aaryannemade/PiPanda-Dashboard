//! On-disk store for the cloud access token.
//!
//! Bambu access tokens are bearer credentials valid for roughly three months
//! and the refresh endpoint has been dead for a while, so there is nothing to
//! rotate: we persist the token and re-run the interactive login when it stops
//! working.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cloud = @import("cloud.zig");

/// `rw-------`. The token is equivalent to the account password for API
/// purposes.
const private_file: Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    @enumFromInt(0o600);

pub const Credentials = struct {
    account: []const u8,
    access_token: []const u8,
    /// MQTT username, `u_<uid>`.
    mqtt_username: []const u8,
    region: cloud.Region,
    /// Serial of the printer to watch. Optional so `login` can run before the
    /// device list is known.
    device_id: ?[]const u8 = null,
    /// LAN access code, cached from the device list so LAN mode works offline.
    device_access_code: ?[]const u8 = null,
};

pub const LoadError = error{
    NotFound,
    /// The file exists but is not a credentials document we understand.
    Corrupt,
    OutOfMemory,
    AccessDenied,
    Unexpected,
};

pub const Store = struct {
    io: Io,
    /// Directory holding the credentials file. Owned by the caller.
    dir: []const u8,

    const file_name = "credentials.json";

    /// Resolves the state directory: `$PIPANDA_STATE_DIR`, else
    /// `$XDG_STATE_HOME/pipanda`, else `$HOME/.local/state/pipanda`.
    ///
    /// The returned path is allocated in `arena`.
    pub fn resolveDir(
        arena: Allocator,
        environ: *std.process.Environ.Map,
    ) Allocator.Error![]const u8 {
        if (environ.get("PIPANDA_STATE_DIR")) |dir| {
            if (dir.len != 0) return arena.dupe(u8, dir);
        }
        if (environ.get("XDG_STATE_HOME")) |base| {
            if (base.len != 0) return std.fs.path.join(arena, &.{ base, "pipanda" });
        }
        if (environ.get("HOME")) |home| {
            if (home.len != 0) return std.fs.path.join(arena, &.{ home, ".local/state/pipanda" });
        }
        return arena.dupe(u8, ".pipanda");
    }

    pub fn path(self: Store, arena: Allocator) Allocator.Error![]const u8 {
        return std.fs.path.join(arena, &.{ self.dir, file_name });
    }

    /// Loads the stored credentials. Everything returned is allocated in
    /// `arena`.
    pub fn load(self: Store, arena: Allocator) LoadError!Credentials {
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

        const parsed = std.json.parseFromSliceLeaky(Credentials, arena, bytes, .{
            // Tolerate fields added by newer versions of pipanda.
            .ignore_unknown_fields = true,
        }) catch return error.Corrupt;

        if (parsed.access_token.len == 0 or parsed.mqtt_username.len == 0) return error.Corrupt;
        return parsed;
    }

    pub const SaveError = error{ OutOfMemory, AccessDenied, Unexpected };

    pub fn save(self: Store, gpa: Allocator, creds: Credentials) SaveError!void {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, self.dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            else => return error.Unexpected,
        };

        const json = try std.json.Stringify.valueAlloc(gpa, creds, .{ .whitespace = .indent_2 });
        defer gpa.free(json);

        const full_path = try self.path(gpa);
        defer gpa.free(full_path);

        cwd.writeFile(self.io, .{
            .sub_path = full_path,
            .data = json,
            .flags = .{ .permissions = private_file },
        }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            else => return error.Unexpected,
        };
    }

    pub const DeleteError = error{ NotFound, OutOfMemory, AccessDenied, Unexpected };

    /// Removes the stored credentials, e.g. on logout. `NotFound` when there was
    /// nothing to remove.
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
