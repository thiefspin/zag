//! End-to-end tests of the public API: router tests in memory, plus one test
//! over a real loopback socket.

const std = @import("std");
const zag = @import("root.zig");
const testing = std.testing;

const AppState = struct { greeting: []const u8 };
const User = struct { id: u64, name: []const u8 };
const CreateUser = struct { name: []const u8 };

fn index() []const u8 {
    return "hello";
}

fn getUser(p: zag.Path(struct { id: u64 })) zag.Json(User) {
    return .{ .value = .{ .id = p.value.id, .name = "ziggy" } };
}

fn me() []const u8 {
    return "me";
}

fn greet(
    ctx: *zag.Context,
    state: zag.State(AppState),
    q: zag.Query(struct { name: []const u8 = "world" }),
) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}, {s}", .{ state.value.greeting, q.value.name });
}

fn createUser(ctx: *zag.Context, body: zag.Json(CreateUser)) !zag.Response {
    const text = try std.fmt.allocPrint(ctx.arena, "created {s}", .{body.value.name});
    return .{ .status = .created, .body = text };
}

fn failing() !void {
    return error.Forbidden;
}

fn files(p: zag.Path(struct { rest: []const u8 })) zag.Response {
    return .text(p.value.rest);
}

fn newRouter(state: *AppState) !zag.Router(AppState) {
    var router: zag.Router(AppState) = .init(testing.allocator, state);
    errdefer router.deinit();
    try router.get("/", index);
    try router.get("/users/me", me);
    try router.get("/users/:id", getUser);
    try router.post("/users", createUser);
    try router.get("/greet", greet);
    try router.get("/forbidden", failing);
    try router.get("/files/*rest", files);
    return router;
}

fn expectResponse(router: anytype, method: std.http.Method, target: []const u8, status: std.http.Status, body: []const u8) !void {
    var res = try zag.testing.request(router, method, target, .{});
    defer res.deinit();
    try testing.expectEqual(status, res.status);
    try testing.expectEqualStrings(body, res.body);
}

test "routing, extractors and responses" {
    var state: AppState = .{ .greeting = "hi" };
    var router = try newRouter(&state);
    defer router.deinit();

    try expectResponse(&router, .GET, "/", .ok, "hello");
    try expectResponse(&router, .GET, "/users/7", .ok, "{\"id\":7,\"name\":\"ziggy\"}");
    try expectResponse(&router, .GET, "/users/me", .ok, "me");
    try expectResponse(&router, .GET, "/users/abc", .bad_request, "");
    try expectResponse(&router, .GET, "/greet?name=zig", .ok, "hi, zig");
    try expectResponse(&router, .GET, "/greet", .ok, "hi, world");
    try expectResponse(&router, .GET, "/forbidden", .forbidden, "");
    try expectResponse(&router, .GET, "/files/a/b%20c", .ok, "a/b c");
    try expectResponse(&router, .GET, "/files/a/%2e%2e/x", .bad_request, "");
    try expectResponse(&router, .GET, "/nope", .not_found, "");
    try expectResponse(&router, .HEAD, "/", .ok, "hello");
}

test "405 lists allowed methods" {
    var state: AppState = .{ .greeting = "hi" };
    var router = try newRouter(&state);
    defer router.deinit();

    var res = try zag.testing.request(&router, .DELETE, "/users", .{});
    defer res.deinit();
    try testing.expectEqual(.method_not_allowed, res.status);
    try testing.expectEqualStrings("POST", res.header("allow").?);
}

test "json body" {
    var state: AppState = .{ .greeting = "hi" };
    var router = try newRouter(&state);
    defer router.deinit();

    const json: []const std.http.Header = &.{.{ .name = "Content-Type", .value = "application/json" }};
    var ok = try zag.testing.request(&router, .POST, "/users", .{ .headers = json, .body = "{\"name\":\"ada\",\"extra\":1}" });
    defer ok.deinit();
    try testing.expectEqual(.created, ok.status);
    try testing.expectEqualStrings("created ada", ok.body);

    var bad = try zag.testing.request(&router, .POST, "/users", .{ .headers = json, .body = "{nope" });
    defer bad.deinit();
    try testing.expectEqual(.bad_request, bad.status);

    var wrong_type = try zag.testing.request(&router, .POST, "/users", .{ .body = "{}" });
    defer wrong_type.deinit();
    try testing.expectEqual(.unsupported_media_type, wrong_type.status);
}

test "duplicate routes are rejected" {
    var router: zag.Router(void) = .init(testing.allocator, {});
    defer router.deinit();
    try router.get("/", index);
    try testing.expectError(error.DuplicateRoute, router.get("/", index));
}

var order_buffer: [8]u8 = undefined;
var order_len: usize = 0;

fn record(comptime tag: u8) zag.middleware.Middleware {
    return struct {
        fn run(ctx: *zag.Context, next: zag.middleware.Next) anyerror!zag.Response {
            order_buffer[order_len] = tag;
            order_len += 1;
            return next.run(ctx);
        }
    }.run;
}

fn deny(_: *zag.Context, _: zag.middleware.Next) anyerror!zag.Response {
    return error.Unauthorized;
}

test "middleware order, nesting and short-circuit" {
    order_len = 0;
    var api: zag.Router(void) = .init(testing.allocator, {});
    defer api.deinit();
    try api.get("/ping", index);
    try api.layer(record('c'));

    var router: zag.Router(void) = .init(testing.allocator, {});
    defer router.deinit();
    try router.layer(record('a'));
    try router.layer(record('b'));
    try router.nest("/api", &api);

    try expectResponse(&router, .GET, "/api/ping", .ok, "hello");
    try testing.expectEqualStrings("abc", order_buffer[0..order_len]);

    // 404s still run the router's own layers.
    order_len = 0;
    try expectResponse(&router, .GET, "/missing", .not_found, "");
    try testing.expectEqualStrings("ab", order_buffer[0..order_len]);

    try router.layer(deny);
    try expectResponse(&router, .GET, "/api/ping", .unauthorized, "");
}

test "cors" {
    var router: zag.Router(void) = .init(testing.allocator, {});
    defer router.deinit();
    try router.get("/", index);
    try router.layer(zag.middleware.cors(.{}));

    var res = try zag.testing.request(&router, .GET, "/", .{});
    defer res.deinit();
    try testing.expectEqualStrings("*", res.header("access-control-allow-origin").?);

    var preflight = try zag.testing.request(&router, .OPTIONS, "/", .{});
    defer preflight.deinit();
    try testing.expectEqual(.no_content, preflight.status);
}

test "serve over loopback" {
    const io = testing.io;
    var state: AppState = .{ .greeting = "hi" };
    var router = try newRouter(&state);
    defer router.deinit();

    const serve = @import("serve.zig");
    var listener = try serve.listen(io, .{ .port = 0 });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    const shared: serve.Shared = .{ .io = io, .gpa = testing.allocator, .dispatch = .of(&router), .options = .{} };
    var server_task = try io.concurrent(serve.accept, .{ shared, &listener });
    defer server_task.cancel(io) catch {};

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(
        "GET /users/42 HTTP/1.1\r\nhost: x\r\n\r\n" ++
            "POST /users HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\n" ++
            "transfer-encoding: chunked\r\nconnection: close\r\n\r\n" ++
            "5\r\n{\"nam\r\n8\r\ne\":\"bo\"}\r\n0\r\n\r\n",
    );
    try writer.interface.flush();

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const reply = try reader.interface.allocRemaining(testing.allocator, .limited(4096));
    defer testing.allocator.free(reply);

    try testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.find(u8, reply, "{\"id\":42,\"name\":\"ziggy\"}") != null);
    try testing.expect(std.mem.find(u8, reply, "HTTP/1.1 201 Created\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, reply, "created bo"));
}
