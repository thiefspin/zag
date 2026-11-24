//! Builds a flat struct from named string values. Shared by `Path(T)` and
//! `Query(T)`.

const std = @import("std");
const Param = @import("path.zig").Param;

pub const Error = error{ MissingParam, InvalidParam };

/// A list of decoded name/value pairs that can be looked up by name.
pub const Pairs = struct {
    items: []const Param,

    pub fn get(self: Pairs, name: []const u8) ?[]const u8 {
        for (self.items) |pair| {
            if (std.mem.eql(u8, pair.name, name)) return pair.value;
        }
        return null;
    }
};

/// Fills each field of `T` from `source.get(field_name)`. Missing fields use
/// their default value, then `null` if optional, else `error.MissingParam`.
pub fn parseStruct(comptime T: type, source: anytype) Error!T {
    comptime check(T);
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        @field(result, name) = try parseField(Field, attrs, source.get(name));
    }
    return result;
}

/// Compile error unless `T` is a flat struct of supported field types.
pub fn check(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") {
        @compileError("expected a struct, found '" ++ @typeName(T) ++ "'");
    }
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_types) |name, Field| {
        if (!isSupported(Field)) @compileError(
            "field '" ++ name ++ "' of '" ++ @typeName(T) ++ "' has unsupported type '" ++
                @typeName(Field) ++ "'; use integers, floats, bool, enums, []const u8, or optionals of these",
        );
    }
}

/// Parses `a=1&b=x%20y` into decoded pairs allocated in `arena`.
pub fn parseQuery(arena: std.mem.Allocator, query: []const u8) error{OutOfMemory}!Pairs {
    const count = std.mem.countScalar(u8, query, '&') + 1;
    const items = try arena.alloc(Param, count);
    var len: usize = 0;
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| : (len += 1) {
        const name, const value = splitPair(pair);
        items[len] = .{ .name = try decode(arena, name), .value = try decode(arena, value) };
    }
    return .{ .items = items[0..len] };
}

fn parseField(
    comptime Field: type,
    comptime attrs: std.lang.Type.Struct.FieldAttributes,
    raw: ?[]const u8,
) Error!Field {
    if (raw) |text| return parseValue(Field, text);
    if (comptime attrs.defaultValue(Field)) |default| return default;
    if (@typeInfo(Field) == .optional) return null;
    return error.MissingParam;
}

fn parseValue(comptime T: type, text: []const u8) Error!T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10) catch error.InvalidParam,
        .float => std.fmt.parseFloat(T, text) catch error.InvalidParam,
        .bool => parseBool(text),
        .@"enum" => std.meta.stringToEnum(T, text) orelse error.InvalidParam,
        .optional => |optional| try parseValue(optional.child, text),
        .pointer => text,
        else => comptime unreachable,
    };
}

fn parseBool(text: []const u8) Error!bool {
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) return true;
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) return false;
    return error.InvalidParam;
}

fn isSupported(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        .optional => |optional| @typeInfo(optional.child) != .optional and isSupported(optional.child),
        else => T == []const u8,
    };
}

fn splitPair(pair: []const u8) struct { []const u8, []const u8 } {
    const index = std.mem.findScalar(u8, pair, '=') orelse return .{ pair, "" };
    return .{ pair[0..index], pair[index + 1 ..] };
}

/// Query strings encode spaces as `+`, then percent-encode the rest.
fn decode(arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    const copy = try arena.dupe(u8, raw);
    std.mem.replaceScalar(u8, copy, '+', ' ');
    return std.Uri.percentDecodeInPlace(copy);
}

const testing = std.testing;

test parseStruct {
    const Color = enum { red, blue };
    const T = struct {
        id: u32,
        name: []const u8,
        color: Color,
        active: bool = true,
        limit: ?u8,
    };
    const pairs: Pairs = .{ .items = &.{
        .{ .name = "id", .value = "42" },
        .{ .name = "name", .value = "ziggy" },
        .{ .name = "color", .value = "blue" },
    } };
    const value = try parseStruct(T, pairs);
    try testing.expectEqual(42, value.id);
    try testing.expectEqualStrings("ziggy", value.name);
    try testing.expectEqual(.blue, value.color);
    try testing.expect(value.active);
    try testing.expectEqual(null, value.limit);
}

test "parseStruct errors" {
    const T = struct { id: u32 };
    const missing: Pairs = .{ .items = &.{} };
    try testing.expectError(error.MissingParam, parseStruct(T, missing));
    const invalid: Pairs = .{ .items = &.{.{ .name = "id", .value = "abc" }} };
    try testing.expectError(error.InvalidParam, parseStruct(T, invalid));
}

test parseQuery {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const pairs = try parseQuery(arena_state.allocator(), "q=hello+world&page=2&flag&x=%41");
    try testing.expectEqualStrings("hello world", pairs.get("q").?);
    try testing.expectEqualStrings("2", pairs.get("page").?);
    try testing.expectEqualStrings("", pairs.get("flag").?);
    try testing.expectEqualStrings("A", pairs.get("x").?);
    try testing.expectEqual(null, pairs.get("missing"));
}
