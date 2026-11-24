//! The json_api todo service, backed by Postgres instead of memory.
//!
//!   make pg-up                        # a Postgres container on :54329
//!   make run LIB=zag-pg EXAMPLE=todos # this service on :3003
//!
//!   curl -X POST localhost:3003/todos -H 'content-type: application/json' -d '{"title":"write docs"}'
//!   curl localhost:3003/todos
//!   curl -X PATCH localhost:3003/todos/1 -H 'content-type: application/json' -d '{"done":true}'
//!   curl -i -X POST localhost:3003/todos -H 'content-type: application/json' -d '{"title":"write docs"}'  # 409
//!   curl -i -X DELETE localhost:3003/todos/1

const std = @import("std");
const zag = @import("zag-http");
const pg = @import("zag-pg");

const Todo = struct { id: i64, title: []const u8, done: bool };
const NewTodo = struct { title: []const u8 };
const TodoPatch = struct { title: ?[]const u8 = null, done: ?bool = null };

const State = struct { db: pg.Pool };

const schema =
    \\create table if not exists todos (
    \\  id bigint generated always as identity primary key,
    \\  title text not null unique check (length(title) between 1 and 200),
    \\  done boolean not null default false
    \\)
;

fn listTodos(ctx: *zag.Context, state: zag.State(State)) !zag.Response {
    const todos = try state.value.db.query(Todo, ctx.arena, "select id, title, done from todos order by id", .{});
    return .json(ctx.arena, todos);
}

/// No row → `error.NotFound` → 404.
fn getTodo(ctx: *zag.Context, state: zag.State(State), path: zag.Path(struct { id: i64 })) !zag.Json(Todo) {
    return .{ .value = try state.value.db.get(Todo, ctx.arena, "select id, title, done from todos where id = $1", .{path.value.id}) };
}

/// A duplicate title is `error.UniqueViolation` → 409; an empty one fails
/// the check constraint → 422.
fn createTodo(ctx: *zag.Context, state: zag.State(State), body: zag.Json(NewTodo)) !zag.Response {
    const todo = try state.value.db.get(Todo, ctx.arena, "insert into todos (title) values ($1) returning id, title, done", .{body.value.title});
    var res: zag.Response = try .json(ctx.arena, todo);
    res.status = .created;
    return res;
}

/// Fields left out of the body keep their value (`coalesce` with NULL).
fn updateTodo(
    ctx: *zag.Context,
    state: zag.State(State),
    path: zag.Path(struct { id: i64 }),
    body: zag.Json(TodoPatch),
) !zag.Json(Todo) {
    return .{ .value = try state.value.db.get(Todo, ctx.arena,
        \\update todos set title = coalesce($2, title), done = coalesce($3, done)
        \\where id = $1 returning id, title, done
    , .{ path.value.id, body.value.title, body.value.done }) };
}

fn deleteTodo(state: zag.State(State), path: zag.Path(struct { id: i64 })) !void {
    if (try state.value.db.exec("delete from todos where id = $1", .{path.value.id}) == 0) return error.NotFound;
}

pub fn main(init: std.process.Init) !void {
    var state: State = .{ .db = try .init(init.io, init.gpa, .{
        .url = "postgres://zag:zag@127.0.0.1:54329/zag",
        .max_connections = 8,
    }) };
    defer state.db.deinit();
    try state.db.execScript(schema);

    var router: zag.Router(State) = .init(init.gpa, &state);
    defer router.deinit();
    try router.get("/todos", listTodos);
    try router.get("/todos/:id", getTodo);
    try router.post("/todos", createTodo);
    try router.patch("/todos/:id", updateTodo);
    try router.delete("/todos/:id", deleteTodo);
    try router.layer(zag.middleware.logger);

    try zag.serve(init.io, init.gpa, &router, .{ .port = 3003 });
}
