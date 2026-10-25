//! Markdown -> HTML rendering, via md4c (CommonMark 0.31.2 + GFM extensions).
//!
//! Raw HTML in the source is escaped, never passed through: the document is
//! displayed inside a webview that can reach this program's bindings, so a
//! hostile `.md` file must not be able to run script.

const std = @import("std");

const c = @import("md4c");

pub const Error = error{ OutOfMemory, MarkdownParseFailed };

/// GitHub-Flavored Markdown feature set: tables, strikethrough, task lists,
/// bare-URL autolinks. Plus HTML suppression.
const parser_flags: c_uint = c.MD_FLAG_TABLES |
    c.MD_FLAG_STRIKETHROUGH |
    c.MD_FLAG_TASKLISTS |
    c.MD_FLAG_PERMISSIVEAUTOLINKS |
    c.MD_FLAG_NOHTMLBLOCKS |
    c.MD_FLAG_NOHTMLSPANS;

const Sink = struct {
    list: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    oom: bool = false,
};

fn collect(chunk: [*c]const u8, size: c_uint, userdata: ?*anyopaque) callconv(.c) void {
    const sink: *Sink = @ptrCast(@alignCast(userdata.?));
    if (size == 0) return;
    sink.list.appendSlice(sink.alloc, chunk[0..size]) catch {
        sink.oom = true;
    };
}

/// Renders markdown to an HTML fragment. Caller owns the returned string.
pub fn toHtml(alloc: std.mem.Allocator, markdown: []const u8) Error![]u8 {
    var sink: Sink = .{ .list = .empty, .alloc = alloc };
    errdefer sink.list.deinit(alloc);

    const src = if (markdown.len == 0) "" else markdown;
    const len = std.math.cast(c_uint, src.len) orelse return error.MarkdownParseFailed;
    const rc = c.md_html(src.ptr, len, collect, &sink, parser_flags, 0);

    if (sink.oom) return error.OutOfMemory;
    if (rc < 0) return error.MarkdownParseFailed;

    return sink.list.toOwnedSlice(alloc);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nexpected to contain: {s}\nactual:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContent;
    }
}

test "headings and paragraphs" {
    const html = try toHtml(testing.allocator, "# Title\n\nBody text.\n");
    defer testing.allocator.free(html);
    try expectContains(html, "<h1>Title</h1>");
    try expectContains(html, "<p>Body text.</p>");
}

test "inline emphasis, code and strikethrough" {
    const html = try toHtml(testing.allocator, "**bold** *em* `code` ~~gone~~");
    defer testing.allocator.free(html);
    try expectContains(html, "<strong>bold</strong>");
    try expectContains(html, "<em>em</em>");
    try expectContains(html, "<code>code</code>");
    try expectContains(html, "<del>gone</del>");
}

test "gfm tables" {
    const html = try toHtml(testing.allocator,
        \\| a | b |
        \\| --- | --- |
        \\| 1 | 2 |
    );
    defer testing.allocator.free(html);
    try expectContains(html, "<table>");
    try expectContains(html, "<th>a</th>");
    try expectContains(html, "<td>1</td>");
}

test "gfm task lists" {
    const html = try toHtml(testing.allocator, "- [x] done\n- [ ] todo\n");
    defer testing.allocator.free(html);
    try expectContains(html, "type=\"checkbox\"");
    try expectContains(html, "checked");
}

test "fenced code keeps language class" {
    const html = try toHtml(testing.allocator, "```zig\nconst x = 1;\n```\n");
    defer testing.allocator.free(html);
    try expectContains(html, "<pre><code class=\"language-zig\">");
}

test "bare urls autolink" {
    const html = try toHtml(testing.allocator, "see https://ziglang.org now");
    defer testing.allocator.free(html);
    try expectContains(html, "<a href=\"https://ziglang.org\">");
}

test "raw html is escaped, not executed" {
    const html = try toHtml(testing.allocator, "<script>alert(1)</script>");
    defer testing.allocator.free(html);
    try expectContains(html, "&lt;script&gt;");
    try testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
}

test "empty input" {
    const html = try toHtml(testing.allocator, "");
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("", html);
}

test "unicode passes through intact" {
    const html = try toHtml(testing.allocator, "# 日本語 — ünïcode\n");
    defer testing.allocator.free(html);
    try expectContains(html, "日本語 — ünïcode");
}

test "image inlining tests are compiled into this binary" {
    _ = @import("images.zig");
}
