//! A threadsafe pool of connections. One per app; every query borrows a
//! connection and gives it back. Connections open lazily up to
//! `max_connections`, and broken ones are replaced.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const Conn = @import("Conn.zig");
const Tx = @import("Tx.zig");

const Pool = @This();

pub const Error = Conn.Error || error{
    /// No connection became free within `acquire_timeout`.
    PoolTimeout,
};

pub const Options = struct {
    /// `postgres://…`; used when `config` is null.
    url: ?[]const u8 = null,
    config: ?Config = null,
    max_connections: u16 = 10,
    /// How long `acquire` waits for a free connection.
    acquire_timeout: Io.Duration = .fromSeconds(5),
};

io: Io,
gpa: Allocator,
/// Owns the strings in `config`.
arena: std.heap.ArenaAllocator,
config: Config,
options: Options,
mutex: Io.Mutex = .init,
available: Io.Condition = .init,
idle: std.ArrayList(*Conn) = .empty,
/// Open connections plus connections being opened.
open_count: u16 = 0,

/// Does not connect; the first query does.
pub fn init(io: Io, gpa: Allocator, options: Options) !Pool {
    if (options.max_connections == 0) return error.InvalidConfig;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const config = options.config orelse
        try Config.parseUrl(arena.allocator(), options.url orelse return error.InvalidConfig);

    var idle: std.ArrayList(*Conn) = .empty;
    try idle.ensureTotalCapacity(gpa, options.max_connections);
    return .{ .io = io, .gpa = gpa, .arena = arena, .config = config, .options = options, .idle = idle };
}

/// Closes idle connections. Every borrowed connection must be released first.
pub fn deinit(self: *Pool) void {
    std.debug.assert(self.idle.items.len == self.open_count);
    for (self.idle.items) |conn| conn.close();
    self.idle.deinit(self.gpa);
    self.arena.deinit();
}

/// Borrows a connection; give it back with `release`. Prefer the query
/// functions below, which do this for you.
pub fn acquire(self: *Pool) Error!*Conn {
    const deadline: Io.Clock.Timestamp = .fromNow(self.io, .{ .raw = self.options.acquire_timeout, .clock = .awake });
    if (try self.reserve(deadline)) |conn| return conn;
    return Conn.open(self.io, self.gpa, self.config) catch |err| {
        self.forget();
        return err;
    };
}

/// An idle connection, or null after reserving a slot for a new one.
fn reserve(self: *Pool, deadline: Io.Clock.Timestamp) Error!?*Conn {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    while (true) {
        if (self.idle.pop()) |conn| return conn;
        if (self.open_count < self.options.max_connections) {
            self.open_count += 1;
            return null;
        }
        self.available.waitTimeout(self.io, &self.mutex, .{ .deadline = deadline }) catch |err| return switch (err) {
            error.Timeout => error.PoolTimeout,
            error.Canceled => error.Canceled,
        };
    }
}

/// Gives a connection back. Rolls back an unfinished transaction; closes it
/// if it is broken.
pub fn release(self: *Pool, conn: *Conn) void {
    if (!conn.broken and conn.tx_status != 'I') conn.execScript("rollback") catch {};
    if (conn.broken) {
        conn.close();
        return self.forget();
    }
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.idle.appendAssumeCapacity(conn);
    self.available.signal(self.io);
}

/// Frees the slot of a connection that was closed or never opened.
fn forget(self: *Pool) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.open_count -= 1;
    self.available.signal(self.io);
}

/// Starts a transaction on a borrowed connection. See `Tx`.
pub fn begin(self: *Pool) Error!Tx {
    const conn = try self.acquire();
    errdefer self.release(conn);
    try conn.execScript("begin");
    return .{ .pool = self, .conn = conn };
}

// The query functions of `Conn`, each on a borrowed connection.

pub fn query(self: *Pool, comptime T: type, arena: Allocator, sql: []const u8, args: anytype) Error![]T {
    const conn = try self.acquire();
    defer self.release(conn);
    return conn.query(T, arena, sql, args);
}

pub fn queryOne(self: *Pool, comptime T: type, arena: Allocator, sql: []const u8, args: anytype) Error!?T {
    const conn = try self.acquire();
    defer self.release(conn);
    return conn.queryOne(T, arena, sql, args);
}

pub fn get(self: *Pool, comptime T: type, arena: Allocator, sql: []const u8, args: anytype) Error!T {
    const conn = try self.acquire();
    defer self.release(conn);
    return conn.get(T, arena, sql, args);
}

pub fn exec(self: *Pool, sql: []const u8, args: anytype) Error!u64 {
    const conn = try self.acquire();
    defer self.release(conn);
    return conn.exec(sql, args);
}

pub fn execScript(self: *Pool, sql: []const u8) Error!void {
    const conn = try self.acquire();
    defer self.release(conn);
    return conn.execScript(sql);
}
