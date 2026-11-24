//! One connection to Postgres. Not threadsafe: use one per task, or a `Pool`.
//!
//! Parameterized calls use the extended protocol in one round trip:
//! Parse, Bind, Describe, Execute, Sync.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");
const errors = @import("errors.zig");
const params = @import("params.zig");
const rows = @import("rows.zig");
const Result = @import("Result.zig");

const log = std.log.scoped(.zag_pg);

const Conn = @This();

pub const Error = errors.QueryError || rows.DecodeError || error{
    /// I/O failed or the server closed the connection. The connection is broken.
    ConnectionFailed,
    AuthenticationFailed,
    /// `get` found no row.
    NotFound,
    Canceled,
};

const read_buffer_size = 16 * 1024;
const write_buffer_size = 8 * 1024;

io: Io,
gpa: Allocator,
stream: net.Stream,
reader: net.Stream.Reader,
writer: net.Stream.Writer,
buffer: []u8,
out: protocol.Builder,
/// Holds message bodies too large for the read buffer.
large: std.ArrayList(u8) = .empty,
/// Details of the last server error. Valid until the next error.
last_error: ?errors.Diagnostics = null,
error_arena: std.heap.ArenaAllocator,
/// Set on I/O or protocol errors; a broken connection must be closed.
broken: bool = false,
/// From ReadyForQuery: 'I' idle, 'T' in a transaction, 'E' failed transaction.
tx_status: u8 = 'I',

/// Connects, authenticates and waits until the server is ready.
pub fn open(io: Io, gpa: Allocator, config: Config) Error!*Conn {
    const stream = connect(io, config) catch |err| {
        log.debug("connect to {s}:{d} failed: {s}", .{ config.host, config.port, @errorName(err) });
        return if (err == error.Canceled) error.Canceled else error.ConnectionFailed;
    };
    errdefer stream.close(io);

    const self = try gpa.create(Conn);
    errdefer gpa.destroy(self);
    const buffer = try gpa.alloc(u8, read_buffer_size + write_buffer_size);
    self.* = .{
        .io = io,
        .gpa = gpa,
        .stream = stream,
        .reader = stream.reader(io, buffer[0..read_buffer_size]),
        .writer = stream.writer(io, buffer[read_buffer_size..]),
        .buffer = buffer,
        .out = .{ .gpa = gpa },
        .error_arena = .init(gpa),
    };
    errdefer self.deinitBuffers();

    try self.sendStartup(config);
    try auth.authenticate(self, config);
    try self.waitUntilReady();
    return self;
}

/// Closes the connection. Sends Terminate when the connection is healthy.
pub fn close(self: *Conn) void {
    if (!self.broken) {
        self.out.begin('X') catch {};
        self.sendAndFlush() catch {};
    }
    self.stream.close(self.io);
    self.deinitBuffers();
    self.gpa.destroy(self);
}

fn deinitBuffers(self: *Conn) void {
    self.out.deinit();
    self.large.deinit(self.gpa);
    self.error_arena.deinit();
    self.gpa.free(self.buffer);
}

const ConnectError = net.HostName.ConnectError || net.HostName.ValidateError;

/// Std's threaded `Io` does not support connect timeouts yet, so race a timer.
fn connect(io: Io, config: Config) (ConnectError || error{Timeout})!net.Stream {
    const Race = union(enum) { connected: ConnectError!net.Stream, timer: Io.Cancelable!void };
    var buffer: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &buffer);
    // A connect that finished as we gave up still owns a socket.
    defer while (select.cancel()) |leftover| switch (leftover) {
        .connected => |result| if (result) |stream| stream.close(io) else |_| {},
        .timer => {},
    };
    select.concurrent(.connected, connectNow, .{ io, config }) catch return connectNow(io, config);
    select.concurrent(.timer, Io.sleep, .{ io, config.connect_timeout, .awake }) catch {};
    return switch (try select.await()) {
        .connected => |result| result,
        .timer => error.Timeout,
    };
}

fn connectNow(io: Io, config: Config) ConnectError!net.Stream {
    const options: net.IpAddress.ConnectOptions = .{ .mode = .stream };
    if (net.IpAddress.parse(config.host, config.port)) |address| {
        return address.connect(io, options);
    } else |_| {
        const host: net.HostName = try .init(config.host);
        return host.connect(io, config.port, options);
    }
}

fn sendStartup(self: *Conn, config: Config) Error!void {
    try self.out.begin(null);
    try self.out.int32(protocol.protocol_version);
    try self.startupParam("user", config.user);
    try self.startupParam("database", config.database orelse config.user);
    try self.startupParam("application_name", config.application_name);
    try self.startupParam("client_encoding", "UTF8");
    if (config.statement_timeout) |timeout| {
        var digits: [24]u8 = undefined;
        const ms = std.fmt.bufPrint(&digits, "{d}", .{timeout.toMilliseconds()}) catch unreachable;
        try self.startupParam("statement_timeout", ms);
    }
    try self.out.raw(&.{0});
    try self.sendAndFlush();
}

fn startupParam(self: *Conn, name: []const u8, value: []const u8) Allocator.Error!void {
    try self.out.cstring(name);
    try self.out.cstring(value);
}

fn waitUntilReady(self: *Conn) Error!void {
    while (true) {
        const message = try self.read();
        switch (message.tag) {
            'K' => {}, // BackendKeyData, for cancel requests (not used yet)
            'Z' => return self.setReady(message),
            'E' => return self.startupFailed(message),
            else => return self.protocolViolation(message.tag),
        }
    }
}

// --- Queries -----------------------------------------------------------------

/// All rows, decoded into `T`. Memory belongs to `arena`.
pub fn query(self: *Conn, comptime T: type, arena: Allocator, sql: []const u8, args: anytype) Error![]T {
    var result = try self.start(arena, sql, args);
    defer result.finish();
    var list: std.ArrayList(T) = .empty;
    var mapping: ?rows.Mapping(T) = null;
    while (try result.next()) |values| {
        if (mapping == null) mapping = try rows.mapColumns(T, result.columns);
        try list.append(arena, try rows.decode(T, arena, result.columns, mapping.?, values));
    }
    return list.items;
}

/// The first row, or null. Further rows are ignored.
pub fn queryOne(self: *Conn, comptime T: type, arena: Allocator, sql: []const u8, args: anytype) Error!?T {
    var result = try self.start(arena, sql, args);
    defer result.finish();
    const values = try result.next() orelse return null;
    const row = try rows.decode(T, arena, result.columns, try rows.mapColumns(T, result.columns), values);
    while (try result.next()) |_| {}
    return row;
}

/// The first row; `error.NotFound` if there is none.
pub fn get(self: *Conn, comptime T: type, arena: Allocator, sql: []const u8, args: anytype) Error!T {
    return try self.queryOne(T, arena, sql, args) orelse error.NotFound;
}

/// Runs a statement and returns the number of rows it affected.
pub fn exec(self: *Conn, sql: []const u8, args: anytype) Error!u64 {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    var result = try self.start(scratch.allocator(), sql, args);
    defer result.finish();
    while (try result.next()) |_| {}
    return result.affected;
}

/// Runs one or more statements without parameters (simple protocol), for
/// migrations and transaction control. Never put user input in `sql`.
pub fn execScript(self: *Conn, sql: []const u8) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    try self.out.begin('Q');
    try self.out.cstring(sql);
    try self.sendAndFlush();
    var result: Result = .{ .conn = self, .arena = scratch.allocator() };
    defer result.finish();
    while (try result.next()) |_| {}
}

fn start(self: *Conn, arena: Allocator, sql: []const u8, args: anytype) Error!Result {
    if (self.broken) return error.ConnectionFailed;
    const values = try params.encode(arena, args);
    try self.sendExtended(sql, values);
    return .{ .conn = self, .arena = arena };
}

fn sendExtended(self: *Conn, sql: []const u8, values: []const ?[]const u8) Error!void {
    try self.out.begin('P'); // Parse: unnamed statement, types inferred
    try self.out.cstring("");
    try self.out.cstring(sql);
    try self.out.int16(0);
    try self.send();

    try self.out.begin('B'); // Bind: all parameters and results as text
    try self.out.cstring("");
    try self.out.cstring("");
    try self.out.int16(0);
    try self.out.int16(std.math.cast(i16, values.len) orelse return error.QueryFailed);
    for (values) |value| {
        const v = value orelse {
            try self.out.int32(-1);
            continue;
        };
        try self.out.int32(std.math.cast(i32, v.len) orelse return error.QueryFailed);
        try self.out.raw(v);
    }
    try self.out.int16(0);
    try self.send();

    try self.out.begin('D'); // Describe the portal, to get column names
    try self.out.raw("P\x00");
    try self.send();
    try self.out.begin('E'); // Execute, no row limit
    try self.out.cstring("");
    try self.out.int32(0);
    try self.send();
    try self.out.begin('S');
    try self.sendAndFlush();
}

// --- Messages ------------------------------------------------------------------

/// Reads the next message, skipping notices and other asynchronous messages.
pub fn read(self: *Conn) Error!protocol.Message {
    while (true) {
        const message = protocol.readMessage(&self.reader.interface, self.gpa, &self.large) catch |err| {
            self.broken = true;
            return switch (err) {
                error.OutOfMemory, error.ProtocolViolation => |e| e,
                error.ReadFailed => if (isCanceled(self.reader.err)) error.Canceled else error.ConnectionFailed,
                error.EndOfStream => error.ConnectionFailed,
            };
        };
        switch (message.tag) {
            'N' => logNotice(message.body),
            'S', 'A' => {}, // ParameterStatus, NotificationResponse
            else => return message,
        }
    }
}

/// Queues the message in `out`; `sendAndFlush` writes everything.
pub fn send(self: *Conn) Error!void {
    self.out.send(&self.writer.interface) catch return self.writeFailed();
}

pub fn sendAndFlush(self: *Conn) Error!void {
    try self.send();
    self.writer.interface.flush() catch return self.writeFailed();
}

fn writeFailed(self: *Conn) Error {
    self.broken = true;
    return if (isCanceled(self.writer.err)) error.Canceled else error.ConnectionFailed;
}

fn isCanceled(err: anytype) bool {
    const e = err orelse return false;
    return e == error.Canceled;
}

pub fn protocolViolation(self: *Conn, tag: u8) Error {
    log.debug("unexpected message '{c}'", .{tag});
    self.broken = true;
    return error.ProtocolViolation;
}

pub fn setReady(self: *Conn, message: protocol.Message) Error!void {
    if (message.body.len != 1) return self.protocolViolation(message.tag);
    self.tx_status = message.body[0];
}

/// Records the error details in `last_error` and returns the matching Zig error.
pub fn serverError(self: *Conn, body: []const u8) Error {
    const diagnostics = errors.Diagnostics.parse(body) catch return self.protocolViolation('E');
    log.debug("{s} {s}: {s}", .{ diagnostics.severity, diagnostics.code, diagnostics.message });
    self.last_error = self.keepDiagnostics(body);
    return diagnostics.toError();
}

/// Copies the details so they outlive the read buffer; null if out of memory.
fn keepDiagnostics(self: *Conn, body: []const u8) ?errors.Diagnostics {
    _ = self.error_arena.reset(.retain_capacity);
    const copy = self.error_arena.allocator().dupe(u8, body) catch return null;
    return errors.Diagnostics.parse(copy) catch unreachable; // parsed once already
}

/// An error before the connection is ready: bad credentials, missing database, ….
pub fn startupFailed(self: *Conn, message: protocol.Message) Error {
    const err = self.serverError(message.body);
    self.broken = true;
    if (err == error.ProtocolViolation) return err;
    const code = if (self.last_error) |d| d.code else "";
    return if (std.mem.startsWith(u8, code, "28")) error.AuthenticationFailed else error.ConnectionFailed;
}

fn logNotice(body: []const u8) void {
    const notice = errors.Diagnostics.parse(body) catch return;
    log.debug("{s}: {s}", .{ notice.severity, notice.message });
}
