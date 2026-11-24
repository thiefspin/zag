//! Postgres `ErrorResponse` → Zig errors, plus the full details for logging.

const std = @import("std");
const Parser = @import("protocol.zig").Parser;

/// Errors from a statement the server rejected. Chosen so a zag-http handler
/// can return them directly (409, 422, 503, 504, 500).
pub const QueryError = error{
    /// 23505
    UniqueViolation,
    /// 23503
    ForeignKeyViolation,
    /// 23502 not-null, 23514 check, 23P01 exclusion
    ConstraintViolation,
    /// 40001 serialization failure, 40P01 deadlock. Safe to retry the transaction.
    SerializationFailure,
    /// 57014, including `statement_timeout`.
    QueryTimeout,
    /// Any other server error.
    QueryFailed,
};

/// What the server said, from an `ErrorResponse`. Strings point into the
/// memory the response was parsed into.
pub const Diagnostics = struct {
    severity: []const u8 = "",
    /// SQLSTATE, e.g. "23505".
    code: []const u8 = "",
    message: []const u8 = "",
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
    constraint: ?[]const u8 = null,

    /// Parses `ErrorResponse`/`NoticeResponse` fields: (type byte, cstring)* 0.
    pub fn parse(body: []const u8) error{ProtocolViolation}!Diagnostics {
        var d: Diagnostics = .{};
        var p: Parser = .{ .bytes = body };
        while (true) {
            const field = try p.byte();
            if (field == 0) return d;
            const value = try p.cstring();
            switch (field) {
                'V' => d.severity = value,
                'S' => if (d.severity.len == 0) {
                    d.severity = value;
                },
                'C' => d.code = value,
                'M' => d.message = value,
                'D' => d.detail = value,
                'H' => d.hint = value,
                's' => d.schema = value,
                't' => d.table = value,
                'c' => d.column = value,
                'n' => d.constraint = value,
                else => {},
            }
        }
    }

    pub fn toError(self: Diagnostics) QueryError {
        return fromSqlState(self.code);
    }
};

pub fn fromSqlState(code: []const u8) QueryError {
    const map = std.StaticStringMap(QueryError).initComptime(.{
        .{ "23505", error.UniqueViolation },
        .{ "23503", error.ForeignKeyViolation },
        .{ "23502", error.ConstraintViolation },
        .{ "23514", error.ConstraintViolation },
        .{ "23P01", error.ConstraintViolation },
        .{ "40001", error.SerializationFailure },
        .{ "40P01", error.SerializationFailure },
        .{ "57014", error.QueryTimeout },
    });
    return map.get(code) orelse error.QueryFailed;
}

const testing = std.testing;

test "parse and map" {
    const body = "SERROR\x00VERROR\x00C23505\x00Mduplicate key value\x00Dkey (email)=(a@b.c) exists\x00nusers_email_key\x00\x00";
    const d = try Diagnostics.parse(body);
    try testing.expectEqualStrings("ERROR", d.severity);
    try testing.expectEqualStrings("duplicate key value", d.message);
    try testing.expectEqualStrings("users_email_key", d.constraint.?);
    try testing.expectEqual(error.UniqueViolation, d.toError());
    try testing.expectEqual(error.QueryFailed, fromSqlState("42601"));
    try testing.expectError(error.ProtocolViolation, Diagnostics.parse("Cunterminated"));
}
