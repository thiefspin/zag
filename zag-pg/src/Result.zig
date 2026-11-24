//! Walks the responses to one query up to ReadyForQuery, yielding rows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Conn = @import("Conn.zig");
const rows = @import("rows.zig");

const Result = @This();
const Error = Conn.Error;

conn: *Conn,
arena: Allocator,
columns: []rows.Column = &.{},
values: []?[]const u8 = &.{},
affected: u64 = 0,
failure: ?Error = null,
done: bool = false,

/// The next row's values (valid until the next call), or null when done.
pub fn next(self: *Result) Error!?[]const ?[]const u8 {
    while (!self.done) {
        const message = try self.conn.read();
        switch (message.tag) {
            '1', '2', 'n', 'I' => {}, // ParseComplete, BindComplete, NoData, EmptyQuery
            'T' => try self.describe(message.body),
            'D' => {
                try rows.splitRow(message.body, self.values);
                return self.values;
            },
            'C' => self.affected = affectedRows(message.body),
            'E' => {
                self.failure = self.conn.serverError(message.body);
                if (self.conn.broken) return self.failure.?;
            },
            'Z' => {
                self.done = true;
                try self.conn.setReady(message);
            },
            else => return self.conn.protocolViolation(message.tag),
        }
    }
    if (self.failure) |err| return err;
    return null;
}

fn describe(self: *Result, body: []const u8) Error!void {
    self.columns = try rows.parseColumns(self.arena, body);
    self.values = try self.arena.alloc(?[]const u8, self.columns.len);
}

/// Reads any remaining responses so the connection is ready for reuse.
pub fn finish(self: *Result) void {
    while (!self.done and !self.conn.broken) {
        _ = self.next() catch |err| switch (err) {
            error.ConnectionFailed, error.ProtocolViolation, error.Canceled, error.OutOfMemory => return,
            else => {},
        };
    }
}

/// "INSERT 0 3" → 3, "UPDATE 2" → 2, "CREATE TABLE" → 0.
fn affectedRows(tag_body: []const u8) u64 {
    const tag = std.mem.trimEnd(u8, tag_body, "\x00");
    const space = std.mem.findScalarLast(u8, tag, ' ') orelse return 0;
    return std.fmt.parseInt(u64, tag[space + 1 ..], 10) catch 0;
}

test affectedRows {
    try std.testing.expectEqual(3, affectedRows("INSERT 0 3\x00"));
    try std.testing.expectEqual(2, affectedRows("UPDATE 2\x00"));
    try std.testing.expectEqual(0, affectedRows("CREATE TABLE\x00"));
}
