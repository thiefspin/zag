//! End-to-end client tests against a real zag router on a loopback port.

const std = @import("std");
const zag = @import("../root.zig");
const testing = std.testing;

const User = struct { id: u64, name: []const u8 };

/// The fake remote service.
const Remote = struct {
    /// How many times /flaky has been called.
    flaky_calls: std.atomic.Value(u32) = .init(0),
    /// /flaky fails with 503 this many times before succeeding.
    flaky_failures: u32 = 2,
};

fn getUser(path: zag.Path(struct { id: u64 })) !zag.Json(User) {
    if (path.value.id == 404) return error.NotFound;
    return .{ .value = .{ .id = path.value.id, .name = "ada" } };
}

fn createUser(ctx: *zag.Context, body: zag.Json(User)) !zag.Response {
    var res: zag.Response = try .json(ctx.arena, body.value);
    res.status = .created;
    return res;
}

fn boom() std.http.Status {
    return .internal_server_error;
}

fn badJson() zag.Response {
    return .{ .headers = &.{.{ .name = "content-type", .value = "application/json" }}, .body = "{not json" };
}

/// Echoes what arrived as `method|query|x-id|authorization|content-type|body`.
fn inspect(ctx: *zag.Context) ![]const u8 {
    const r = ctx.request;
    return std.fmt.allocPrint(ctx.arena, "{s}|{s}|{s}|{s}|{s}|{s}", .{
        @tagName(r.method),                 r.query,
        r.header("x-id") orelse "",         r.header("authorization") orelse "",
        r.header("content-type") orelse "", r.body,
    });
}

fn flaky(state: zag.State(Remote)) zag.Response {
    const calls = state.value.flaky_calls.fetchAdd(1, .monotonic) + 1;
    if (calls <= state.value.flaky_failures) return .empty(.service_unavailable);
    return .text("recovered");
}

fn slow(ctx: *zag.Context) ![]const u8 {
    try ctx.io.sleep(.fromMilliseconds(300), .awake);
    return "late";
}

const big_body: [200_000]u8 = @splat('x');

fn big() []const u8 {
    return &big_body;
}

fn newRemote(state: *Remote) !zag.Router(Remote) {
    var router: zag.Router(Remote) = .init(testing.allocator, state);
    errdefer router.deinit();
    try router.get("/users/:id", getUser);
    try router.post("/users", createUser);
    try router.get("/boom", boom);
    try router.get("/bad-json", badJson);
    try router.route(.GET, "/inspect", inspect);
    try router.route(.POST, "/inspect", inspect);
    try router.route(.PUT, "/inspect", inspect);
    try router.get("/flaky", flaky);
    try router.post("/flaky", flaky);
    try router.get("/slow", slow);
    try router.get("/big", big);
    return router;
}

/// A remote service plus a client pointed at it, torn down together.
const Fixture = struct {
    state: Remote = .{},
    router: zag.Router(Remote) = undefined,
    server: *zag.testing.TestServer = undefined,
    client: zag.Client = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn init(self: *Fixture, options: zag.Client.Options) !void {
        self.router = try newRemote(&self.state);
        self.server = try zag.testing.serve(&self.router);
        var with_url = options;
        with_url.base_url = self.server.url;
        self.client = .init(testing.io, testing.allocator, with_url);
        self.arena = .init(testing.allocator);
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.client.deinit();
        self.server.deinit();
        self.router.deinit();
    }
};

const fast_retry: zag.Client.Retry = .{ .base_delay = .fromMilliseconds(1), .max_delay = .fromMilliseconds(5) };

test "json helpers" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const arena = f.arena.allocator();

    const user = try f.client.getJson(User, arena, "/users/7");
    try testing.expectEqual(7, user.id);
    try testing.expectEqualStrings("ada", user.name);

    const created = try f.client.postJson(User, arena, "users", User{ .id = 9, .name = "bob" });
    try testing.expectEqualStrings("bob", created.name);
}

test "status and decoding errors" {
    var f: Fixture = .{};
    try f.init(.{ .retry = fast_retry });
    defer f.deinit();
    const arena = f.arena.allocator();

    try testing.expectError(error.NotFound, f.client.getJson(User, arena, "/users/404"));
    try testing.expectError(error.UpstreamStatus, f.client.getJson(User, arena, "/boom"));
    try testing.expectError(error.UpstreamInvalidResponse, f.client.getJson(User, arena, "/bad-json"));

    // `send` returns the raw response without checking the status.
    const res = try f.client.send(arena, .{ .url = "/boom" });
    try testing.expectEqual(.internal_server_error, res.status);
}

test "query, headers and default headers" {
    var f: Fixture = .{};
    try f.init(.{ .headers = &.{
        .{ .name = "authorization", .value = "Bearer secret" },
        .{ .name = "x-id", .value = "default" },
    } });
    defer f.deinit();

    const res = try f.client.send(f.arena.allocator(), .{
        .url = "/inspect",
        .query = &.{ .{ .name = "q", .value = "a b" }, .{ .name = "n", .value = "1" } },
        .headers = &.{.{ .name = "X-Id", .value = "mine" }},
    });
    try testing.expectEqualStrings("GET|q=a%20b&n=1|mine|Bearer secret||", res.body);
}

test "form and bytes bodies" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    const arena = f.arena.allocator();

    const form = try f.client.send(arena, .{
        .method = .POST,
        .url = "/inspect",
        .body = .{ .form = &.{ .{ .name = "a", .value = "1" }, .{ .name = "b", .value = "x&y" } } },
    });
    try testing.expectEqualStrings("POST||||application/x-www-form-urlencoded|a=1&b=x%26y", form.body);

    const bytes = try f.client.send(arena, .{
        .method = .PUT,
        .url = "/inspect",
        .body = .{ .bytes = .{ .data = "raw", .content_type = "text/plain" } },
    });
    try testing.expectEqualStrings("PUT||||text/plain|raw", bytes.body);
}

test "multipart upload, including a streamed part" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();

    var file: std.Io.Reader = .fixed("file contents");
    const res = try f.client.send(f.arena.allocator(), .{
        .method = .POST,
        .url = "/inspect",
        .body = .{ .multipart = &.{
            .{ .name = "title", .data = .{ .bytes = "report" } },
            .{ .name = "file", .filename = "r.txt", .content_type = "text/plain", .data = .{ .reader = &file } },
        } },
    });
    var fields = std.mem.splitScalar(u8, res.body, '|');
    for (0..4) |_| _ = fields.next();
    const content_type = fields.next().?;
    const body = fields.rest();

    try testing.expect(std.mem.startsWith(u8, content_type, "multipart/form-data; boundary=zag-"));
    const boundary = content_type["multipart/form-data; boundary=".len..];
    try testing.expect(std.mem.indexOf(u8, body, "name=\"title\"\r\n\r\nreport\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "filename=\"r.txt\"\r\ncontent-type: text/plain\r\n\r\nfile contents\r\n") != null);
    const closing = try std.fmt.allocPrint(f.arena.allocator(), "--{s}--\r\n", .{boundary});
    try testing.expect(std.mem.endsWith(u8, body, closing));
}

test "streamed request body" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();

    var source: std.Io.Reader = .fixed("streamed upload");
    const res = try f.client.send(f.arena.allocator(), .{
        .method = .POST,
        .url = "/inspect",
        .body = .{ .stream = .{ .reader = &source, .content_type = "text/plain" } },
    });
    try testing.expectEqualStrings("POST||||text/plain|streamed upload", res.body);
}

test "streaming response" {
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();

    var download = try f.client.stream(.{ .url = "/big" });
    defer download.deinit();
    try testing.expectEqual(.ok, download.status);
    const body = try (try download.reader()).allocRemaining(testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(body);
    try testing.expectEqual(big_body.len, body.len);

    // Abandoning a stream without reading it closes the connection cleanly.
    var abandoned = try f.client.stream(.{ .url = "/big" });
    abandoned.deinit();
}

test "retries idempotent requests on 503" {
    var f: Fixture = .{};
    try f.init(.{ .retry = fast_retry });
    defer f.deinit();

    const res = try f.client.send(f.arena.allocator(), .{ .url = "/flaky" });
    try testing.expectEqualStrings("recovered", res.body);
    try testing.expectEqual(3, f.state.flaky_calls.load(.monotonic));
}

test "does not retry POST by default" {
    var f: Fixture = .{};
    try f.init(.{ .retry = fast_retry });
    defer f.deinit();

    const res = try f.client.send(f.arena.allocator(), .{ .method = .POST, .url = "/flaky" });
    try testing.expectEqual(.service_unavailable, res.status);
    try testing.expectEqual(1, f.state.flaky_calls.load(.monotonic));
}

test "stream retries too" {
    var f: Fixture = .{};
    try f.init(.{ .retry = fast_retry });
    defer f.deinit();

    var s = try f.client.stream(.{ .url = "/flaky" });
    defer s.deinit();
    try testing.expectEqual(.ok, s.status);
    try testing.expectEqual(3, f.state.flaky_calls.load(.monotonic));
}

test "timeout" {
    var f: Fixture = .{};
    try f.init(.{ .retry = .{ .max_attempts = 1 } });
    defer f.deinit();

    try testing.expectError(error.Timeout, f.client.send(f.arena.allocator(), .{
        .url = "/slow",
        .timeout = .fromMilliseconds(50),
    }));
    // A fresh request on the same client still works afterwards.
    const res = try f.client.send(f.arena.allocator(), .{ .url = "/users/1" });
    try testing.expectEqual(.ok, res.status);
}

test "limits and connection failures" {
    var f: Fixture = .{};
    try f.init(.{ .max_response_size = 1000, .retry = fast_retry });
    defer f.deinit();
    try testing.expectError(error.ResponseTooLarge, f.client.send(f.arena.allocator(), .{ .url = "/big" }));

    var refused: zag.Client = .init(testing.io, testing.allocator, .{ .base_url = "http://127.0.0.1:1", .retry = fast_retry });
    defer refused.deinit();
    try testing.expectError(error.UpstreamUnavailable, refused.send(f.arena.allocator(), .{ .url = "/" }));
    try testing.expectError(error.InvalidRequest, refused.send(f.arena.allocator(), .{ .url = "/", .headers = &.{.{ .name = "bad", .value = "a\r\nb" }} }));
}

/// A service that calls the remote one, to check errors map to sensible statuses.
const Gateway = struct { client: *zag.Client };

fn proxyUser(ctx: *zag.Context, state: zag.State(Gateway), path: zag.Path(struct { id: []const u8 })) !zag.Json(User) {
    const target = try std.fmt.allocPrint(ctx.arena, "/users/{s}", .{path.value.id});
    return .{ .value = try state.value.client.getJson(User, ctx.arena, target) };
}

fn proxyBoom(ctx: *zag.Context, state: zag.State(Gateway)) !zag.Json(User) {
    return .{ .value = try state.value.client.getJson(User, ctx.arena, "/boom") };
}

test "handlers can return client errors directly" {
    var f: Fixture = .{};
    try f.init(.{ .retry = fast_retry });
    defer f.deinit();

    var gateway_state: Gateway = .{ .client = &f.client };
    var gateway: zag.Router(Gateway) = .init(testing.allocator, &gateway_state);
    defer gateway.deinit();
    try gateway.get("/u/:id", proxyUser);
    try gateway.get("/boom", proxyBoom);

    var ok = try zag.testing.request(&gateway, .GET, "/u/5", .{});
    defer ok.deinit();
    try testing.expectEqualStrings("{\"id\":5,\"name\":\"ada\"}", ok.body);

    var missing = try zag.testing.request(&gateway, .GET, "/u/404", .{});
    defer missing.deinit();
    try testing.expectEqual(.not_found, missing.status);

    var failed = try zag.testing.request(&gateway, .GET, "/boom", .{});
    defer failed.deinit();
    try testing.expectEqual(.bad_gateway, failed.status);
}
