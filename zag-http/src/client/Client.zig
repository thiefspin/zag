//! An HTTP client for calling other services: a thin layer over
//! `std.http.Client` (TLS, pooling, redirects, decompression) that adds base
//! URLs, default headers, typed JSON, request bodies, timeouts and retries.
//!
//! Share one `Client` across the app (e.g. in router state); it is threadsafe.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;

const body_impl = @import("body.zig");
const retry_impl = @import("retry.zig");
const url = @import("url.zig");

const log = std.log.scoped(.zag_client);
const Client = @This();

pub const Body = body_impl.Body;
pub const Part = body_impl.Part;
pub const Param = url.Param;
pub const Retry = retry_impl.Retry;
pub const Stream = @import("Stream.zig");

/// Errors from sending a request. `respond.fromError` maps them to 502/504
/// when a handler returns them.
pub const Error = error{
    /// No response within the timeout.
    Timeout,
    /// Connection, TLS or protocol failure talking to the other service.
    UpstreamUnavailable,
    /// The response body exceeded `max_response_size`.
    ResponseTooLarge,
    /// Bad URL, header, or multipart field. A bug in the caller.
    InvalidRequest,
    OutOfMemory,
    Canceled,
};

/// Errors from `expectSuccess` for non-2xx responses.
pub const StatusError = error{ Unauthorized, Forbidden, NotFound, UpstreamStatus };

/// Errors from the JSON helpers.
pub const JsonError = Error || StatusError || error{UpstreamInvalidResponse};

pub const Options = struct {
    /// Joined to relative request URLs.
    base_url: ?[]const u8 = null,
    /// Sent with every request unless the request sets the same header.
    headers: []const http.Header = &.{},
    /// Per attempt. null waits forever.
    timeout: ?Io.Duration = .fromSeconds(30),
    retry: Retry = .{},
    max_response_size: usize = 10 * 1024 * 1024,
    max_redirects: u16 = 3,
    user_agent: []const u8 = "zag-http",
};

pub const Request = struct {
    method: http.Method = .GET,
    /// Absolute, or relative to `Options.base_url`.
    url: []const u8,
    /// Percent-encoded and appended to the URL.
    query: []const Param = &.{},
    headers: []const http.Header = &.{},
    body: Body = .none,
    /// Overrides `Options.timeout`.
    timeout: ?Io.Duration = null,
    /// Overrides `Options.retry`.
    retry: ?Retry = null,
};

/// A fully-read response. All slices live in the arena passed to `send`.
pub const Response = struct {
    status: http.Status,
    headers: []const http.Header,
    body: []const u8,

    /// Returns the first header named `name` (case-insensitive).
    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        return findHeader(self.headers, name);
    }

    /// Returns an error for non-2xx statuses (see `StatusError`).
    pub fn expectSuccess(self: Response) StatusError!void {
        if (self.status.class() == .success) return;
        log.debug("upstream returned {d}", .{@backingInt(self.status)});
        return switch (self.status) {
            .unauthorized => error.Unauthorized,
            .forbidden => error.Forbidden,
            .not_found => error.NotFound,
            else => error.UpstreamStatus,
        };
    }

    /// Decodes the body as JSON. Unknown fields are ignored.
    pub fn json(self: Response, comptime T: type, arena: Allocator) error{ OutOfMemory, UpstreamInvalidResponse }!T {
        return std.json.parseFromSliceLeaky(T, arena, self.body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.UpstreamInvalidResponse,
        };
    }
};

io: Io,
gpa: Allocator,
options: Options,
std_client: http.Client,

pub fn init(io: Io, gpa: Allocator, options: Options) Client {
    return .{ .io = io, .gpa = gpa, .options = options, .std_client = .{ .io = io, .allocator = gpa } };
}

pub fn deinit(self: *Client) void {
    self.std_client.deinit();
    self.* = undefined;
}

/// `GET url`, then decode the JSON response as `T`.
pub fn getJson(self: *Client, comptime T: type, arena: Allocator, target: []const u8) JsonError!T {
    return self.sendJson(T, arena, .{ .url = target });
}

/// `POST url` with `value` as JSON, then decode the JSON response as `T`.
pub fn postJson(self: *Client, comptime T: type, arena: Allocator, target: []const u8, value: anytype) JsonError!T {
    return self.sendJson(T, arena, .{ .method = .POST, .url = target, .body = try .json(arena, value) });
}

/// Sends `request`, checks the status, and decodes the JSON response as `T`.
pub fn sendJson(self: *Client, comptime T: type, arena: Allocator, request: Request) JsonError!T {
    var with_accept = request;
    with_accept.headers = try withDefault(arena, request.headers, .{ .name = "accept", .value = "application/json" });
    const res = try self.send(arena, with_accept);
    try res.expectSuccess();
    return res.json(T, arena);
}

/// Sends `request` and reads the whole response into `arena`. Retries and
/// timeouts apply; the status is not checked.
pub fn send(self: *Client, arena: Allocator, request: Request) Error!Response {
    const prepared = try self.prepare(arena, request);
    var attempt: u8 = 1;
    while (true) : (attempt += 1) {
        const result = raceTimeout(self.io, prepared.timeout, Response, sendOnce, .{ self, arena, prepared });
        const delay = self.retryDelay(prepared, attempt, outcomeOf(result)) orelse return result;
        try self.io.sleep(delay, .awake);
    }
}

/// Sends `request` and returns once the response head has arrived; read the
/// body with `Stream.reader`. The timeout covers only the head. Call `deinit`.
pub fn stream(self: *Client, request: Request) Error!*Stream {
    return Stream.open(self, request);
}

/// A request with URL, headers and settings resolved.
pub const Prepared = struct {
    method: http.Method,
    uri: std.Uri,
    headers: []const http.Header,
    /// Credentials are present, so redirects aren't followed (see `startRequest`).
    has_credentials: bool,
    body: Body,
    timeout: ?Io.Duration,
    retry: Retry,
};

pub fn prepare(self: *const Client, arena: Allocator, request: Request) Error!Prepared {
    try request.body.validate();
    const full_url = try url.build(arena, self.options.base_url, request.url, request.query);
    const uri = std.Uri.parse(full_url) catch return error.InvalidRequest;
    const headers = try mergeHeaders(arena, request.headers, self.options.headers);
    return .{
        .method = request.method,
        .uri = uri,
        .headers = headers.list,
        .has_credentials = headers.has_credentials,
        .body = request.body,
        .timeout = request.timeout orelse self.options.timeout,
        .retry = request.retry orelse self.options.retry,
    };
}

/// Starts a `std.http.Client` request for `prepared` in `slot`.
pub fn startRequest(self: *Client, prepared: Prepared, slot: *http.Client.Request) !void {
    // Redirects are followed only without a body (it can't be resent) and
    // without credentials: std 0.17.1 doesn't send `privileged_headers`, so
    // credentials go in `extra_headers`, which a redirect to another host
    // would leak. The 3xx response is returned to the caller instead.
    const follow = prepared.body == .none and !prepared.has_credentials;
    slot.* = try self.std_client.request(prepared.method, prepared.uri, .{
        .redirect_behavior = if (follow) .init(self.options.max_redirects) else .unhandled,
        .headers = .{ .user_agent = .{ .override = self.options.user_agent } },
        .extra_headers = prepared.headers,
    });
}

/// Sends the body and waits for the response head.
pub fn exchange(self: *Client, arena: Allocator, prepared: Prepared, request: *http.Client.Request) !http.Client.Response {
    try body_impl.send(request, arena, self.io, prepared.body);
    const follows = prepared.body == .none and !prepared.has_credentials;
    const redirect_buffer: []u8 = if (follows) try arena.alloc(u8, 8 * 1024) else &.{};
    return request.receiveHead(redirect_buffer);
}

/// Returns the delay before the next attempt, or null to stop.
pub fn retryDelay(self: *const Client, prepared: Prepared, attempt: u8, outcome: retry_impl.Outcome) ?Io.Duration {
    var random: u64 = undefined;
    self.io.random(std.mem.asBytes(&random));
    const delay = retry_impl.nextDelay(prepared.retry, .{
        .number = attempt,
        .method = prepared.method,
        .replayable = prepared.body.isReplayable(),
        .outcome = outcome,
    }, random) orelse return null;
    log.debug("retrying {s} {f} (attempt {d}) in {d}ms", .{
        @tagName(prepared.method), prepared.uri.fmt(.all), attempt + 1, delay.toMilliseconds(),
    });
    return delay;
}

/// One attempt: connect, send, read the whole response.
fn sendOnce(self: *Client, arena: Allocator, prepared: Prepared) Error!Response {
    return self.sendOnceUnmapped(arena, prepared) catch |err| return classify(err);
}

fn sendOnceUnmapped(self: *Client, arena: Allocator, prepared: Prepared) !Response {
    var request: http.Client.Request = undefined;
    try self.startRequest(prepared, &request);
    defer request.deinit();
    var response = try self.exchange(arena, prepared, &request);
    const headers = try copyHeaders(arena, response.head.bytes);
    const status = response.head.status;
    return .{ .status = status, .headers = headers, .body = try readBody(arena, &response, self.options.max_response_size) };
}

/// Reads and decompresses the whole body into `arena`.
fn readBody(arena: Allocator, response: *http.Client.Response, limit: usize) ![]const u8 {
    const decompress_buffer = try allocDecompressBuffer(arena, response.head.content_encoding);
    var transfer_buffer: [1024]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(arena, .limited(limit)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => |e| return e,
    };
}

pub fn allocDecompressBuffer(gpa: Allocator, encoding: http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .deflate, .gzip => gpa.alloc(u8, std.compress.flate.max_window_len),
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len),
        .compress => error.UnsupportedCompressionMethod,
    };
}

/// Copies response headers out of the connection buffer into `arena`.
pub fn copyHeaders(arena: Allocator, head_bytes: []const u8) ![]const http.Header {
    const bytes = try arena.dupe(u8, head_bytes);
    var list: std.ArrayList(http.Header) = .empty;
    var it: http.HeaderIterator = .init(bytes);
    while (it.next()) |h| try list.append(arena, h);
    return list.items;
}

/// Runs `func(args)` and fails with `error.Timeout` if it takes longer than
/// `timeout`. The request runs as its own task, raced against a sleep; the
/// loser is canceled. Without spare concurrency it runs without a timeout.
pub fn raceTimeout(io: Io, timeout: ?Io.Duration, comptime T: type, comptime func: anytype, args: anytype) Error!T {
    const duration = timeout orelse return @call(.auto, func, args);
    const Race = union(enum) { done: Error!T, timer: Io.Cancelable!void };
    var buffer: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &buffer);
    select.concurrent(.done, func, args) catch return @call(.auto, func, args);
    select.concurrent(.timer, Io.sleep, .{ io, duration, .awake }) catch {
        select.cancelDiscard();
        return @call(.auto, func, args);
    };
    const first = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.cancelDiscard();
    return switch (first) {
        .done => |result| result,
        .timer => error.Timeout,
    };
}

pub fn outcomeOf(result: anytype) retry_impl.Outcome {
    const res = result catch |err| return .{ .failed = err };
    return .{ .status = .{ .code = res.status, .retry_after = findHeader(res.headers, "retry-after") } };
}

/// Maps `std.http.Client` errors onto `Error`. The original is logged.
pub fn classify(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.Timeout => error.Timeout,
        error.StreamTooLong => error.ResponseTooLarge,
        error.InvalidRequest, error.UnsupportedUriScheme, error.UriMissingHost, error.InvalidHostName => error.InvalidRequest,
        else => {
            log.debug("upstream request failed: {s}", .{@errorName(err)});
            return error.UpstreamUnavailable;
        },
    };
}

const MergedHeaders = struct { list: []const http.Header, has_credentials: bool };

/// Request headers first, then client defaults not overridden by name.
fn mergeHeaders(arena: Allocator, request: []const http.Header, defaults: []const http.Header) Error!MergedHeaders {
    var list: std.ArrayList(http.Header) = .empty;
    var has_credentials = false;
    for ([2][]const http.Header{ request, defaults }, 0..) |headers, pass| {
        for (headers) |h| {
            if (!isValidHeader(h)) return error.InvalidRequest;
            if (pass == 1 and findHeader(request, h.name) != null) continue;
            has_credentials = has_credentials or isCredential(h.name);
            try list.append(arena, h);
        }
    }
    return .{ .list = list.items, .has_credentials = has_credentials };
}

/// `headers` plus `extra` if no header with that name is present.
fn withDefault(arena: Allocator, headers: []const http.Header, extra: http.Header) error{OutOfMemory}![]const http.Header {
    if (findHeader(headers, extra.name) != null) return headers;
    return std.mem.concat(arena, http.Header, &.{ headers, &.{extra} });
}

fn findHeader(headers: []const http.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn isCredential(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie");
}

/// `std.http` asserts on these, so reject them as an error instead.
fn isValidHeader(h: http.Header) bool {
    if (h.name.len == 0 or std.mem.findAny(u8, h.name, ":\r\n") != null) return false;
    return std.mem.findAny(u8, h.value, "\r\n") == null;
}

test mergeHeaders {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const merged = try mergeHeaders(arena_state.allocator(), &.{
        .{ .name = "X-Id", .value = "1" },
    }, &.{
        .{ .name = "x-id", .value = "default" },
        .{ .name = "Authorization", .value = "Bearer t" },
        .{ .name = "accept", .value = "*/*" },
    });
    try std.testing.expectEqual(3, merged.list.len);
    try std.testing.expectEqualStrings("1", findHeader(merged.list, "x-id").?);
    try std.testing.expect(merged.has_credentials);
    try std.testing.expectError(error.InvalidRequest, mergeHeaders(arena_state.allocator(), &.{.{ .name = "a", .value = "x\r\ny" }}, &.{}));
}
