//! Local image support.
//!
//! The page inside the webview has an opaque origin, so it cannot fetch
//! `file://` subresources: a relative `![alt](pic.png)` would render broken.
//! Instead the Zig side reads the file the document points at and rewrites the
//! `<img>` source into a `data:` URI before the HTML reaches the browser.

const std = @import("std");
const Io = std.Io;

/// Images larger than this are left alone rather than inlined.
pub const max_image_bytes: usize = 12 * 1024 * 1024;

pub const Options = struct {
    /// Directory the document lives in; relative sources resolve against it.
    doc_dir: []const u8,
};

/// Rewrites relative `<img src="...">` references to `data:` URIs.
/// Absolute URLs (`http:`, `data:`, `//host`) and unresolvable paths are kept
/// exactly as they were.
pub fn inlineLocalImages(
    alloc: std.mem.Allocator,
    io: Io,
    html: []const u8,
    options: Options,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var cursor: usize = 0;
    while (findTag(html, cursor)) |tag_start| {
        const tag_end = findTagEnd(html, tag_start) orelse break;

        try out.appendSlice(alloc, html[cursor..tag_start]);

        const tag = html[tag_start..tag_end];
        const rewritten = try rewriteTag(alloc, io, tag, options) orelse {
            try out.appendSlice(alloc, tag);
            cursor = tag_end;
            continue;
        };
        defer alloc.free(rewritten);

        try out.appendSlice(alloc, rewritten);
        cursor = tag_end;
    }

    try out.appendSlice(alloc, html[cursor..]);
    return out.toOwnedSlice(alloc);
}

fn findTag(html: []const u8, from: usize) ?usize {
    return std.mem.indexOfPos(u8, html, from, "<img ");
}

fn findTagEnd(html: []const u8, from: usize) ?usize {
    const end = std.mem.indexOfScalarPos(u8, html, from, '>') orelse return null;
    return end + 1;
}

const Span = struct { start: usize, end: usize };

fn attrValue(tag: []const u8, name: []const u8) ?Span {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, tag, search, name)) |hit| {
        const after = hit + name.len;
        if (after >= tag.len or tag[after] != '=') {
            search = after;
            continue;
        }
        var value_start = after + 1;
        if (value_start >= tag.len) return null;
        const quote = tag[value_start];
        if (quote != '"' and quote != '\'') {
            // Unquoted value: read to whitespace or tag end.
            var i = value_start;
            while (i < tag.len and tag[i] != ' ' and tag[i] != '>') : (i += 1) {}
            return .{ .start = value_start, .end = i };
        }
        value_start += 1;
        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
        return .{ .start = value_start, .end = value_end };
    }
    return null;
}

/// Returns a new tag with the `src` attribute replaced, or null when the tag
/// should be left untouched.
fn rewriteTag(
    alloc: std.mem.Allocator,
    io: Io,
    tag: []const u8,
    options: Options,
) !?[]u8 {
    const span = attrValue(tag, "src") orelse return null;
    const raw_src = tag[span.start..span.end];
    if (raw_src.len == 0) return null;
    if (isAbsoluteSource(raw_src)) return null;

    const src = try decodeEntities(alloc, raw_src);
    defer alloc.free(src);

    const mime = mimeFor(src) orelse return null;

    const path = if (std.fs.path.isAbsolute(src))
        try alloc.dupe(u8, src)
    else
        try std.fs.path.join(alloc, &.{ options.doc_dir, src });
    defer alloc.free(path);

    const bytes = readLimited(alloc, io, path) catch return null;
    defer alloc.free(bytes);

    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const data_uri = try alloc.alloc(u8, "data:".len + mime.len + ";base64,".len + encoded_len);
    defer alloc.free(data_uri);

    @memcpy(data_uri[0.."data:".len], "data:");
    var at: usize = "data:".len;
    @memcpy(data_uri[at .. at + mime.len], mime);
    at += mime.len;
    @memcpy(data_uri[at .. at + ";base64,".len], ";base64,");
    at += ";base64,".len;
    _ = std.base64.standard.Encoder.encode(data_uri[at..], bytes);

    var rebuilt: std.ArrayList(u8) = .empty;
    errdefer rebuilt.deinit(alloc);
    try rebuilt.appendSlice(alloc, tag[0..span.start]);
    try rebuilt.appendSlice(alloc, data_uri);
    try rebuilt.appendSlice(alloc, tag[span.end..]);
    return try rebuilt.toOwnedSlice(alloc);
}

fn isAbsoluteSource(src: []const u8) bool {
    if (std.mem.startsWith(u8, src, "//")) return true;
    if (std.mem.startsWith(u8, src, "#")) return true;
    const colon = std.mem.indexOfScalar(u8, src, ':') orelse return false;
    const scheme = src[0..colon];
    if (scheme.len == 0) return false;
    for (scheme) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    return true;
}

fn readLimited(alloc: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_image_bytes));
}

fn mimeFor(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    const known = .{
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        .{ ".bmp", "image/bmp" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ico", "image/x-icon" },
    };
    inline for (known) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    }
    return null;
}

/// md4c escapes attribute values, so `&amp;` and friends must be undone before
/// the string is used as a path.
fn decodeEntities(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            const rest = raw[i..];
            const replacements = .{
                .{ "&amp;", "&" },
                .{ "&quot;", "\"" },
                .{ "&lt;", "<" },
                .{ "&gt;", ">" },
                .{ "&#39;", "'" },
                .{ "&apos;", "'" },
            };
            var matched = false;
            inline for (replacements) |pair| {
                if (!matched and std.mem.startsWith(u8, rest, pair[0])) {
                    try out.appendSlice(alloc, pair[1]);
                    i += pair[0].len;
                    matched = true;
                }
            }
            if (matched) continue;
        }
        try out.append(alloc, raw[i]);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "relative image becomes a data uri" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0 };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pic.png", .data = &png });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &buf);

    const html = "<p><img src=\"pic.png\" alt=\"p\" /></p>";
    const out = try inlineLocalImages(testing.allocator, testing.io, html, .{ .doc_dir = buf[0..dir_len] });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "data:image/png;base64,") != null);
    try testing.expect(std.mem.indexOf(u8, out, "src=\"pic.png\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "alt=\"p\"") != null);
}

test "remote and data sources are left alone" {
    const html = "<img src=\"https://example.com/x.png\"><img src=\"data:image/png;base64,AA\">";
    const out = try inlineLocalImages(testing.allocator, testing.io, html, .{ .doc_dir = "." });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(html, out);
}

test "missing files keep their original tag" {
    const html = "<img src=\"nope.png\" alt=\"x\">";
    const out = try inlineLocalImages(testing.allocator, testing.io, html, .{ .doc_dir = "." });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(html, out);
}

test "entity escaping is decoded for the path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gif = [_]u8{ 'G', 'I', 'F', '8', '9', 'a' };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a&b.gif", .data = &gif });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &buf);

    const html = "<img src=\"a&amp;b.gif\">";
    const out = try inlineLocalImages(testing.allocator, testing.io, html, .{ .doc_dir = buf[0..dir_len] });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "data:image/gif;base64,") != null);
}

test "html without images is returned unchanged" {
    const html = "<h1>Title</h1>\n<p>No pictures here.</p>\n";
    const out = try inlineLocalImages(testing.allocator, testing.io, html, .{ .doc_dir = "." });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(html, out);
}
