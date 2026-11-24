//! A service that calls another service: a small "gateway" in front of the
//! json_api example. Shows `zag.Client` in router state and how upstream
//! errors turn into sensible responses.
//!
//!   make run EXAMPLE=json_api      # terminal 1: the upstream on :3000
//!   make run EXAMPLE=gateway       # terminal 2: this gateway on :3001
//!
//!   curl -X POST localhost:3001/todos -H 'content-type: application/json' -d '{"title":"write docs"}'
//!   curl localhost:3001/summary
//!   curl -i localhost:3001/todos/99   # upstream 404 -> 404
//!   # stop json_api, then:
//!   curl -i localhost:3001/summary    # upstream down -> 502 (after retries)

const std = @import("std");
const zag = @import("zag-http");

const Todo = struct { id: u32, title: []const u8, done: bool };
const NewTodo = struct { title: []const u8 };

const Summary = struct {
    total: usize,
    done: usize,
    titles: []const []const u8,
};

/// One client for the whole app, so connections to the upstream are reused.
const State = struct { upstream: zag.Client };

/// Calls the upstream and reshapes its answer.
fn summary(ctx: *zag.Context, state: zag.State(State)) !zag.Json(Summary) {
    const todos = try state.value.upstream.getJson([]const Todo, ctx.arena, "/todos");

    const titles = try ctx.arena.alloc([]const u8, todos.len);
    var done: usize = 0;
    for (todos, titles) |todo, *title| {
        title.* = todo.title;
        if (todo.done) done += 1;
    }
    return .{ .value = .{ .total = todos.len, .done = done, .titles = titles } };
}

/// An upstream 404 comes back as `error.NotFound`, which zag turns into a 404.
fn getTodo(
    ctx: *zag.Context,
    state: zag.State(State),
    path: zag.Path(struct { id: u32 }),
) !zag.Json(Todo) {
    const target = try std.fmt.allocPrint(ctx.arena, "/todos/{d}", .{path.value.id});
    return .{ .value = try state.value.upstream.getJson(Todo, ctx.arena, target) };
}

/// Forwards the body. POST is not retried, so a todo is never created twice.
fn createTodo(ctx: *zag.Context, state: zag.State(State), body: zag.Json(NewTodo)) !zag.Response {
    const todo = try state.value.upstream.postJson(Todo, ctx.arena, "/todos", body.value);
    var res: zag.Response = try .json(ctx.arena, todo);
    res.status = .created;
    return res;
}

pub fn main(init: std.process.Init) !void {
    var state: State = .{ .upstream = .init(init.io, init.gpa, .{
        .base_url = "http://127.0.0.1:3000",
        .headers = &.{.{ .name = "x-forwarded-by", .value = "zag-gateway" }},
        .timeout = .fromSeconds(2),
        .retry = .{ .max_attempts = 3, .base_delay = .fromMilliseconds(50) },
    }) };
    defer state.upstream.deinit();

    var router: zag.Router(State) = .init(init.gpa, &state);
    defer router.deinit();
    try router.get("/summary", summary);
    try router.get("/todos/:id", getTodo);
    try router.post("/todos", createTodo);
    try router.layer(zag.middleware.logger);

    try zag.serve(init.io, init.gpa, &router, .{ .port = 3001 });
}
