//! Quill — a markdown editor. The native window and HTML surface come from the
//! OS webview; every other responsibility (file I/O, markdown parsing, app
//! state, URL launching) is Zig.

const std = @import("std");
const Io = std.Io;

const Webview = @import("webview").Webview;
const render = @import("render.zig");
const images = @import("images.zig");
const platform = @import("platform.zig");

const index_html = @embedFile("assets/index.html");
const style_css = @embedFile("assets/style.css");
const app_js = @embedFile("assets/app.js");

pub const version = "0.1.2";

const welcome_md =
    \\# Quill
    \\
    \\A markdown editor with a native window, a Zig core, and a real renderer.
    \\
    \\Open a file with **Open** (or `Ctrl+O`), or pass one on the command line:
    \\
    \\```
    \\quill notes.md
    \\```
    \\
    \\## What it handles
    \\
    \\- **Bold**, *italic*, ~~strikethrough~~, `inline code`
    \\- [Links](https://commonmark.org) and bare URLs: https://ziglang.org
    \\- Tables, task lists, fenced code, blockquotes
    \\- Nested lists
    \\
    \\| Feature | Renders |
    \\| --- | --- |
    \\| Tables | yes |
    \\| Task lists | yes |
    \\| Raw HTML | escaped on purpose |
    \\
    \\> Markdown is parsed by md4c, so it is CommonMark 0.31.2 plus the GFM
    \\> extensions you expect — not a lookalike.
    \\
    \\### Task list
    \\
    \\- [x] Split view
    \\- [x] Live preview
    \\- [ ] Make it your own
    \\
    \\```zig
    \\std.log.info("hello from a code fence", .{});
    \\```
    \\
    \\---
    \\
    \\Keys: `Ctrl+S` save · `Ctrl+O` open · `Ctrl+E` toggle preview · `Ctrl+B/I/K` bold, italic, link
    \\
;

const usage =
    \\Quill {s} — markdown editor with a native window and a Zig core.
    \\
    \\Usage: quill [options] [file.md]
    \\
    \\Options:
    \\  -h, --help       Show this help and exit
    \\  -V, --version    Print the version and exit
    \\      --devtools   Enable the webview's developer tools
    \\
    \\Keys:
    \\  Ctrl+S / Ctrl+Shift+S   save to the opened file / export a copy
    \\  Ctrl+O                  open a file
    \\  Ctrl+E                  toggle the preview pane
    \\  Ctrl+B / I / K          bold, italic, link
    \\  Ctrl+= / - / 0          zoom
    \\
;

// ── app state ────────────────────────────────────────────────────────────────

const App = struct {
    alloc: std.mem.Allocator,
    io: Io,
    w: *Webview,
    /// Absolute path of the document being edited, when it has one.
    doc_path: ?[]const u8,
    /// Directory the document lives in, for resolving relative images.
    doc_dir: ?[]const u8,
    doc_name: []const u8,
    title_buf: [512]u8 = undefined,

    /// JS: `await qRender(markdown)` -> HTML fragment.
    fn onRender(self: *App, id: [:0]const u8, req: [:0]const u8) void {
        self.doRender(id, req) catch |err| self.rejectError(id, err);
    }

    fn doRender(self: *App, id: [:0]const u8, req: [:0]const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, req, .{});
        defer parsed.deinit();

        const markdown = try argString(parsed.value, 0);

        const raw_html = try render.toHtml(self.alloc, markdown);
        defer self.alloc.free(raw_html);

        const html = if (self.doc_dir) |dir|
            try images.inlineLocalImages(self.alloc, self.io, raw_html, .{ .doc_dir = dir })
        else
            try self.alloc.dupe(u8, raw_html);
        defer self.alloc.free(html);

        const payload = try jsonQuoteZ(self.alloc, html);
        defer self.alloc.free(payload);

        try self.w.respond(id, .ok, payload);
    }

    /// JS: `await qSave(text)` -> {"ok":bool}. Writes back to the file Quill
    /// was launched with; the browser file picker never exposes a real path.
    fn onSave(self: *App, id: [:0]const u8, req: [:0]const u8) void {
        self.doSave(id, req) catch |err| self.rejectError(id, err);
    }

    fn doSave(self: *App, id: [:0]const u8, req: [:0]const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, req, .{});
        defer parsed.deinit();

        const text = try argString(parsed.value, 0);
        const path = self.doc_path orelse {
            try self.w.respond(id, .ok, "{\"ok\":false}");
            return;
        };

        try platform.writeFile(self.io, path, text);
        try self.w.respond(id, .ok, "{\"ok\":true}");
    }

    /// JS: `qTitle(string)` — mirrors the document name into the window title.
    fn onTitle(self: *App, id: [:0]const u8, req: [:0]const u8) void {
        self.doTitle(id, req) catch |err| self.rejectError(id, err);
    }

    fn doTitle(self: *App, id: [:0]const u8, req: [:0]const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, req, .{});
        defer parsed.deinit();

        const title = try argString(parsed.value, 0);
        const wide = std.fmt.bufPrintSentinel(&self.title_buf, "{s}", .{title}, 0) catch return error.TitleTooLong;
        try self.w.setTitle(wide);
        try self.w.respond(id, .ok, "");
    }

    /// JS: `qOpenUrl(href)` — hand links to the user's browser, never navigate
    /// the app's own surface away from itself.
    fn onOpenUrl(self: *App, id: [:0]const u8, req: [:0]const u8) void {
        self.doOpenUrl(id, req) catch |err| self.rejectError(id, err);
    }

    fn doOpenUrl(self: *App, id: [:0]const u8, req: [:0]const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, req, .{});
        defer parsed.deinit();

        const url = try argString(parsed.value, 0);
        try platform.openUrl(self.io, url);
        try self.w.respond(id, .ok, "");
    }

    fn rejectError(self: *App, id: [:0]const u8, err: anyerror) void {
        const payload = jsonQuoteZ(self.alloc, @errorName(err)) catch return;
        defer self.alloc.free(payload);
        self.w.respond(id, .err, payload) catch {};
    }
};

fn argString(value: std.json.Value, index: usize) ![]const u8 {
    const items = switch (value) {
        .array => |list| list.items,
        else => return error.ExpectedArgumentArray,
    };
    if (index >= items.len) return error.MissingArgument;
    return switch (items[index]) {
        .string => |s| s,
        else => error.ExpectedStringArgument,
    };
}

// ── JSON helpers (hand-rolled: we only ever emit a JSON string) ──────────────

fn appendJsonString(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try list.appendSlice(alloc, "\\\""),
        '\\' => try list.appendSlice(alloc, "\\\\"),
        '\n' => try list.appendSlice(alloc, "\\n"),
        '\r' => try list.appendSlice(alloc, "\\r"),
        '\t' => try list.appendSlice(alloc, "\\t"),
        else => {
            if (ch < 0x20) {
                var escape: [8]u8 = undefined;
                const text = std.fmt.bufPrint(&escape, "\\u{x:0>4}", .{ch}) catch unreachable;
                try list.appendSlice(alloc, text);
            } else {
                try list.append(alloc, ch);
            }
        },
    };
    try list.append(alloc, '"');
}

fn jsonQuoteZ(alloc: std.mem.Allocator, s: []const u8) ![:0]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try appendJsonString(&list, alloc, s);
    return list.toOwnedSliceSentinel(alloc, 0);
}

// ── page assembly ────────────────────────────────────────────────────────────

/// Inlines the stylesheet and script into the shell document.
fn buildPage(alloc: std.mem.Allocator) ![:0]u8 {
    const with_style = try std.mem.replaceOwned(u8, alloc, index_html, "/*STYLE*/", style_css);
    defer alloc.free(with_style);

    const page = try std.mem.replaceOwned(u8, alloc, with_style, "/*SCRIPT*/", app_js);
    defer alloc.free(page);

    return alloc.dupeSentinel(u8, page, 0);
}

fn buildInitScript(
    alloc: std.mem.Allocator,
    name: []const u8,
    path: ?[]const u8,
    text: []const u8,
) ![:0]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);

    try list.appendSlice(alloc, "window.__QUILL__={\"name\":");
    try appendJsonString(&list, alloc, name);
    try list.appendSlice(alloc, ",\"path\":");
    if (path) |p| {
        try appendJsonString(&list, alloc, p);
    } else {
        try list.appendSlice(alloc, "null");
    }
    try list.appendSlice(alloc, ",\"text\":");
    try appendJsonString(&list, alloc, text);
    try list.appendSlice(alloc, "};");

    return list.toOwnedSliceSentinel(alloc, 0);
}

// ── entry point ──────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const alloc = init.gpa;

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);

    var devtools = false;
    var file_arg: ?[]const u8 = null;

    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const text = try std.fmt.allocPrint(arena, usage, .{version});
            try writeStdout(io, text);
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            try writeStdout(io, "quill " ++ version ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "--devtools")) {
            devtools = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("quill: unknown option '{s}' (try --help)\n", .{arg});
            return;
        } else if (file_arg == null) {
            file_arg = arg;
        }
    }

    // Document to open: the CLI path if it resolves, otherwise the welcome doc.
    var doc_text: []const u8 = welcome_md;
    var doc_path: ?[]const u8 = null;
    var doc_dir: ?[]const u8 = null;
    var doc_name: []const u8 = "untitled.md";

    if (file_arg) |arg| {
        doc_name = std.fs.path.basename(arg);
        if (platform.absolutePath(io, arena, arg)) |abs| {
            doc_path = abs;
            if (platform.readFile(io, arena, abs)) |text| {
                doc_text = text;
                doc_dir = std.fs.path.dirname(abs);
            } else |err| {
                std.debug.print("quill: cannot read '{s}': {s}\n", .{ arg, @errorName(err) });
                doc_path = null;
                doc_name = "untitled.md";
            }
        } else {
            std.debug.print("quill: no such file '{s}'\n", .{arg});
            doc_name = "untitled.md";
        }
    }

    const w = try Webview.create(devtools, null);
    defer w.destroy() catch {};

    try w.setTitle("Quill");
    try w.setSize(1180, 780, .none);

    var app: App = .{
        .alloc = alloc,
        .io = io,
        .w = w,
        .doc_path = doc_path,
        .doc_dir = doc_dir,
        .doc_name = doc_name,
    };

    try w.bind(App, "qRender", App.onRender, &app);
    try w.bind(App, "qSave", App.onSave, &app);
    try w.bind(App, "qTitle", App.onTitle, &app);
    try w.bind(App, "qOpenUrl", App.onOpenUrl, &app);

    const init_script = try buildInitScript(arena, doc_name, doc_path, doc_text);
    try w.addInitScript(init_script);

    const page = try buildPage(arena);
    try w.setHtml(page);

    try w.run();
}

fn writeStdout(io: Io, text: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}
