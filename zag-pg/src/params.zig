//! Encodes query arguments (a tuple of Zig values) as text parameters.
//! `null` means SQL NULL.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Wraps a value that is sent as, or decoded from, a `json`/`jsonb` column.
pub fn Json(comptime T: type) type {
    return struct {
        value: T,
        /// Marks this type for `params` and `rows`.
        pub const PgJson = T;
    };
}

pub fn isJson(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "PgJson");
}

/// Encodes every element of `args` (a tuple) into `arena`.
pub fn encode(arena: Allocator, args: anytype) error{OutOfMemory}![]const ?[]const u8 {
    const Args = @TypeOf(args);
    const info = @typeInfo(Args);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("query arguments must be a tuple, e.g. .{ id, name }; found '" ++ @typeName(Args) ++ "'");
    }
    const out = try arena.alloc(?[]const u8, info.@"struct".field_types.len);
    inline for (info.@"struct".field_types, 0..) |Arg, i| {
        out[i] = try encodeValue(Arg, arena, args[i], i + 1);
    }
    return out;
}

fn encodeValue(comptime T: type, arena: Allocator, value: T, comptime position: usize) error{OutOfMemory}!?[]const u8 {
    if (comptime isString(T)) return value;
    if (comptime isJson(T)) return try std.json.Stringify.valueAlloc(arena, value.value, .{});
    return switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => try std.fmt.allocPrint(arena, "{d}", .{value}),
        .bool => if (value) "t" else "f",
        .@"enum", .enum_literal => @tagName(value),
        .null => null,
        .optional => |optional| if (value) |inner| try encodeValue(optional.child, arena, inner, position) else null,
        else => @compileError(std.fmt.comptimePrint(
            "query argument ${d} has unsupported type '{s}'; use integers, floats, bool, strings, enums, optionals, or pg.Json(T)",
            .{ position, @typeName(T) },
        )),
    };
}

pub fn isString(comptime T: type) bool {
    if (T == []const u8 or T == []u8) return true;
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one) return false;
    const child = @typeInfo(info.pointer.child);
    return child == .array and child.array.child == u8;
}

const testing = std.testing;

test encode {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const Color = enum { red, blue };
    const missing: ?i32 = null;
    const present: ?i32 = 5;
    const name: []const u8 = "ada";

    const encoded = try encode(arena_state.allocator(), .{
        42,                                             @as(i64, -7), 1.5,        true,    false,
        "literal",                                      name,         Color.blue, missing, present,
        Json(struct { a: u8 }){ .value = .{ .a = 1 } },
    });
    const expected = [_]?[]const u8{ "42", "-7", "1.5", "t", "f", "literal", "ada", "blue", null, "5", "{\"a\":1}" };
    try testing.expectEqual(expected.len, encoded.len);
    for (expected, encoded) |want, got| {
        if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expectEqual(null, got);
    }
}
