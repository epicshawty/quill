//! The only OS-specific code in Quill: file I/O and "open this URL in the
//! user's browser". Everything else is portable Zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Refuse to load anything larger than this into the editor.
pub const max_file_bytes: usize = 32 * 1024 * 1024;

pub fn readFile(io: Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_file_bytes));
}

pub fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Resolves `path` to an absolute, symlink-free path. Returns null when the
/// file does not exist (nothing to resolve against).
pub fn absolutePath(io: Io, alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const abs = std.Io.Dir.cwd().realPathFileAlloc(io, path, alloc) catch return null;
    return abs;
}

pub fn openUrl(io: Io, url: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => try openUrlWindows(url),
        .macos => try spawnDetached(io, &.{ "open", url }),
        else => try spawnDetached(io, &.{ "xdg-open", url }),
    }
}

fn spawnDetached(io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = child.wait(io) catch {};
}

fn openUrlWindows(url: []const u8) !void {
    const shell32 = struct {
        extern "shell32" fn ShellExecuteW(
            hwnd: ?*anyopaque,
            operation: [*:0]const u16,
            file: [*:0]const u16,
            parameters: ?[*:0]const u16,
            directory: ?[*:0]const u16,
            show_cmd: c_int,
        ) callconv(.winapi) ?*anyopaque;
    };

    var buffer: [4096]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&buffer, url);
    buffer[len] = 0;
    const wide = buffer[0..len :0];

    const wide_op = [_:0]u16{ 'o', 'p', 'e', 'n' };
    _ = shell32.ShellExecuteW(null, &wide_op, wide, null, null, 1);
}
