//! An HTTP response: status, headers and a fully-buffered body.

const std = @import("std");
const Response = @This();

status: std.http.Status = .ok,
headers: []const std.http.Header = &.{},
body: []const u8 = "",

const text_headers: []const std.http.Header = &.{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
};
const json_headers: []const std.http.Header = &.{
    .{ .name = "content-type", .value = "application/json" },
};

/// A response with no body. `return .empty(.created);`
pub fn empty(status: std.http.Status) Response {
    return .{ .status = status };
}

/// A `200 OK` plain-text response. `return .text("hello");`
pub fn text(body: []const u8) Response {
    return .{ .headers = text_headers, .body = body };
}

/// A `200 OK` JSON response. The body is allocated in `arena`.
pub fn json(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}!Response {
    const body = try std.json.Stringify.valueAlloc(arena, value, .{});
    return .{ .headers = json_headers, .body = body };
}

test json {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const res = try json(arena_state.allocator(), .{ .id = 1 });
    try std.testing.expectEqualStrings("{\"id\":1}", res.body);
    try std.testing.expectEqualStrings("application/json", res.headers[0].value);
}
