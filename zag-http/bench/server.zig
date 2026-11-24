//! Benchmark server: one route per scenario. Started by `bench/run.zig`.
//! Usage: bench-server <port>

const std = @import("std");
const zag = @import("zag-http");

const Element = struct { name: []const u8, number: u32, group: u32 };

const State = struct {
    /// Points at this same server, which calls itself to simulate a backend
    /// (like a database or another service).
    client: zag.Client,
    /// ~6 KB JSON object keyed by element symbol, served at /source/elements.json.
    elements_json: []const u8,
};

fn plaintext() []const u8 {
    return "Hello, World!";
}

fn json() zag.Json(struct { message: []const u8 }) {
    return .{ .value = .{ .message = "Hello, World!" } };
}

fn params(
    path: zag.Path(struct { id: u64, post: []const u8 }),
    query: zag.Query(struct { limit: u32 = 10 }),
) zag.Json(struct { id: u64, post: []const u8, limit: u32 }) {
    return .{ .value = .{ .id = path.value.id, .post = path.value.post, .limit = query.value.limit } };
}

const Echo = struct { name: []const u8, tags: []const []const u8, count: u32 };

fn echo(body: zag.Json(Echo)) zag.Json(Echo) {
    return body;
}

fn source(state: zag.State(State)) zag.Response {
    return .{
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = state.value.elements_json,
    };
}

/// Fetches the element table from the backend, then returns one element.
fn element(
    ctx: *zag.Context,
    state: zag.State(State),
    query: zag.Query(struct { symbol: []const u8 }),
) !zag.Json(Element) {
    const table = try state.value.client.getJson(std.json.ArrayHashMap(Element), ctx.arena, "/source/elements.json");
    const found = table.map.get(query.value.symbol) orelse return error.NotFound;
    return .{ .value = found };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const port = try std.fmt.parseInt(u16, args[1], 10);

    const base_url = try std.fmt.allocPrint(init.arena.allocator(), "http://127.0.0.1:{d}", .{port});
    var state: State = .{
        .client = .init(init.io, gpa, .{ .base_url = base_url }),
        .elements_json = try buildElements(init.arena.allocator()),
    };
    defer state.client.deinit();

    var router: zag.Router(State) = .init(gpa, &state);
    defer router.deinit();
    try router.get("/plaintext", plaintext);
    try router.get("/json", json);
    try router.get("/users/:id/posts/:post", params);
    try router.post("/echo", echo);
    try router.get("/source/elements.json", source);
    try router.get("/element", element);

    try zag.serve(init.io, gpa, &router, .{ .port = port });
}

/// Builds a periodic-table-shaped JSON object with 118 entries.
fn buildElements(arena: std.mem.Allocator) ![]const u8 {
    var table: std.json.ArrayHashMap(Element) = .{};
    try table.map.put(arena, "He", .{ .name = "Helium", .number = 2, .group = 18 });
    for (3..119) |n| {
        const symbol = try std.fmt.allocPrint(arena, "E{d}", .{n});
        const name = try std.fmt.allocPrint(arena, "Element{d}", .{n});
        try table.map.put(arena, symbol, .{ .name = name, .number = @intCast(n), .group = @intCast(n % 18 + 1) });
    }
    return std.json.Stringify.valueAlloc(arena, table, .{});
}
