//! Route pattern validation and matching. Pure functions: no I/O, no allocation
//! except `decodeParams`, which writes into a caller-provided arena.

const std = @import("std");
const mem = std.mem;

/// Maximum number of `:name` / `*name` captures in one pattern.
pub const max_params = 16;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// Captured path parameters for one request.
pub const Params = struct {
    items: [max_params]Param = undefined,
    len: usize = 0,

    /// Returns the value captured for `name`, or null if there is none.
    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        for (self.slice()) |param| {
            if (mem.eql(u8, param.name, name)) return param.value;
        }
        return null;
    }

    pub fn slice(self: *const Params) []const Param {
        return self.items[0..self.len];
    }

    fn append(self: *Params, param: Param) void {
        self.items[self.len] = param;
        self.len += 1;
    }
};

/// Checks a route pattern at comptime. Bad patterns are compile errors.
pub fn validate(comptime pattern: []const u8) void {
    comptime {
        if (pattern.len == 0 or pattern[0] != '/') {
            @compileError("route pattern '" ++ pattern ++ "' must start with '/'");
        }
        var count = 0;
        var it = mem.tokenizeScalar(u8, pattern, '/');
        while (it.next()) |segment| {
            if (!isCapture(segment)) continue;
            count += 1;
            if (segment.len == 1) {
                @compileError("route pattern '" ++ pattern ++ "' has a capture with no name; write ':id' or '*path'");
            }
            if (segment[0] == '*' and it.peek() != null) {
                @compileError("route pattern '" ++ pattern ++ "': wildcard '" ++ segment ++ "' must be the last segment");
            }
        }
        if (count > max_params) {
            @compileError(std.fmt.comptimePrint("route pattern '{s}' has more than {d} captures", .{ pattern, max_params }));
        }
    }
}

/// True if the pattern has no captures.
pub fn isStatic(pattern: []const u8) bool {
    return mem.findAny(u8, pattern, ":*") == null;
}

/// Matches `path` against `pattern`, filling `params` on success.
/// Empty segments are ignored, so `/users/` matches `/users`.
pub fn match(pattern: []const u8, path: []const u8, params: *Params) bool {
    params.len = 0;
    var pattern_it = mem.tokenizeScalar(u8, pattern, '/');
    var path_it = mem.tokenizeScalar(u8, path, '/');

    while (pattern_it.next()) |segment| {
        if (segment[0] == '*') {
            params.append(.{ .name = segment[1..], .value = path_it.rest() });
            return true;
        }
        const value = path_it.next() orelse return false;
        if (segment[0] == ':') {
            params.append(.{ .name = segment[1..], .value = value });
        } else if (!mem.eql(u8, segment, value)) {
            return false;
        }
    }
    return path_it.next() == null;
}

pub const DecodeError = error{ InvalidParam, OutOfMemory };

/// Percent-decodes every captured value into `arena`. Rejects values that
/// contain a `..` segment, so wildcards can't escape a directory.
pub fn decodeParams(arena: mem.Allocator, params: *Params) DecodeError!void {
    for (params.items[0..params.len]) |*param| {
        const copy = try arena.dupe(u8, param.value);
        const decoded = std.Uri.percentDecodeInPlace(copy);
        if (hasDotDotSegment(decoded)) return error.InvalidParam;
        param.value = decoded;
    }
}

fn isCapture(segment: []const u8) bool {
    return segment[0] == ':' or segment[0] == '*';
}

fn hasDotDotSegment(value: []const u8) bool {
    var it = mem.tokenizeScalar(u8, value, '/');
    while (it.next()) |segment| {
        if (mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

const testing = std.testing;

test "static match" {
    var params: Params = .{};
    try testing.expect(match("/", "/", &params));
    try testing.expect(match("/users", "/users", &params));
    try testing.expect(match("/users", "/users/", &params));
    try testing.expect(!match("/users", "/users/1", &params));
    try testing.expect(!match("/users", "/", &params));
}

test "named params" {
    var params: Params = .{};
    try testing.expect(match("/users/:id/posts/:post", "/users/7/posts/abc", &params));
    try testing.expectEqualStrings("7", params.get("id").?);
    try testing.expectEqualStrings("abc", params.get("post").?);
    try testing.expectEqual(null, params.get("missing"));
    try testing.expect(!match("/users/:id", "/users", &params));
}

test "wildcard captures the rest" {
    var params: Params = .{};
    try testing.expect(match("/static/*file", "/static/css/site.css", &params));
    try testing.expectEqualStrings("css/site.css", params.get("file").?);
    try testing.expect(match("/static/*file", "/static", &params));
    try testing.expectEqualStrings("", params.get("file").?);
}

test "isStatic" {
    try testing.expect(isStatic("/users"));
    try testing.expect(!isStatic("/users/:id"));
    try testing.expect(!isStatic("/files/*rest"));
}

test "decodeParams decodes and rejects dot-dot" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var params: Params = .{};
    try testing.expect(match("/x/*rest", "/x/a%20b/c", &params));
    try decodeParams(arena, &params);
    try testing.expectEqualStrings("a b/c", params.get("rest").?);

    try testing.expect(match("/x/*rest", "/x/a/%2e%2e/etc", &params));
    try testing.expectError(error.InvalidParam, decodeParams(arena, &params));
}

test "fuzz match never crashes" {
    try testing.fuzz({}, fuzzMatch, .{});
}

fn fuzzMatch(_: void, smith: *testing.Smith) !void {
    var buffer: [255]u8 = undefined;
    const len = smith.valueRangeAtMost(u8, 0, buffer.len);
    smith.bytes(buffer[0..len]);
    var params: Params = .{};
    _ = match("/a/:b/c/*d", buffer[0..len], &params);
}
