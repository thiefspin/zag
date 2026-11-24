//! Decodes result rows (text format) into Zig structs, matching fields to
//! columns by name. The column → field mapping is built once per query.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("protocol.zig").Parser;
const params = @import("params.zig");

pub const DecodeError = error{
    /// A field of the result struct has no column and no default value.
    ColumnMissing,
    /// `NULL` in a column whose field is not optional.
    UnexpectedNull,
    /// The column's text could not be parsed as the field's type.
    InvalidValue,
    OutOfMemory,
    ProtocolViolation,
};

pub const bytea_oid = 17;

pub const Column = struct { name: []const u8, type_oid: u32 };

/// Parses a `RowDescription` body into `arena`.
pub fn parseColumns(arena: Allocator, body: []const u8) (Allocator.Error || error{ProtocolViolation})![]Column {
    var p: Parser = .{ .bytes = body };
    const count: usize = @intCast(@max(0, try p.int16()));
    const columns = try arena.alloc(Column, count);
    for (columns) |*column| {
        const name = try arena.dupe(u8, try p.cstring());
        _ = try p.take(4 + 2); // table oid, attribute number
        const type_oid: u32 = @bitCast(try p.int32());
        _ = try p.take(2 + 4 + 2); // type size, type modifier, format
        column.* = .{ .name = name, .type_oid = type_oid };
    }
    return columns;
}

/// For each field of `T`, the index of its column, or null to use the
/// field's default value.
pub fn Mapping(comptime T: type) type {
    return [@typeInfo(T).@"struct".field_names.len]?usize;
}

pub fn mapColumns(comptime T: type, columns: []const Column) DecodeError!Mapping(T) {
    comptime check(T);
    const info = @typeInfo(T).@"struct";
    var mapping: Mapping(T) = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, i| {
        mapping[i] = findColumn(columns, name);
        if (mapping[i] == null and comptime attrs.defaultValue(Field) == null) {
            std.log.scoped(.zag_pg).debug("no column named '{s}' for {s}", .{ name, @typeName(T) });
            return error.ColumnMissing;
        }
    }
    return mapping;
}

fn findColumn(columns: []const Column, name: []const u8) ?usize {
    for (columns, 0..) |column, i| {
        if (std.mem.eql(u8, column.name, name)) return i;
    }
    return null;
}

/// Splits a `DataRow` body into one slice per column (null = SQL NULL).
pub fn splitRow(body: []const u8, values: []?[]const u8) error{ProtocolViolation}!void {
    var p: Parser = .{ .bytes = body };
    const count: usize = @intCast(@max(0, try p.int16()));
    if (count != values.len) return error.ProtocolViolation;
    for (values) |*value| {
        const len = try p.int32();
        value.* = if (len < 0) null else try p.take(@intCast(len));
    }
}

/// Builds a `T` from one row's values. Strings are copied into `arena`.
pub fn decode(
    comptime T: type,
    arena: Allocator,
    columns: []const Column,
    mapping: Mapping(T),
    values: []const ?[]const u8,
) DecodeError!T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, i| {
        @field(result, name) = if (mapping[i]) |column|
            try decodeValue(Field, arena, values[column], columns[column].type_oid)
        else if (comptime attrs.defaultValue(Field)) |default|
            default
        else
            unreachable; // `mapColumns` only leaves fields with defaults unmapped
    }
    return result;
}

fn decodeValue(comptime F: type, arena: Allocator, text: ?[]const u8, oid: u32) DecodeError!F {
    if (@typeInfo(F) == .optional) {
        const t = text orelse return null;
        return try decodeText(@typeInfo(F).optional.child, arena, t, oid);
    }
    return decodeText(F, arena, text orelse return error.UnexpectedNull, oid);
}

fn decodeText(comptime F: type, arena: Allocator, text: []const u8, oid: u32) DecodeError!F {
    if (F == []const u8) return if (oid == bytea_oid) decodeBytea(arena, text) else arena.dupe(u8, text);
    if (comptime params.isJson(F)) return .{ .value = try decodeJson(F.PgJson, arena, text) };
    return switch (@typeInfo(F)) {
        .int => std.fmt.parseInt(F, text, 10) catch error.InvalidValue,
        .float => std.fmt.parseFloat(F, text) catch error.InvalidValue,
        .bool => if (std.mem.eql(u8, text, "t")) true else if (std.mem.eql(u8, text, "f")) false else error.InvalidValue,
        .@"enum" => std.meta.stringToEnum(F, text) orelse error.InvalidValue,
        else => comptime unreachable, // rejected by `check`
    };
}

fn decodeJson(comptime T: type, arena: Allocator, text: []const u8) DecodeError!T {
    return std.json.parseFromSliceLeaky(T, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidValue,
    };
}

/// `\x0a1b…` → bytes.
fn decodeBytea(arena: Allocator, text: []const u8) DecodeError![]const u8 {
    if (!std.mem.startsWith(u8, text, "\\x") or text.len % 2 != 0) return error.InvalidValue;
    const out = try arena.alloc(u8, (text.len - 2) / 2);
    return std.fmt.hexToBytes(out, text[2..]) catch error.InvalidValue;
}

/// Compile error unless `T` is a struct of supported field types.
pub fn check(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") @compileError("rows decode into structs; found '" ++ @typeName(T) ++ "'");
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_types) |name, Field| {
        if (!isSupported(Field)) @compileError(
            "field '" ++ name ++ "' of '" ++ @typeName(T) ++ "' has unsupported type '" ++ @typeName(Field) ++
                "'; use integers, floats, bool, enums, []const u8, pg.Json(T), or optionals of these",
        );
    }
}

fn isSupported(comptime F: type) bool {
    if (F == []const u8 or params.isJson(F)) return true;
    return switch (@typeInfo(F)) {
        .int, .float, .bool, .@"enum" => true,
        .optional => |o| @typeInfo(o.child) != .optional and isSupported(o.child),
        else => false,
    };
}

const testing = std.testing;

test "decode by column name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Role = enum { admin, member };
    const User = struct {
        id: i64,
        name: []const u8,
        email: ?[]const u8,
        role: Role,
        active: bool,
        score: f64 = 0,
        avatar: []const u8,
        meta: params.Json(struct { theme: []const u8 }),
    };
    const columns = [_]Column{
        .{ .name = "name", .type_oid = 25 },
        .{ .name = "id", .type_oid = 20 },
        .{ .name = "unused", .type_oid = 25 },
        .{ .name = "email", .type_oid = 25 },
        .{ .name = "role", .type_oid = 25 },
        .{ .name = "active", .type_oid = 16 },
        .{ .name = "avatar", .type_oid = bytea_oid },
        .{ .name = "meta", .type_oid = 3802 },
    };
    const mapping = try mapColumns(User, &columns);
    const values = [_]?[]const u8{ "ada", "42", "x", null, "admin", "t", "\\x7a6167", "{\"theme\":\"dark\",\"x\":1}" };
    const user = try decode(User, arena, &columns, mapping, &values);

    try testing.expectEqual(42, user.id);
    try testing.expectEqualStrings("ada", user.name);
    try testing.expectEqual(null, user.email);
    try testing.expectEqual(.admin, user.role);
    try testing.expect(user.active);
    try testing.expectEqual(0, user.score);
    try testing.expectEqualStrings("zag", user.avatar);
    try testing.expectEqualStrings("dark", user.meta.value.theme);

    var bad = values;
    bad[0] = null;
    try testing.expectError(error.UnexpectedNull, decode(User, arena, &columns, mapping, &bad));
    bad = values;
    bad[1] = "forty-two";
    try testing.expectError(error.InvalidValue, decode(User, arena, &columns, mapping, &bad));
    try testing.expectError(error.ColumnMissing, mapColumns(User, columns[0..3]));
}

test "parseColumns and splitRow" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    // Two columns: "id" int8 (20) and "name" text (25).
    const description = "\x00\x02" ++
        "id\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00" ++ "\x00\x00\x00\x14" ++ "\x00\x08" ++ "\xff\xff\xff\xff" ++ "\x00\x00" ++
        "name\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00" ++ "\x00\x00\x00\x19" ++ "\xff\xff" ++ "\xff\xff\xff\xff" ++ "\x00\x00";
    const columns = try parseColumns(arena_state.allocator(), description);
    try testing.expectEqual(2, columns.len);
    try testing.expectEqualStrings("name", columns[1].name);
    try testing.expectEqual(25, columns[1].type_oid);

    var values: [2]?[]const u8 = undefined;
    try splitRow("\x00\x02" ++ "\x00\x00\x00\x017" ++ "\xff\xff\xff\xff", &values);
    try testing.expectEqualStrings("7", values[0].?);
    try testing.expectEqual(null, values[1]);
    try testing.expectError(error.ProtocolViolation, splitRow("\x00\x02\x00\x00\x00\x09ab", &values));
}
