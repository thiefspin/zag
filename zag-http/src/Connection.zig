//! The keep-alive loop for one TCP connection: read a request, dispatch it,
//! write the response, repeat.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const Context = @import("Context.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");

const log = std.log.scoped(.zag);
const Connection = @This();

pub const Options = struct {
    max_body_size: usize,
    keep_alive: bool,
};

/// A type-erased router, so connections don't depend on the state type.
pub const Dispatch = struct {
    ptr: *const anyopaque,
    handleFn: *const fn (ptr: *const anyopaque, ctx: *Context) Response,

    pub fn of(router: anytype) Dispatch {
        const R = @TypeOf(router.*);
        const erased = struct {
            fn handle(ptr: *const anyopaque, ctx: *Context) Response {
                const typed: *const R = @ptrCast(@alignCast(ptr));
                return typed.handle(ctx);
            }
        };
        return .{ .ptr = router, .handleFn = erased.handle };
    }

    pub fn handle(self: Dispatch, ctx: *Context) Response {
        return self.handleFn(self.ptr, ctx);
    }
};

io: std.Io,
dispatch: Dispatch,
options: Options,
server: http.Server,
/// Reset after every request; keeps its capacity across keep-alive requests.
arena: std.heap.ArenaAllocator,

/// Serves requests until the client closes, an error occurs, or keep-alive ends.
pub fn run(self: *Connection) void {
    while (true) {
        _ = self.arena.reset(.retain_capacity);
        const keep_going = self.serveOne() catch |err| {
            log.debug("connection closed: {s}", .{@errorName(err)});
            return;
        };
        if (!keep_going) return;
    }
}

/// Handles one request. Returns whether the connection may be reused.
fn serveOne(self: *Connection) !bool {
    var request = self.server.receiveHead() catch |err| return self.rejectHead(err);
    const arena = self.arena.allocator();
    const req = readRequest(&request, arena, self.options.max_body_size) catch |err|
        return rejectRequest(&request, err);

    var ctx: Context = .{ .request = req, .arena = arena, .io = self.io };
    const res = self.dispatch.handle(&ctx);

    const keep_alive = self.options.keep_alive and request.head.keep_alive;
    try send(&request, res, keep_alive);
    return keep_alive and self.server.reader.state == .ready;
}

/// Handles a failure to read the request head. Writes a bare error response
/// where HTTP expects one.
fn rejectHead(self: *Connection, err: http.Server.ReceiveHeadError) !bool {
    const status: http.Status = switch (err) {
        error.HttpConnectionClosing => return false,
        error.HttpHeadersOversize => .request_header_fields_too_large,
        error.HttpHeadersInvalid => .bad_request,
        error.HttpRequestTruncated, error.ReadFailed => return err,
    };
    try self.server.out.print("HTTP/1.1 {d} {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{
        @backingInt(status), status.phrase() orelse "",
    });
    try self.server.out.flush();
    return false;
}

/// Handles a failure to read the rest of the request. Always closes.
fn rejectRequest(request: *http.Server.Request, err: anyerror) !bool {
    const status: http.Status = switch (err) {
        error.PayloadTooLarge => .payload_too_large,
        error.HttpExpectationFailed => .expectation_failed,
        error.UnsupportedEncoding => .unsupported_media_type,
        error.HttpHeadersInvalid, error.MalformedBody => .bad_request,
        error.OutOfMemory => .internal_server_error,
        else => return err,
    };
    // Already handled (or rejected); don't let `respond` look at it again.
    request.head.expect = null;
    try request.respond("", .{ .status = status, .keep_alive = false });
    return false;
}

/// Copies the head into `arena` and reads the whole body, so the request
/// stays valid while the handler runs.
fn readRequest(request: *http.Server.Request, arena: Allocator, max_body_size: usize) !Request {
    const head_bytes = try arena.dupe(u8, request.head_buffer);
    // Same bytes `receiveHead` already parsed, so this can't fail differently.
    const head = try http.Server.Request.Head.parse(head_bytes);
    if (head.content_length != null and head.transfer_encoding != .none) return error.HttpHeadersInvalid;
    if (head.transfer_compression != .identity) return error.UnsupportedEncoding;

    const path, const query = Request.splitTarget(head.target);
    return .{
        .method = head.method,
        .path = path,
        .query = query,
        .headers = try collectHeaders(arena, head_bytes),
        .body = try readBody(request, arena, max_body_size),
    };
}

fn collectHeaders(arena: Allocator, head_bytes: []const u8) ![]const http.Header {
    var count: usize = 0;
    var counter: http.HeaderIterator = .init(head_bytes);
    while (counter.next()) |_| count += 1;

    const headers = try arena.alloc(http.Header, count);
    var it: http.HeaderIterator = .init(head_bytes);
    for (headers) |*h| h.* = it.next().?;
    return headers;
}

fn readBody(request: *http.Server.Request, arena: Allocator, max_body_size: usize) ![]const u8 {
    const head = request.head;
    const has_body = head.content_length != null or head.transfer_encoding != .none;
    if (!has_body) return "";
    if ((head.content_length orelse 0) > max_body_size) return error.PayloadTooLarge;

    const body_reader = try request.readerExpectContinue(&.{});
    return body_reader.allocRemaining(arena, .limited(max_body_size)) catch |err| switch (err) {
        error.StreamTooLong => error.PayloadTooLarge,
        // A body framing error (e.g. bad chunk) is the client's fault.
        error.ReadFailed => if (request.server.reader.body_err != null) error.MalformedBody else error.ReadFailed,
        else => |e| e,
    };
}

fn send(request: *http.Server.Request, res: Response, keep_alive: bool) !void {
    if (hasLineBreak(res.headers)) {
        log.err("response header contains CR or LF; sending 500 instead", .{});
        return request.respond("", .{ .status = .internal_server_error, .keep_alive = false });
    }
    try request.respond(res.body, .{
        .status = res.status,
        .extra_headers = res.headers,
        .keep_alive = keep_alive,
    });
}

/// Header values with CR/LF would let a handler inject headers.
fn hasLineBreak(headers: []const http.Header) bool {
    for (headers) |h| {
        if (std.mem.findAny(u8, h.name, "\r\n") != null) return true;
        if (std.mem.findAny(u8, h.value, "\r\n") != null) return true;
    }
    return false;
}
