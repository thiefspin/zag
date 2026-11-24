//! URL building and `name=value` encoding for the client. Pure functions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Param = @import("../path.zig").Param;

pub const BuildError = error{ InvalidRequest, OutOfMemory };

/// Joins `url` to `base` (unless `url` is absolute) and appends `query`,
/// percent-encoded. The result is allocated in `arena`.
pub fn build(arena: Allocator, base: ?[]const u8, url: []const u8, query: []const Param) BuildError![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeJoined(w, base, url) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.InvalidRequest => error.InvalidRequest,
    };
    if (query.len > 0) {
        const separator: u8 = if (std.mem.findScalar(u8, url, '?') == null) '?' else '&';
        w.writeByte(separator) catch return error.OutOfMemory;
        writePairs(w, query) catch return error.OutOfMemory;
    }
    return out.written();
}

/// Encodes `params` as `a=1&b=x%20y` (also the form-urlencoded body format).
pub fn encodePairs(arena: Allocator, params: []const Param) error{OutOfMemory}![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    writePairs(&out.writer, params) catch return error.OutOfMemory;
    return out.written();
}

pub fn writePairs(w: *Io.Writer, params: []const Param) Io.Writer.Error!void {
    for (params, 0..) |param, i| {
        if (i > 0) try w.writeByte('&');
        try std.Uri.Component.percentEncode(w, param.name, isUnreserved);
        try w.writeByte('=');
        try std.Uri.Component.percentEncode(w, param.value, isUnreserved);
    }
}

fn writeJoined(w: *Io.Writer, base: ?[]const u8, url: []const u8) (Io.Writer.Error || error{InvalidRequest})!void {
    if (isAbsolute(url)) return w.writeAll(url);
    const prefix = base orelse return error.InvalidRequest;
    try w.writeAll(std.mem.trimEnd(u8, prefix, "/"));
    try w.writeByte('/');
    try w.writeAll(std.mem.trimStart(u8, url, "/"));
}

fn isAbsolute(url: []const u8) bool {
    return std.mem.find(u8, url, "://") != null;
}

/// RFC 3986 unreserved characters; everything else is percent-encoded.
fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

const testing = std.testing;

test build {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("http://a.test/v1/users", try build(arena, "http://a.test/v1/", "/users", &.{}));
    try testing.expectEqualStrings("http://a.test/users", try build(arena, "http://a.test", "users", &.{}));
    try testing.expectEqualStrings("https://b.test/x", try build(arena, "http://a.test", "https://b.test/x", &.{}));
    try testing.expectEqualStrings(
        "http://a.test/s?q=hello%20world&page=2",
        try build(arena, "http://a.test", "/s", &.{ .{ .name = "q", .value = "hello world" }, .{ .name = "page", .value = "2" } }),
    );
    try testing.expectEqualStrings("http://a.test/s?x=1&y=%26", try build(arena, null, "http://a.test/s?x=1", &.{.{ .name = "y", .value = "&" }}));
    try testing.expectError(error.InvalidRequest, build(arena, null, "/relative", &.{}));
}
