#!/usr/bin/env bash
# Packages the repo the way `zig fetch` sees it and builds a fresh project
# that depends on it. Catches files missing from `.paths` in build.zig.zon
# and modules that don't resolve from the root package.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Tracked and untracked-but-not-ignored files, so this also works before a commit.
(cd "$root" && git ls-files -co --exclude-standard -z |
    COPYFILE_DISABLE=1 tar --null -T - -czf "$work/zag.tar.gz" --transform 's,^,zag/,' 2>/dev/null ||
    git ls-files -co --exclude-standard -z | COPYFILE_DISABLE=1 tar --null -T - -czf "$work/zag.tar.gz" -s ',^,zag/,')

mkdir -p "$work/consumer/src"
cd "$work/consumer"
cat > build.zig.zon <<'ZON'
.{
    .name = .consumer,
    .version = "0.0.0",
    .minimum_zig_version = "0.17.1",
    .dependencies = .{},
    .paths = .{""},
}
ZON
cat > build.zig <<'ZIG'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const zag = b.dependency("zag", .{ .target = target });
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-http", .module = zag.module("zag-http") },
            .{ .name = "zag-pg", .module = zag.module("zag-pg") },
        },
    }) });
    b.installArtifact(exe);
}
ZIG
cat > src/main.zig <<'ZIG'
const std = @import("std");
const http = @import("zag-http");
const pg = @import("zag-pg");

fn hello() []const u8 {
    return "hi";
}

pub fn main(init: std.process.Init) !void {
    var router: http.Router(void) = .init(init.gpa, {});
    defer router.deinit();
    try router.get("/", hello);
    const config = try pg.Config.parseUrl(init.arena.allocator(), "postgres://zag@localhost/zag");
    std.debug.print("ok: {s}\n", .{config.host});
}
ZIG

# Zig asks for a fingerprint on first build and suggests one.
fingerprint=$(zig build 2>&1 | grep -o '0x[0-9a-f]\{8,\}' | head -1 || true)
sed -i.bak "s/    .version = \"0.0.0\",/    .version = \"0.0.0\",\n    .fingerprint = $fingerprint,/" build.zig.zon && rm build.zig.zon.bak

zig fetch --save=zag "$work/zag.tar.gz"
zig build
./zig-out/bin/consumer
echo "package check passed"
