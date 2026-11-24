//! A small in-memory JSON API with shared state.
//!
//!   zig build run-example -Dexample=json_api
//!   curl -X POST localhost:3000/todos -H 'content-type: application/json' -d '{"title":"write docs"}'
//!   curl localhost:3000/todos/1

const std = @import("std");
const zag = @import("zag-http");

const Todo = struct {
    id: u32,
    title: []const u8,
    done: bool = false,
};

/// Shared by all connections, so every access holds `mutex`.
const AppState = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    todos: std.ArrayList(Todo) = .empty,

    fn deinit(self: *AppState) void {
        for (self.todos.items) |todo| self.gpa.free(todo.title);
        self.todos.deinit(self.gpa);
    }
};

const NewTodo = struct { title: []const u8 };

fn listTodos(ctx: *zag.Context, state: zag.State(AppState)) !zag.Response {
    try state.value.mutex.lock(ctx.io);
    defer state.value.mutex.unlock(ctx.io);
    return .json(ctx.arena, state.value.todos.items);
}

fn getTodo(
    ctx: *zag.Context,
    state: zag.State(AppState),
    path: zag.Path(struct { id: u32 }),
) !zag.Response {
    try state.value.mutex.lock(ctx.io);
    defer state.value.mutex.unlock(ctx.io);
    for (state.value.todos.items) |todo| {
        if (todo.id == path.value.id) return .json(ctx.arena, todo);
    }
    return error.NotFound;
}

fn createTodo(
    ctx: *zag.Context,
    state: zag.State(AppState),
    body: zag.Json(NewTodo),
) !zag.Response {
    const app = state.value;
    // The body lives in the request arena; copy it into long-lived memory.
    const title = try app.gpa.dupe(u8, body.value.title);
    errdefer app.gpa.free(title);

    try app.mutex.lock(ctx.io);
    defer app.mutex.unlock(ctx.io);
    const todo: Todo = .{ .id = @intCast(app.todos.items.len + 1), .title = title };
    try app.todos.append(app.gpa, todo);

    var res: zag.Response = try .json(ctx.arena, todo);
    res.status = .created;
    return res;
}

pub fn main(init: std.process.Init) !void {
    var state: AppState = .{ .gpa = init.gpa };
    defer state.deinit();

    var router: zag.Router(AppState) = .init(init.gpa, &state);
    defer router.deinit();

    try router.get("/todos", listTodos);
    try router.get("/todos/:id", getTodo);
    try router.post("/todos", createTodo);
    try router.layer(zag.middleware.logger);
    try router.layer(zag.middleware.cors(.{}));

    try zag.serve(init.io, init.gpa, &router, .{ .port = 3000 });
}
