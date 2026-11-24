//! Umbrella build: re-exports each library's module and tests them all.
//! Library-specific steps (examples, fuzzing) live in each library's folder.
//!
//!   zig build test    test every library
//!   zig build docs    API reference for every library in zig-out/docs

const std = @import("std");

/// Each entry is a dependency in build.zig.zon and a module users can import.
const libraries = [_]struct {
    dep: []const u8,
    module: []const u8,
    /// Tests that depend on outside state (a database) always rerun.
    uncached: bool = false,
}{
    .{ .dep = "zag_http", .module = "zag-http" },
    .{ .dep = "zag_pg", .module = "zag-pg", .uncached = true },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run tests for every library");
    const docs_step = b.step("docs", "Generate API docs into zig-out/docs");
    var index: std.ArrayList(u8) = .empty;

    for (libraries) |lib| {
        const dep = b.dependency(lib.dep, .{ .target = target, .optimize = optimize });
        const module = dep.module(lib.module);
        try b.modules.put(b.graph.arena, lib.module, module);

        const tests = b.addTest(.{ .root_module = module });
        const run = b.addRunArtifact(tests);
        run.has_side_effects = lib.uncached;
        test_step.dependOn(&run.step);

        const obj = b.addObject(.{ .name = lib.module, .root_module = module });
        docs_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = obj.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = b.fmt("docs/{s}", .{lib.module}),
        }).step);
        try index.print(b.graph.arena, "<li><a href=\"{0s}/\">{0s}</a></li>\n", .{lib.module});
    }

    const page = b.addWriteFiles().add("index.html", b.fmt(index_html, .{index.items}));
    docs_step.dependOn(&b.addInstallFile(page, "docs/index.html").step);
}

const index_html =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><title>Zag API reference</title>
    \\<style>body{{font:16px/1.5 system-ui,sans-serif;max-width:40rem;margin:3rem auto;padding:0 1rem}}</style>
    \\</head><body><h1>Zag API reference</h1><ul>
    \\{s}</ul>
    \\<p><a href="https://github.com/thiefspin/zag">Source and guides on GitHub</a></p>
    \\</body></html>
    \\
;
