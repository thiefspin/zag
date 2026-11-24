//! A transaction on a borrowed connection.
//!
//!   var tx = try pool.begin();
//!   defer tx.deinit(); // rolls back unless committed
//!   _ = try tx.exec(...);
//!   try tx.commit();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Conn = @import("Conn.zig");
const Pool = @import("Pool.zig");

const Tx = @This();

pub const Error = Conn.Error || error{
    /// A statement in this transaction failed, so it can only roll back.
    TransactionAborted,
};

pool: *Pool,
conn: *Conn,
finished: bool = false,

pub fn commit(self: *Tx) Error!void {
    std.debug.assert(!self.finished);
    // In a failed transaction Postgres answers COMMIT with ROLLBACK, not an error.
    if (self.conn.tx_status == 'E') return error.TransactionAborted;
    try self.conn.execScript("commit");
    self.finished = true;
}

pub fn rollback(self: *Tx) Error!void {
    std.debug.assert(!self.finished);
    self.finished = true;
    try self.conn.execScript("rollback");
}

/// Rolls back if neither `commit` nor `rollback` succeeded, then returns the
/// connection to the pool.
pub fn deinit(self: *Tx) void {
    if (!self.finished) self.conn.execScript("rollback") catch {};
    self.pool.release(self.conn);
}

pub fn query(self: *Tx, comptime T: type, arena: Allocator, sql: []const u8, args: anytype) Error![]T {
    return self.conn.query(T, arena, sql, args);
}

pub fn queryOne(self: *Tx, comptime T: type, arena: Allocator, sql: []const u8, args: anytype) Error!?T {
    return self.conn.queryOne(T, arena, sql, args);
}

pub fn get(self: *Tx, comptime T: type, arena: Allocator, sql: []const u8, args: anytype) Error!T {
    return self.conn.get(T, arena, sql, args);
}

pub fn exec(self: *Tx, sql: []const u8, args: anytype) Error!u64 {
    return self.conn.exec(sql, args);
}
