//! A response whose body is read as it arrives. Created by `Client.stream`;
//! holds its connection until `deinit`.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Client = @import("Client.zig");

const Stream = @This();

client: *Client,
/// Owns the prepared request, copied headers and decompression buffer.
arena: std.heap.ArenaAllocator,
request: http.Client.Request = undefined,
/// Points into `request`, which is why `Stream` lives on the heap.
response: http.Client.Response = undefined,
/// True while `request` holds a connection that `deinit` must release.
live: bool = false,
status: http.Status = .ok,
headers: []const http.Header = &.{},
body_reader: ?*Io.Reader = null,
transfer_buffer: [4096]u8 = undefined,
decompress: http.Decompress = undefined,

/// Sends the request and waits for the head, retrying like `Client.send`.
pub fn open(client: *Client, request: Client.Request) Client.Error!*Stream {
    const self = try client.gpa.create(Stream);
    self.* = .{ .client = client, .arena = .init(client.gpa) };
    errdefer self.deinit();

    const prepared = try client.prepare(self.arena.allocator(), request);
    var attempt: u8 = 1;
    while (true) : (attempt += 1) {
        const result = Client.raceTimeout(client.io, prepared.timeout, void, openOnce, .{ self, prepared });
        const delay = client.retryDelay(prepared, attempt, self.outcomeOf(result)) orelse {
            try result;
            return self;
        };
        self.release();
        try client.io.sleep(delay, .awake);
    }
}

/// Reads the body, decompressed if the server compressed it.
pub fn reader(self: *Stream) error{ OutOfMemory, UpstreamUnavailable }!*Io.Reader {
    if (self.body_reader) |r| return r;
    const buffer = Client.allocDecompressBuffer(self.arena.allocator(), self.response.head.content_encoding) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UpstreamUnavailable,
    };
    const r = self.response.readerDecompressing(&self.transfer_buffer, &self.decompress, buffer);
    self.body_reader = r;
    return r;
}

/// After `reader()` returns `error.ReadFailed`, the underlying cause.
pub fn bodyError(self: *const Stream) ?http.Reader.BodyError {
    return self.response.bodyErr();
}

/// Returns the first header named `name` (case-insensitive).
pub fn header(self: *const Stream, name: []const u8) ?[]const u8 {
    for (self.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Releases the connection (closed unless the body was read to the end) and
/// frees everything the stream owns.
pub fn deinit(self: *Stream) void {
    self.release();
    self.arena.deinit();
    const gpa = self.client.gpa;
    gpa.destroy(self);
}

fn release(self: *Stream) void {
    if (!self.live) return;
    // An unread body would otherwise be drained first, which can take
    // forever on a large or endless stream. Closing is cheaper.
    if (self.request.reader.state != .ready) {
        if (self.request.connection) |connection| connection.closing = true;
    }
    self.request.deinit();
    self.live = false;
}

fn openOnce(self: *Stream, prepared: Client.Prepared) Client.Error!void {
    self.openOnceUnmapped(prepared) catch |err| return Client.classify(err);
}

fn openOnceUnmapped(self: *Stream, prepared: Client.Prepared) !void {
    const arena = self.arena.allocator();
    try self.client.startRequest(prepared, &self.request);
    self.live = true;
    errdefer self.release();
    self.response = try self.client.exchange(arena, prepared, &self.request);
    self.status = self.response.head.status;
    self.headers = try Client.copyHeaders(arena, self.response.head.bytes);
}

fn outcomeOf(self: *const Stream, result: Client.Error!void) @import("retry.zig").Outcome {
    result catch |err| return .{ .failed = err };
    return .{ .status = .{ .code = self.status, .retry_after = self.header("retry-after") } };
}
