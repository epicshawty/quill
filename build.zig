const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const webview_dep = b.dependency("webview", .{
        .target = target,
        .optimize = optimize,
    });

    // ── md4c (vendored C, MIT) ───────────────────────────────────────────────
    const md4c_src = b.path("deps/md4c");
    const md4c_files: []const []const u8 = &.{ "md4c.c", "md4c-html.c", "entity.c" };

    // Zig 0.17 removed @cImport; C headers are translated at build time instead.
    const md4c_translate = b.addTranslateC(.{
        .root_source_file = b.path("deps/md4c/md4c-html.h"),
        .target = target,
        .optimize = optimize,
    });
    md4c_translate.addIncludePath(md4c_src);
    const md4c_mod = md4c_translate.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "webview", .module = webview_dep.module("webview") },
            .{ .name = "md4c", .module = md4c_mod },
        },
    });
    exe_mod.addIncludePath(md4c_src);
    exe_mod.addCSourceFiles(.{ .root = md4c_src, .files = md4c_files, .flags = &.{"-std=c99"} });

    const exe = b.addExecutable(.{ .name = "quill", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run Quill");
    run_step.dependOn(&run_cmd.step);

    // ── tests: markdown pipeline only, no GUI toolkit needed ────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "md4c", .module = md4c_mod },
        },
    });
    test_mod.addIncludePath(md4c_src);
    test_mod.addCSourceFiles(.{ .root = md4c_src, .files = md4c_files, .flags = &.{"-std=c99"} });

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run markdown rendering tests");
    test_step.dependOn(&run_tests.step);
}
