//! A tour of `zag.Client`, runnable offline: it starts a small fake service
//! in-process on :3002, calls it with every client feature, and prints what
//! happened.
//!
//!   make run EXAMPLE=client_tour

const std = @import("std");
const zag = @import("zag-http");

const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // The fake service we're going to call.
    var remote_state: Remote = .{};
    var remote = try newRemote(gpa, &remote_state);
    defer remote.deinit();
    var server = try io.concurrent(runRemote, .{ io, gpa, &remote });
    defer server.cancel(io);

    var client: zag.Client = .init(io, gpa, .{
        .base_url = "http://127.0.0.1:3002",
        .headers = &.{.{ .name = "authorization", .value = "Bearer demo-token" }},
        .timeout = .fromSeconds(5),
        .retry = .{ .base_delay = .fromMilliseconds(20) },
    });
    defer client.deinit();

    // Everything the client returns lives in this arena. In a handler you'd
    // use `ctx.arena` instead and never free anything yourself.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try jsonHelpers(&client, arena);
    try queryAndHeaders(&client, arena);
    try bodies(&client, arena);
    try streamingDownload(&client);
    try retriesAndTimeouts(&client, arena, &remote_state);
}

fn jsonHelpers(client: *zag.Client, arena: std.mem.Allocator) !void {
    print("\n== JSON helpers\n", .{});
    const user = try client.getJson(User, arena, "/users/7");
    print("getJson  -> {s} (id {d})\n", .{ user.name, user.id });

    const created = try client.postJson(User, arena, "/users", User{ .id = 8, .name = "grace" });
    print("postJson -> created {s}\n", .{created.name});

    // Non-2xx statuses become errors you can `try` straight out of a handler.
    _ = client.getJson(User, arena, "/users/404") catch |err| print("getJson /users/404 -> error.{s}\n", .{@errorName(err)});
}

fn queryAndHeaders(client: *zag.Client, arena: std.mem.Allocator) !void {
    print("\n== send: query, headers, raw response\n", .{});
    const res = try client.send(arena, .{
        .url = "/echo",
        .query = &.{ .{ .name = "search", .value = "zig & http" }, .{ .name = "page", .value = "2" } },
        .headers = &.{.{ .name = "x-request-id", .value = "abc123" }},
    });
    print("status {d}, content-type {s}\n{s}", .{
        @backingInt(res.status), res.header("content-type") orelse "?", res.body,
    });
}

fn bodies(client: *zag.Client, arena: std.mem.Allocator) !void {
    print("\n== request bodies\n", .{});
    const form = try client.send(arena, .{
        .method = .POST,
        .url = "/echo",
        .body = .{ .form = &.{ .{ .name = "user", .value = "ada" }, .{ .name = "lang", .value = "zig" } } },
    });
    print("-- form\n{s}", .{form.body});

    var file: std.Io.Reader = .fixed("pretend this is a large file read from disk\n");
    const upload = try client.send(arena, .{
        .method = .POST,
        .url = "/echo",
        .body = .{ .multipart = &.{
            .{ .name = "title", .data = .{ .bytes = "Quarterly report" } },
            .{ .name = "file", .filename = "report.txt", .content_type = "text/plain", .data = .{ .reader = &file } },
        } },
    });
    print("-- multipart (file part streamed from a reader)\n{s}", .{upload.body});

    var source: std.Io.Reader = .fixed("bytes produced on the fly");
    const streamed = try client.send(arena, .{
        .method = .PUT,
        .url = "/echo",
        .body = .{ .stream = .{ .reader = &source, .content_type = "text/plain" } },
    });
    print("-- streamed body (chunked)\n{s}", .{streamed.body});
}

fn streamingDownload(client: *zag.Client) !void {
    print("\n== streaming download\n", .{});
    var download = try client.stream(.{ .url = "/big" });
    defer download.deinit();

    // Read in chunks as data arrives instead of buffering the whole body.
    const reader = try download.reader();
    var total: usize = 0;
    var chunks: usize = 0;
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&buffer);
        if (n == 0) break;
        total += n;
        chunks += 1;
    }
    print("status {d}: read {d} bytes in {d} chunks\n", .{ @backingInt(download.status), total, chunks });
}

fn retriesAndTimeouts(client: *zag.Client, arena: std.mem.Allocator, remote: *Remote) !void {
    print("\n== retries and timeouts\n", .{});
    const recovered = try client.send(arena, .{ .url = "/flaky" });
    print("GET /flaky -> {s} after {d} attempts (503, 503, then 200)\n", .{ recovered.body, remote.flaky_calls.load(.monotonic) });

    remote.flaky_calls.store(0, .monotonic);
    const post = try client.send(arena, .{ .method = .POST, .url = "/flaky" });
    print("POST /flaky -> {d} after {d} attempt (POST is not retried)\n", .{ @backingInt(post.status), remote.flaky_calls.load(.monotonic) });

    _ = client.send(arena, .{
        .url = "/slow",
        .timeout = .fromMilliseconds(100),
        .retry = .{ .max_attempts = 1 },
    }) catch |err| print("GET /slow with 100ms timeout -> error.{s}\n", .{@errorName(err)});
}

// ---------------------------------------------------------------------------
// The fake remote service.

const User = struct { id: u64, name: []const u8 };

const Remote = struct {
    flaky_calls: std.atomic.Value(u32) = .init(0),
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

/// Describes the request it received.
fn echo(ctx: *zag.Context) ![]const u8 {
    const r = ctx.request;
    return std.fmt.allocPrint(ctx.arena,
        \\  method:        {s}
        \\  query:         {s}
        \\  authorization: {s}
        \\  x-request-id:  {s}
        \\  content-type:  {s}
        \\  body ({d} bytes): {s}
        \\
    , .{
        @tagName(r.method),
        r.query,
        r.header("authorization") orelse "-",
        r.header("x-request-id") orelse "-",
        r.header("content-type") orelse "-",
        r.body.len,
        if (r.body.len > 1000) "(long)" else r.body,
    });
}

fn flaky(state: zag.State(Remote)) zag.Response {
    const calls = state.value.flaky_calls.fetchAdd(1, .monotonic) + 1;
    if (calls <= 2) return .empty(.service_unavailable);
    return .text("ok");
}

fn slow(ctx: *zag.Context) ![]const u8 {
    try ctx.io.sleep(.fromSeconds(1), .awake);
    return "too late";
}

const big_body: [500_000]u8 = @splat('z');

fn big() []const u8 {
    return &big_body;
}

fn newRemote(gpa: std.mem.Allocator, state: *Remote) !zag.Router(Remote) {
    var router: zag.Router(Remote) = .init(gpa, state);
    errdefer router.deinit();
    try router.get("/users/:id", getUser);
    try router.post("/users", createUser);
    try router.get("/echo", echo);
    try router.post("/echo", echo);
    try router.put("/echo", echo);
    try router.get("/flaky", flaky);
    try router.post("/flaky", flaky);
    try router.get("/slow", slow);
    try router.get("/big", big);
    return router;
}

fn runRemote(io: std.Io, gpa: std.mem.Allocator, router: *zag.Router(Remote)) void {
    zag.serve(io, gpa, router, .{ .port = 3002 }) catch |err| switch (err) {
        error.Canceled => {},
        else => std.debug.print("fake service failed: {s}\n", .{@errorName(err)}),
    };
}
