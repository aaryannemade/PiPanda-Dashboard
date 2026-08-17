//! pipanda CLI.
//!
//!   pipanda login [--region china]   authenticate and store the access token
//!   pipanda devices                  list printers bound to the account
//!   pipanda use <device-id>          select the printer to watch
//!   pipanda watch [--lan]            stream live status from the printer
//!   pipanda light <on|off>           set the chamber light

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pipanda = @import("pipanda");

const usage =
    \\pipanda — auxiliary dashboard backend for the Bambu Lab P1S
    \\
    \\usage: pipanda <command> [options]
    \\
    \\commands:
    \\  login            authenticate with the Bambu Lab cloud and store the token
    \\  devices          list the printers bound to the account
    \\  use <device-id>  remember which printer to talk to
    \\  watch            stream live printer status
    \\  light <on|off>   set the chamber light
    \\
    \\options:
    \\  --code           log in with an emailed code instead of a password
    \\  --region china   use the China cloud region (login only)
    \\  --lan            talk to the printer directly instead of via the cloud
    \\  --json           emit the merged JSON status per update (watch only)
    \\  --raw            emit each raw report payload verbatim (watch only)
    \\  --verbose        log protocol steps to stderr; credentials are redacted
    \\
    \\state is kept in $PIPANDA_STATE_DIR, else $XDG_STATE_HOME/pipanda.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or isHelp(args[1])) {
        try out.writeAll(usage);
        try out.flush();
        // A usage message is not a crash; do not dump a stack trace for it.
        std.process.exit(if (args.len < 2) 2 else 0);
    }

    const store: pipanda.credentials.Store = .{
        .io = io,
        .dir = try pipanda.credentials.Store.resolveDir(arena, init.environ_map),
    };

    var opts: Options = .{ .printer_host = init.environ_map.get("PIPANDA_PRINTER_HOST") };
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--lan")) {
            opts.lan = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            opts.raw = true;
        } else if (std.mem.eql(u8, arg, "--code")) {
            opts.code_login = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            pipanda.log.enabled = true;
        } else if (std.mem.eql(u8, arg, "--region")) {
            i += 1;
            if (i >= args.len) return error.MissingRegionValue;
            opts.region = if (std.mem.eql(u8, args[i], "china")) .china else .global;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("unknown option: {s}", .{arg});
            return error.UnknownOption;
        } else {
            try positional.append(arena, arg);
        }
    }

    const command = args[1];
    const result = if (std.mem.eql(u8, command, "login"))
        cmdLogin(gpa, arena, io, out, store, opts)
    else if (std.mem.eql(u8, command, "devices"))
        cmdDevices(gpa, arena, io, out, store)
    else if (std.mem.eql(u8, command, "use"))
        cmdUse(gpa, arena, out, store, positional.items)
    else if (std.mem.eql(u8, command, "watch"))
        cmdWatch(gpa, arena, io, out, store, opts)
    else if (std.mem.eql(u8, command, "light"))
        cmdLight(gpa, arena, io, out, store, opts, positional.items)
    else {
        std.log.err("unknown command: {s}", .{command});
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(2);
    };

    result catch |err| {
        // Anything the user can fix gets a message and a plain exit status.
        // Everything else is a bug and keeps its stack trace.
        if (userMessage(err)) |message| {
            if (message.len != 0) std.log.err("{s}", .{message});
            out.flush() catch {};
            std.process.exit(1);
        }
        return err;
    };
}

/// Maps expected failures to an explanation. An empty string means the call site
/// already logged something more specific.
fn userMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        // Already reported in detail by loadCredentials / openSession.
        error.NotFound,
        error.Corrupt,
        error.NoPrinterSelected,
        error.NoAccessCode,
        error.NoPrinterHost,
        => "",

        error.InvalidCredentials => "the cloud rejected those credentials; if the account has no password, try `pipanda login --code`",
        error.NotAuthorized => "the printer or broker rejected the token; run `pipanda login` again",
        error.LoginCodeIncorrect => "that verification code was not correct",
        error.LoginCodeExpired => "that verification code had expired; a new one has been sent",
        error.BlockedByCloudflare => "Cloudflare blocked the request; wait a few minutes and retry",
        error.UnexpectedResponse => "the cloud API returned something unexpected; pipanda may need updating",
        error.HttpRequestFailed => "could not reach the Bambu Lab cloud",

        error.ConnectionRefused => "connection refused",
        error.ConnectionTimedOut => "connection timed out",
        error.NetworkUnreachable => "network unreachable",
        error.NameResolutionFailed => "could not resolve the host",
        error.TlsHandshakeFailed => "TLS handshake failed",
        error.EndOfStream => "the connection closed unexpectedly",

        error.ExpectedDeviceId => "usage: pipanda use <device-id>",
        error.ExpectedOnOff => "usage: pipanda light <on|off|flashing>",
        error.EmptyCredentials => "",
        error.UnexpectedEndOfInput => "input ended before the prompt was answered",

        else => null,
    };
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "help");
}

const Options = struct {
    region: pipanda.cloud.Region = .global,
    lan: bool = false,
    json: bool = false,
    raw: bool = false,
    /// Skip the password and authenticate with an emailed/texted code.
    code_login: bool = false,
    /// Printer address for `--lan`, from `$PIPANDA_PRINTER_HOST`.
    printer_host: ?[]const u8 = null,
};

fn cmdLogin(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    store: pipanda.credentials.Store,
    opts: Options,
) !void {
    var client: pipanda.cloud.Client = .init(gpa, io, opts.region);
    defer client.deinit();

    var stdin_buffer: [512]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const in = &stdin_reader.interface;

    const account = try prompt(arena, out, in, "Bambu Lab account (email): ");
    if (account.len == 0) {
        std.log.err("account must not be empty", .{});
        return error.EmptyCredentials;
    }

    // Accounts created by signing in with an emailed code have no password at
    // all, so `--code` skips straight to the code flow rather than making the
    // user guess a password that does not exist.
    if (opts.code_login) {
        const token = try loginByCode(&client, arena, out, in, account);
        try finishLogin(gpa, arena, out, &client, store, opts, account, token);
        return;
    }

    const password = try promptSecret(arena, out, in, "Password: ");
    if (password.len == 0) {
        std.log.err("password must not be empty; use `pipanda login --code` if the account has no password", .{});
        return error.EmptyCredentials;
    }

    const access_token = switch (try client.login(arena, account, password)) {
        .token => |token| token,
        .code_required => try loginByCode(&client, arena, out, in, account),
        .tfa_required => |tfa_key| blk: {
            try out.writeAll("This account uses an authenticator app.\n");
            try out.flush();
            const code = try prompt(arena, out, in, "Authenticator code: ");
            break :blk try client.loginWithTfaCode(arena, tfa_key, code);
        },
    };

    try finishLogin(gpa, arena, out, &client, store, opts, account, access_token);
}

/// Requests a fresh login code, prompts for it, and exchanges it for a token.
fn loginByCode(
    client: *pipanda.cloud.Client,
    arena: Allocator,
    out: *Io.Writer,
    in: *Io.Reader,
    account: []const u8,
) ![]const u8 {
    try client.requestLoginCode(arena, account);
    try out.writeAll("A verification code has been sent to your account.\n");
    try out.flush();

    const code = try prompt(arena, out, in, "Verification code: ");
    if (code.len == 0) return error.EmptyCredentials;

    return client.loginWithCode(arena, account, code) catch |err| switch (err) {
        error.LoginCodeExpired => {
            try out.writeAll("That code had expired; a new one has been sent. Re-run login.\n");
            try out.flush();
            return err;
        },
        else => return err,
    };
}

/// Resolves the MQTT username, selects the printer if there is only one, and
/// persists everything.
fn finishLogin(
    gpa: Allocator,
    arena: Allocator,
    out: *Io.Writer,
    client: *pipanda.cloud.Client,
    store: pipanda.credentials.Store,
    opts: Options,
    account: []const u8,
    access_token: []const u8,
) !void {
    const mqtt_username = try client.mqttUsername(arena, access_token);

    var creds: pipanda.credentials.Credentials = .{
        .account = account,
        .access_token = access_token,
        .mqtt_username = mqtt_username,
        .region = opts.region,
    };

    // If the account has exactly one printer there is nothing to choose, so
    // select it and cache its LAN access code straight away.
    const devices = client.devices(arena, access_token) catch &.{};
    if (devices.len == 1) {
        creds.device_id = devices[0].dev_id;
        creds.device_access_code = devices[0].dev_access_code;
    }

    try store.save(gpa, creds);

    try out.print("Logged in as {s} (mqtt user {s}).\n", .{ account, mqtt_username });
    if (creds.device_id) |id| {
        try out.print("Selected printer: {s} ({s}).\n", .{ devices[0].name, id });
    } else if (devices.len > 1) {
        try out.writeAll("Multiple printers found; pick one with `pipanda use <device-id>`.\n");
    }
    try out.flush();
}

fn cmdDevices(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    store: pipanda.credentials.Store,
) !void {
    const creds = try loadCredentials(arena, store);

    var client: pipanda.cloud.Client = .init(gpa, io, creds.region);
    defer client.deinit();

    const devices = try client.devices(arena, creds.access_token);
    if (devices.len == 0) {
        try out.writeAll("No printers bound to this account.\n");
        try out.flush();
        return;
    }

    for (devices) |d| {
        const selected = creds.device_id != null and
            std.mem.eql(u8, creds.device_id.?, d.dev_id);
        try out.print("{s} {s}  {s}  {s}  {s}\n", .{
            if (selected) "*" else " ",
            d.dev_id,
            d.dev_product_name,
            d.name,
            if (d.online) "online" else "offline",
        });
    }
    try out.flush();
}

fn cmdUse(
    gpa: Allocator,
    arena: Allocator,
    out: *Io.Writer,
    store: pipanda.credentials.Store,
    args: []const []const u8,
) !void {
    if (args.len != 1) return error.ExpectedDeviceId;
    const device_id = args[0];

    var creds = try loadCredentials(arena, store);
    creds.device_id = device_id;
    // The cached access code belongs to the previous printer.
    creds.device_access_code = null;
    try store.save(gpa, creds);
    try out.print("Selected printer {s}. Run `pipanda devices` to refresh its LAN code.\n", .{device_id});
    try out.flush();
}

fn cmdWatch(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    store: pipanda.credentials.Store,
    opts: Options,
) !void {
    const session = try openSession(gpa, arena, io, store, opts);
    defer session.close();

    if (opts.raw) session.raw_sink = out;

    // The keepalive has to run alongside a blocking read, so it gets its own
    // task. Writes are mutex-guarded inside the MQTT client.
    var group: Io.Group = .init;
    defer _ = group.cancel(io);
    try group.concurrent(io, pipanda.printer.Session.keepAlive, .{session});

    while (true) {
        switch (try session.pump()) {
            .other_report => continue,
            .status_updated => {},
        }

        // --raw already printed the payload; a summary line on top would only
        // get in the way of a paste.
        if (opts.raw and !opts.json) continue;

        if (opts.json) {
            const json = try session.status.toJson(gpa);
            defer gpa.free(json);
            try out.print("{s}\n", .{json});
        } else {
            try printSnapshot(out, session.status.snapshot());
        }
        try out.flush();
    }
}

fn cmdLight(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    store: pipanda.credentials.Store,
    opts: Options,
    args: []const []const u8,
) !void {
    if (args.len != 1) return error.ExpectedOnOff;
    const state = args[0];

    const mode: pipanda.printer.Session.LedMode = if (std.mem.eql(u8, state, "on"))
        .on
    else if (std.mem.eql(u8, state, "off"))
        .off
    else if (std.mem.eql(u8, state, "flashing"))
        .flashing
    else
        return error.ExpectedOnOff;

    const session = try openSession(gpa, arena, io, store, opts);
    defer session.close();

    try session.setChamberLight(mode);
    try out.print("Chamber light: {s}\n", .{@tagName(mode)});
    try out.flush();
}

fn openSession(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    store: pipanda.credentials.Store,
    opts: Options,
) !*pipanda.printer.Session {
    const creds = try loadCredentials(arena, store);
    const device_id = creds.device_id orelse {
        std.log.err("no printer selected; run `pipanda devices` then `pipanda use <device-id>`", .{});
        return error.NoPrinterSelected;
    };

    if (!opts.lan) {
        return pipanda.printer.Session.connect(gpa, io, device_id, .{ .cloud = .{
            .region = creds.region,
            .username = creds.mqtt_username,
            .access_token = creds.access_token,
        } });
    }

    const access_code = creds.device_access_code orelse {
        std.log.err("no LAN access code cached; run `pipanda devices` while online first", .{});
        return error.NoAccessCode;
    };
    // TODO: discover the printer via SSDP instead of requiring a hostname.
    const host = opts.printer_host orelse {
        std.log.err("set PIPANDA_PRINTER_HOST to the printer's IP for --lan", .{});
        return error.NoPrinterHost;
    };
    return pipanda.printer.Session.connect(gpa, io, device_id, .{ .lan = .{
        .host = host,
        .access_code = access_code,
    } });
}

fn loadCredentials(
    arena: Allocator,
    store: pipanda.credentials.Store,
) !pipanda.credentials.Credentials {
    return store.load(arena) catch |err| switch (err) {
        error.NotFound => {
            std.log.err("not logged in; run `pipanda login` first", .{});
            return err;
        },
        error.Corrupt => {
            std.log.err("stored credentials are unreadable; run `pipanda login` again", .{});
            return err;
        },
        else => return err,
    };
}

fn printSnapshot(out: *Io.Writer, s: pipanda.printer.Snapshot) !void {
    try out.print("{s: <9}", .{s.gcode_state orelse "?"});

    if (s.print_percent) |pct| {
        try out.print(" {d: >3}%", .{pct});
    } else {
        try out.writeAll("    ");
    }
    if (s.layer) |layer| {
        try out.print(" layer {d}/{d}", .{ layer, s.total_layers orelse 0 });
    }
    if (s.remaining_minutes) |mins| {
        try out.print(" eta {d}h{d:0>2}m", .{ @divTrunc(mins, 60), @mod(mins, 60) });
    }
    try out.print("  nozzle {d:.0}/{d:.0}C bed {d:.0}/{d:.0}C", .{
        s.nozzle_temp orelse 0,
        s.nozzle_target orelse 0,
        s.bed_temp orelse 0,
        s.bed_target orelse 0,
    });
    if (s.chamber_temp) |t| try out.print(" chamber {d:.0}C", .{t});
    if (s.chamber_light_on) |on| try out.print(" light {s}", .{if (on) "on" else "off"});
    if (s.active_hms_count) |count| {
        if (count > 0) try out.print("  !! {d} HMS alerts", .{count});
    }
    if (s.subtask_name) |name| {
        if (name.len > 0) try out.print("  {s}", .{name});
    }
    try out.writeByte('\n');
}

fn prompt(
    arena: Allocator,
    out: *Io.Writer,
    in: *Io.Reader,
    label: []const u8,
) ![]const u8 {
    try out.writeAll(label);
    try out.flush();
    return arena.dupe(u8, try readLine(in));
}

/// Same as `prompt`, but with terminal echo switched off so the secret does not
/// land on screen or in the user's scrollback.
fn promptSecret(
    arena: Allocator,
    out: *Io.Writer,
    in: *Io.Reader,
    label: []const u8,
) ![]const u8 {
    try out.writeAll(label);
    try out.flush();

    // Null when stdin is not a terminal (piped input), in which case there is
    // no echo to suppress and nothing to restore.
    const saved: ?std.posix.termios = saved: {
        if (@import("builtin").os.tag == .windows) break :saved null;
        const fd = Io.File.stdin().handle;
        const original = std.posix.tcgetattr(fd) catch break :saved null;
        var quiet = original;
        quiet.lflag.ECHO = false;
        std.posix.tcsetattr(fd, .FLUSH, quiet) catch break :saved null;
        break :saved original;
    };
    defer if (saved) |original| {
        std.posix.tcsetattr(Io.File.stdin().handle, .FLUSH, original) catch {};
    };

    const secret = try arena.dupe(u8, try readLine(in));

    // The user's own newline was not echoed, so supply one.
    if (saved != null) {
        try out.writeAll("\n");
        try out.flush();
    }
    return secret;
}

/// Reads and consumes one line.
///
/// Note `Reader.takeDelimiterExclusive` leaves the delimiter in the stream,
/// which makes the *next* read return an empty line immediately. `takeDelimiter`
/// consumes it and reports end-of-input as null.
fn readLine(in: *Io.Reader) ![]const u8 {
    const line = (try in.takeDelimiter('\n')) orelse return error.UnexpectedEndOfInput;
    return std.mem.trim(u8, line, " \r\t");
}

test readLine {
    var two_lines: Io.Reader = .fixed("me@example.com\nhunter2\n");
    try std.testing.expectEqualStrings("me@example.com", try readLine(&two_lines));
    // The regression: with `takeDelimiterExclusive` the newline stayed in the
    // stream and this returned "" without waiting for input, so the password was
    // submitted empty.
    try std.testing.expectEqualStrings("hunter2", try readLine(&two_lines));
    try std.testing.expectError(error.UnexpectedEndOfInput, readLine(&two_lines));

    // CRLF and surrounding whitespace are stripped.
    var crlf: Io.Reader = .fixed("  me@example.com \r\n");
    try std.testing.expectEqualStrings("me@example.com", try readLine(&crlf));

    // A final line with no terminator is still returned.
    var unterminated: Io.Reader = .fixed("trailing");
    try std.testing.expectEqualStrings("trailing", try readLine(&unterminated));

    // A blank line is a blank line, not end of input.
    var blank: Io.Reader = .fixed("\nx\n");
    try std.testing.expectEqualStrings("", try readLine(&blank));
    try std.testing.expectEqualStrings("x", try readLine(&blank));
}
