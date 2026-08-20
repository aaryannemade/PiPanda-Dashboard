//! MakerWorld model browsing: keyword search, a newest-first feed, and the
//! detail record behind one design.
//!
//! MakerWorld publishes no API. These endpoints are the ones makerworld.com's
//! own frontend calls, found by probing; treat them as reverse engineered and
//! as liable to move without notice.
//!
//! Three things here are load-bearing and look wrong if you do not know why:
//!
//!  - Search is `search-service/search/design`. There is also a
//!    `search-service/select/design`, which *accepts* `keyword`, returns 200,
//!    and always answers `{"total":0,"hits":[]}`. It looks like the search
//!    endpoint and it is not. `select/design` is only good for the unfiltered
//!    newest-first feed, which is what this module uses when no keyword is
//!    given, so both paths are here and neither is redundant.
//!  - No credentials are involved. Every call is anonymous, which is the reason
//!    this is not part of `bambu/cloud.zig`: none of the Orca Slicer
//!    impersonation headers or the region/token plumbing applies. Cloudflare
//!    fronts makerworld.com HTML but not `/api/*`, and any User-Agent passes.
//!  - Replies are projected down to the handful of fields the dashboard draws.
//!    A raw 24-hit search page is ~81 KB of JSON across ~45 fields per hit,
//!    almost all of it contest/AB-test/moderation bookkeeping. Forwarding that
//!    verbatim would push megabytes per scroll through a 512 MB Pi.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = @import("log.zig");

const search_url = "https://makerworld.com/api/v1/search-service/search/design";
const feed_url = "https://makerworld.com/api/v1/search-service/select/design";
const design_url = "https://makerworld.com/api/v1/design-service/design/";

/// Public model page, for the "open on MakerWorld" link. The slug is cosmetic;
/// the id is what resolves.
pub const web_url_prefix = "https://makerworld.com/en/models/";

/// The site serves covers straight from its CDN and the browser fetches them
/// directly, so this is only here to document the contract the frontend relies
/// on: appending `?x-oss-process=image/resize,w_<n>` turns a 3 MB JPEG into a
/// ~6 KB WebP. Nothing in this module rewrites the URL.
pub const cover_resize_query = "x-oss-process=image/resize,w_";

/// How many hits one page may ask for. The upper bound is a memory guard, not
/// a server limit.
pub const max_page_size: u32 = 48;
pub const default_page_size: u32 = 24;

/// Cap on maker-uploaded gallery pictures carried through to the detail
/// payload. The URLs are cheap but the array is author-controlled and
/// unbounded, and twelve is more than any dialog needs.
pub const max_gallery_pictures: usize = 12;

pub const Error = error{
    /// MakerWorld answered with something that is not the shape we parse.
    UnexpectedResponse,
    /// The design id does not exist, or is not public.
    NotFound,
    HttpRequestFailed,
    OutOfMemory,
};

/// One search hit or feed entry, reduced to what a card draws.
pub const Model = struct {
    id: i64,
    title: []const u8,
    /// URL path segment; only used to build the public model link.
    slug: []const u8,
    /// CDN cover, unresized. Empty when the design has no render.
    cover: []const u8,
    creator: []const u8,
    like_count: i64,
    download_count: i64,
    print_count: i64,
    collection_count: i64,
    /// MakerWorld's own adult flag. Passed through so the UI can decide; this
    /// module never filters on it.
    nsfw: bool,
};

pub const Page = struct {
    /// MakerWorld caps this at 10000 for broad queries, so treat it as "at
    /// least this many" rather than an exact count.
    total: i64,
    models: []const Model,
};

/// The design record behind one model, for the detail view.
pub const Detail = struct {
    model: Model,
    /// Description as HTML. Never rendered as markup by the frontend.
    summary: []const u8,
    license: []const u8,
    tags: []const []const u8,
    categories: []const []const u8,
    /// Number of published print profiles ("instances" in MakerWorld's terms).
    instance_count: usize,
    comment_count: i64,
    /// Maker-uploaded gallery images from `designExtension.design_pictures`,
    /// capped at `max_gallery_pictures`. The cover is deliberately not
    /// repeated here; the frontend puts it first itself.
    pictures: []const []const u8,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    http: std.http.Client,

    pub fn init(gpa: Allocator, io: Io) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .http = .{
                .allocator = gpa,
                .io = io,
                // `now` must be left null. `std.http.Client.request` treats a
                // non-null `now` as "the CA bundle is already populated" and
                // skips loading it, which makes every handshake fail with
                // TlsCertificateNotVerified. It sets both on first use.
                .now = null,
            },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    /// A 48-hit page is ~164 KB and the largest reply this module asks for.
    /// Anything past this cap is a redesign or a block page, and an unbounded
    /// read would be an OOM on a 512 MB Pi.
    const json_limit: Io.Limit = .limited(4 * 1024 * 1024);

    /// Issues one anonymous GET. The body is allocated in `arena`.
    fn get(self: *Client, arena: Allocator, url: []const u8) Error![]const u8 {
        const uri = std.Uri.parse(url) catch return error.UnexpectedResponse;

        var req = self.http.request(.GET, uri, .{
            .headers = .{
                // MakerWorld does not care what this says, but an honest one
                // makes the traffic identifiable in their logs.
                .user_agent = .{ .override = "pipanda/0.1 (+https://github.com/anomalyco/pipanda)" },
                // Keep zstd off the table so a fixed flate-sized decompression
                // buffer is enough.
                .accept_encoding = .{ .override = "gzip, deflate" },
            },
            .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .redirect_behavior = @enumFromInt(3),
        }) catch return error.HttpRequestFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.HttpRequestFailed;

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.HttpRequestFailed;

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        const body_reader = response.readerDecompressing(
            &transfer_buffer,
            &decompress,
            &decompress_buffer,
        );
        const body = body_reader.allocRemaining(arena, json_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.UnexpectedResponse,
            else => return error.HttpRequestFailed,
        };

        log.debug("makerworld GET {s} -> {d} ({d} bytes)", .{
            url,
            @intFromEnum(response.head.status),
            body.len,
        });

        if (response.head.status == .not_found) return error.NotFound;
        if (@intFromEnum(response.head.status) >= 300) {
            log.debug("  body: {s}", .{log.prefix(body, 512)});
            return error.HttpRequestFailed;
        }
        return body;
    }

    /// Searches when `keyword` is non-empty, otherwise returns the newest-first
    /// feed. Everything returned is allocated in `arena`.
    pub fn browse(
        self: *Client,
        arena: Allocator,
        keyword: []const u8,
        offset: u32,
        limit: u32,
    ) Error!Page {
        const capped = @min(if (limit == 0) default_page_size else limit, max_page_size);

        var url: Io.Writer.Allocating = .init(arena);
        if (keyword.len == 0) {
            url.writer.print("{s}?offset={d}&limit={d}", .{ feed_url, offset, capped }) catch
                return error.OutOfMemory;
        } else {
            url.writer.print("{s}?keyword=", .{search_url}) catch return error.OutOfMemory;
            std.Uri.Component.percentEncode(&url.writer, keyword, isUnreservedChar) catch
                return error.OutOfMemory;
            url.writer.print("&offset={d}&limit={d}", .{ offset, capped }) catch
                return error.OutOfMemory;
        }

        const body = try self.get(arena, url.written());
        return parsePage(arena, body);
    }

    /// Fetches one design record. Everything returned is allocated in `arena`.
    pub fn detail(self: *Client, arena: Allocator, id: i64) Error!Detail {
        const url = std.fmt.allocPrint(arena, "{s}{d}", .{ design_url, id }) catch
            return error.OutOfMemory;
        const body = try self.get(arena, url);
        return parseDetail(arena, body);
    }
};

// --- Parsing --------------------------------------------------------------

/// Every reply is parsed as a dynamic tree rather than into a struct. MakerWorld
/// adds and renames fields freely, and a typed parse would turn a harmless new
/// key into a hard failure of the whole page.
fn parsePage(arena: Allocator, body: []const u8) Error!Page {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return error.UnexpectedResponse;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.UnexpectedResponse,
    };

    const hits = switch (obj.get("hits") orelse return error.UnexpectedResponse) {
        .array => |a| a,
        // A query that matches nothing serialises `hits` as null rather than
        // as an empty array.
        .null => return .{ .total = 0, .models = &.{} },
        else => return error.UnexpectedResponse,
    };

    var models: std.ArrayList(Model) = .empty;
    try models.ensureTotalCapacity(arena, hits.items.len);
    for (hits.items) |hit| {
        const entry = switch (hit) {
            .object => |o| o,
            else => continue,
        };
        models.appendAssumeCapacity(parseModel(entry));
    }

    return .{
        .total = integerField(obj, "total") orelse @as(i64, @intCast(models.items.len)),
        .models = models.items,
    };
}

/// The search hit and the design record disagree on two key names for the same
/// value, so both spellings are accepted here rather than duplicating the
/// projection.
fn parseModel(obj: std.json.ObjectMap) Model {
    const creator = switch (obj.get("designCreator") orelse std.json.Value{ .null = {} }) {
        .object => |c| stringField(c, "name") orelse "",
        else => "",
    };
    return .{
        .id = integerField(obj, "id") orelse 0,
        .title = stringField(obj, "title") orelse "",
        .slug = stringField(obj, "slug") orelse "",
        .cover = stringField(obj, "cover") orelse stringField(obj, "coverUrl") orelse "",
        .creator = creator,
        .like_count = integerField(obj, "likeCount") orelse 0,
        .download_count = integerField(obj, "downloadCount") orelse 0,
        .print_count = integerField(obj, "printCount") orelse 0,
        .collection_count = integerField(obj, "collectionCount") orelse 0,
        .nsfw = boolField(obj, "nsfw") orelse false,
    };
}

fn parseDetail(arena: Allocator, body: []const u8) Error!Detail {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return error.UnexpectedResponse;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.UnexpectedResponse,
    };
    // A deleted or private design answers 200 with an error envelope rather
    // than 404, so the absence of an id is the only reliable signal.
    if (obj.get("id") == null) return error.NotFound;

    return .{
        .model = parseModel(obj),
        .summary = stringField(obj, "summary") orelse "",
        .license = stringField(obj, "license") orelse "",
        .tags = try stringArray(arena, obj.get("tags")),
        .categories = try namedArray(arena, obj.get("categories")),
        .instance_count = switch (obj.get("instances") orelse std.json.Value{ .null = {} }) {
            .array => |a| a.items.len,
            else => 0,
        },
        .comment_count = integerField(obj, "commentCount") orelse 0,
        .pictures = try galleryPictures(arena, obj.get("designExtension")),
    };
}

/// Digs the maker's gallery out of `designExtension.design_pictures`, which is
/// a list of `{name, url, ...}` records. Missing/null at any level means no
/// gallery, not a failure.
fn galleryPictures(arena: Allocator, value: ?std.json.Value) Error![]const []const u8 {
    const ext = switch (value orelse return &.{}) {
        .object => |o| o,
        else => return &.{},
    };
    const pictures = switch (ext.get("design_pictures") orelse return &.{}) {
        .array => |a| a,
        else => return &.{},
    };

    var out: std.ArrayList([]const u8) = .empty;
    const cap = @min(pictures.items.len, max_gallery_pictures);
    try out.ensureTotalCapacity(arena, cap);
    for (pictures.items) |item| {
        if (out.items.len >= max_gallery_pictures) break;
        switch (item) {
            .object => |o| if (stringField(o, "url")) |url| {
                if (url.len != 0) out.appendAssumeCapacity(url);
            },
            else => {},
        }
    }
    return out.items;
}

/// Collects a JSON array of strings, skipping anything that is not one.
fn stringArray(arena: Allocator, value: ?std.json.Value) Error![]const []const u8 {
    const array = switch (value orelse return &.{}) {
        .array => |a| a,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    try out.ensureTotalCapacity(arena, array.items.len);
    for (array.items) |item| switch (item) {
        .string => |s| if (s.len != 0) out.appendAssumeCapacity(s),
        else => {},
    };
    return out.items;
}

/// Collects the `name` of each object in a JSON array. `categories` is a list
/// of records of which only the label is interesting.
fn namedArray(arena: Allocator, value: ?std.json.Value) Error![]const []const u8 {
    const array = switch (value orelse return &.{}) {
        .array => |a| a,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    try out.ensureTotalCapacity(arena, array.items.len);
    for (array.items) |item| switch (item) {
        .object => |o| if (stringField(o, "name")) |name| {
            if (name.len != 0) out.appendAssumeCapacity(name);
        },
        else => {},
    };
    return out.items;
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn integerField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (obj.get(name) orelse return null) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string, .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, name: []const u8) ?bool {
    return switch (obj.get(name) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

/// RFC 3986 unreserved set. Deliberately conservative: encoding a character
/// that did not need it is harmless, leaving one raw is not.
fn isUnreservedChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

// --- Tests ----------------------------------------------------------------

test parsePage {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Trimmed from a real reply to `search/design?keyword=benchy`.
    const body =
        \\{"total":7122,"hits":[{"id":3047341,"title":"Benchy Light Switch",
        \\"slug":"benchy-light-switch",
        \\"cover":"https://makerworld.bblmw.com/a.jpg","likeCount":3,
        \\"downloadCount":0,"printCount":0,"collectionCount":2,"nsfw":false,
        \\"designCreator":{"uid":240171646,"name":"OLIVER","handle":"Olk2017"},
        \\"contest":{"contestId":0}}],"suggest":{"options":[]}}
    ;
    const page = try parsePage(arena.allocator(), body);
    try std.testing.expectEqual(@as(i64, 7122), page.total);
    try std.testing.expectEqual(@as(usize, 1), page.models.len);
    try std.testing.expectEqualStrings("Benchy Light Switch", page.models[0].title);
    try std.testing.expectEqualStrings("OLIVER", page.models[0].creator);
    try std.testing.expectEqual(@as(i64, 2), page.models[0].collection_count);
}

test "parsePage tolerates a null hits array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // `select/all` answers this shape, and an empty search can too. Treating a
    // null `hits` as a hard error would surface as a 502 on a query that
    // simply matched nothing.
    const page = try parsePage(arena.allocator(), "{\"total\":0,\"hits\":null}");
    try std.testing.expectEqual(@as(i64, 0), page.total);
    try std.testing.expectEqual(@as(usize, 0), page.models.len);
}

test "parsePage rejects a non-object reply" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.UnexpectedResponse, parsePage(arena.allocator(), "[]"));
    try std.testing.expectError(error.UnexpectedResponse, parsePage(arena.allocator(), "nope"));
    // A 200 with no `hits` at all is a redesign, not an empty result.
    try std.testing.expectError(error.UnexpectedResponse, parsePage(arena.allocator(), "{\"total\":3}"));
}

test parseDetail {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // The detail record spells the cover `coverUrl`, where a search hit spells
    // it `cover`; both must land in the same field.
    const body =
        \\{"id":3047341,"title":"Benchy Light Switch","slug":"benchy-light-switch",
        \\"coverUrl":"https://makerworld.bblmw.com/a.jpg","summary":"<p>hi</p>",
        \\"license":"BY-NC","likeCount":3,"commentCount":4,
        \\"tags":["BENCHY","",  "benchy"],
        \\"categories":[{"id":401,"name":"Decor"},{"id":400,"name":"Household"}],
        \\"instances":[{"id":1},{"id":2}],
        \\"designCreator":{"name":"OLIVER"},
        \\"designExtension":{"design_setting":{"makerLab":""},
        \\"design_pictures":[{"name":"1.jpg","url":"https://makerworld.bblmw.com/p1.jpg"},
        \\{"name":"","url":""},
        \\"not-an-object",
        \\{"name":"2.jpg","url":"https://makerworld.bblmw.com/p2.jpg"}]}}
    ;
    const detail = try parseDetail(arena.allocator(), body);
    try std.testing.expectEqualStrings("https://makerworld.bblmw.com/a.jpg", detail.model.cover);
    try std.testing.expectEqualStrings("BY-NC", detail.license);
    try std.testing.expectEqual(@as(usize, 2), detail.instance_count);
    try std.testing.expectEqual(@as(i64, 4), detail.comment_count);
    // The empty tag is dropped rather than rendered as a blank chip.
    try std.testing.expectEqual(@as(usize, 2), detail.tags.len);
    try std.testing.expectEqualStrings("Decor", detail.categories[0]);
    try std.testing.expectEqualStrings("Household", detail.categories[1]);
    // An empty url and a non-object entry are skipped, not fatal.
    try std.testing.expectEqual(@as(usize, 2), detail.pictures.len);
    try std.testing.expectEqualStrings("https://makerworld.bblmw.com/p1.jpg", detail.pictures[0]);
}

test "galleryPictures caps the count" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Makers can upload dozens of photos; the payload only carries the first
    // twelve so a gallery-heavy design cannot bloat the reply.
    var buf: Io.Writer.Allocating = .init(arena.allocator());
    try buf.writer.writeAll("{\"id\":1,\"designExtension\":{\"design_pictures\":[");
    for (0..max_gallery_pictures + 5) |i| {
        if (i != 0) try buf.writer.writeAll(",");
        try buf.writer.print("{{\"url\":\"https://x/{d}.jpg\"}}", .{i});
    }
    try buf.writer.writeAll("]}}");

    const detail = try parseDetail(arena.allocator(), buf.written());
    try std.testing.expectEqual(max_gallery_pictures, detail.pictures.len);
}

test "galleryPictures tolerates a missing extension" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // No designExtension, a null one, and a pictures array of nulls: all are
    // designs without a gallery rather than errors.
    const detail = try parseDetail(arena.allocator(), "{\"id\":1}");
    try std.testing.expectEqual(@as(usize, 0), detail.pictures.len);

    const null_ext = try parseDetail(arena.allocator(), "{\"id\":1,\"designExtension\":null}");
    try std.testing.expectEqual(@as(usize, 0), null_ext.pictures.len);

    const null_pics = try parseDetail(
        arena.allocator(),
        "{\"id\":1,\"designExtension\":{\"design_pictures\":null}}",
    );
    try std.testing.expectEqual(@as(usize, 0), null_pics.pictures.len);
}

test "parseDetail treats a missing id as not found" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // What a withdrawn design answers, with a 200 status.
    try std.testing.expectError(
        error.NotFound,
        parseDetail(arena.allocator(), "{\"code\":404,\"error\":\"gone\"}"),
    );
}

test isUnreservedChar {
    // A space must not survive into the query string, and `&` must not be able
    // to smuggle in another parameter.
    try std.testing.expect(!isUnreservedChar(' '));
    try std.testing.expect(!isUnreservedChar('&'));
    try std.testing.expect(!isUnreservedChar('='));
    try std.testing.expect(!isUnreservedChar('%'));
    try std.testing.expect(isUnreservedChar('a'));
    try std.testing.expect(isUnreservedChar('9'));
    try std.testing.expect(isUnreservedChar('-'));
}
