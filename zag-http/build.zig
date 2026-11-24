const std = @import("std");

const examples = [_][]const u8{ "hello", "json_api", "gateway", "client_tour" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zag = b.addModule("zag-http", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = zag });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const example_name = b.option([]const u8, "example", "Example for run-example (default: hello)") orelse "hello";
    const run_step = b.step("run-example", "Run an example: -Dexample=<name>");

    addBench(b, target, test_step);

    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zag-http", .module = zag }},
            }),
        });
        b.installArtifact(exe);
        if (std.mem.eql(u8, name, example_name)) {
            run_step.dependOn(&b.addRunArtifact(exe).step);
        }
    }
}

/// `zig build bench [-- --connections N --duration S --only NAME]`.
/// Always ReleaseFast: Debug numbers mostly measure safety checks.
fn addBench(b: *std.Build, target: std.Build.ResolvedTarget, test_step: *std.Build.Step) void {
    const zag = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const server = b.addExecutable(.{
        .name = "bench-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/server.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zag-http", .module = zag }},
        }),
    });
    const runner = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/run.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const run = b.addRunArtifact(runner);
    run.addArtifactArg(server);
    run.addPassthruArgs();
    b.step("bench", "Run benchmarks (ReleaseFast)").dependOn(&run.step);

    const load_tests = b.addTest(.{ .root_module = runner.root_module });
    test_step.dependOn(&b.addRunArtifact(load_tests).step);
}
