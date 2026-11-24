const std = @import("std");

const examples = [_][]const u8{"todos"};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pg = b.addModule("zag-pg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = pg });
    const run_tests = b.addRunArtifact(tests);
    // Integration tests talk to Postgres (ZAG_PG_TEST_URL, see `make pg-up`)
    // and skip when it isn't running, so never cache their result.
    run_tests.has_side_effects = true;
    b.step("test", "Run all tests").dependOn(&run_tests.step);

    const zag_http = b.dependency("zag_http", .{ .target = target, .optimize = optimize }).module("zag-http");
    const example_name = b.option([]const u8, "example", "Example for run-example (default: todos)") orelse "todos";
    const run_step = b.step("run-example", "Run an example: -Dexample=<name>");
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zag-pg", .module = pg },
                    .{ .name = "zag-http", .module = zag_http },
                },
            }),
        });
        b.installArtifact(exe);
        if (std.mem.eql(u8, name, example_name)) run_step.dependOn(&b.addRunArtifact(exe).step);
    }
}
