//! Smallest Zag app. Run with `zig build run-example -Dexample=hello`,
//! then `curl localhost:3000/hello/zig`.

const std = @import("std");
const zag = @import("zag-http");

fn index() []const u8 {
    return "hello from zag\n";
}

fn hello(ctx: *zag.Context, path: zag.Path(struct { name: []const u8 })) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "hello, {s}!\n", .{path.value.name});
}

pub fn main(init: std.process.Init) !void {
    var router: zag.Router(void) = .init(init.gpa, {});
    defer router.deinit();

    try router.get("/", index);
    try router.get("/hello/:name", hello);
    try router.layer(zag.middleware.logger);

    try zag.serve(init.io, init.gpa, &router, .{ .port = 3000 });
}
