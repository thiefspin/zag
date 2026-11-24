//! A fully-read HTTP request. All slices live in the request arena.

const std = @import("std");
const Request = @This();

method: std.http.Method,
/// Raw (not percent-decoded) path, without the query string.
path: []const u8,
/// Raw query string without the leading `?`. Empty if there is none.
query: []const u8 = "",
headers: []const std.http.Header = &.{},
body: []const u8 = "",

/// Returns the first header named `name` (case-insensitive).
pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
    for (self.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Splits a request target like `/a/b?x=1` into path and query.
pub fn splitTarget(target: []const u8) struct { []const u8, []const u8 } {
    const index = std.mem.findScalar(u8, target, '?') orelse return .{ target, "" };
    return .{ target[0..index], target[index + 1 ..] };
}

test header {
    const request: Request = .{
        .method = .GET,
        .path = "/",
        .headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
    };
    try std.testing.expectEqualStrings("text/plain", request.header("content-type").?);
    try std.testing.expectEqual(null, request.header("accept"));
}

test splitTarget {
    const path, const query = splitTarget("/a/b?x=1&y=2");
    try std.testing.expectEqualStrings("/a/b", path);
    try std.testing.expectEqualStrings("x=1&y=2", query);

    const path2, const query2 = splitTarget("/plain");
    try std.testing.expectEqualStrings("/plain", path2);
    try std.testing.expectEqualStrings("", query2);
}
