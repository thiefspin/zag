# zag-pg

A PostgreSQL client for Zig, written from scratch against the Postgres wire
protocol. No libpq and no C.

- **Typed queries.** Rows decode into your structs by column name, and arguments
  are plain Zig values.
- **Injection-safe by default.** Every query with arguments sends them
  separately from the SQL, as `$1`, `$2`, ….
- **A pool you don't think about.** It is threadsafe, connects lazily and
  replaces broken connections. Rolling back abandoned transactions is
  automatic.
- **Errors that mean something.** A duplicate key is `error.UniqueViolation`.
  Return it from a [zag-http](../zag-http) handler and the client gets a 409.
- **Pure Zig on `std.Io`.** SCRAM-SHA-256 and MD5 authentication use
  `std.crypto`.

Requires Zig 0.17.1 and PostgreSQL 13 or newer (tested on 17). See
[technical_spec.md](technical_spec.md) for the design.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Connecting](#connecting)
- [Queries](#queries)
- [Arguments](#arguments)
- [Decoding rows](#decoding-rows)
- [Transactions](#transactions)
- [Errors](#errors)
- [Using a connection directly](#using-a-connection-directly)
- [With zag-http](#with-zag-http)
- [Memory](#memory)
- [Running the tests](#running-the-tests)
- [Limitations](#limitations)

## Install

```sh
zig fetch --save git+https://github.com/thiefspin/zag
```

```zig
// build.zig
const zag = b.dependency("zag", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zag-pg", zag.module("zag-pg"));
```

## Quick start

```zig
const std = @import("std");
const pg = @import("zag-pg");

const User = struct { id: i64, name: []const u8, email: ?[]const u8 };

pub fn main(init: std.process.Init) !void {
    var pool: pg.Pool = try .init(init.io, init.gpa, .{
        .url = "postgres://app:secret@localhost:5432/app",
    });
    defer pool.deinit();

    const arena = init.arena.allocator();
    try pool.execScript("create table if not exists users (id bigint primary key, name text not null, email text)");
    _ = try pool.exec("insert into users values ($1, $2, $3) on conflict do nothing", .{ 1, "ada", "ada@example.com" });

    const users = try pool.query(User, arena, "select id, name, email from users order by id", .{});
    for (users) |u| std.debug.print("{d}: {s}\n", .{ u.id, u.name });
}
```

## Connecting

Create one `Pool` for the whole app. `init` doesn't connect; the first query
does.

```zig
var pool: pg.Pool = try .init(io, gpa, .{
    .url = "postgres://user:password@host:5432/database?application_name=api",
    .max_connections = 10,                     // default 10
    .acquire_timeout = .fromSeconds(5),        // how long to wait for a free connection
});
defer pool.deinit();
```

Or pass a `pg.Config` instead of a URL:

```zig
var pool: pg.Pool = try .init(io, gpa, .{ .config = .{
    .host = "db.internal",
    .port = 5432,
    .user = "api",
    .password = password,                      // from your secret store
    .database = "app",                         // default: same as user
    .statement_timeout = .fromSeconds(10),     // default 30s; null = server default
    .connect_timeout = .fromSeconds(5),        // default 10s
} });
```

URL notes: percent-encode special characters in the password (`p%40ss` for
`p@ss`). Both `postgres://` and `postgresql://` work. `sslmode=disable`,
`prefer` and `allow` are accepted, but TLS isn't implemented yet, so
`sslmode=require` is rejected rather than silently ignored.

**Authentication.** SCRAM-SHA-256, the default since Postgres 14, and MD5 work
automatically. Cleartext password auth is refused unless you set
`.allow_cleartext_password = true`, because it sends your password as-is.

## Queries

| Function                            | Returns  |                                             |
|-------------------------------------|----------|---------------------------------------------|
| `query(T, arena, sql, args)`        | `[]T`    | Every row                                   |
| `queryOne(T, arena, sql, args)`     | `?T`     | The first row, or `null`                    |
| `get(T, arena, sql, args)`          | `T`      | The first row, or `error.NotFound`          |
| `exec(sql, args)`                   | `u64`    | Rows affected (`INSERT`/`UPDATE`/`DELETE`)  |
| `execScript(sql)`                   | `void`   | Several statements, no arguments            |

They exist on `Pool`, `Tx` and `Conn` alike. `args` is a tuple; use `.{}` for none.

```zig
const user = try pool.get(User, arena, "select id, name, email from users where id = $1", .{id});
const maybe = try pool.queryOne(User, arena, "select id, name, email from users where email = $1", .{email});
const n = try pool.exec("update users set name = $1 where id = $2", .{ "grace", id });

// RETURNING works with get/query:
const created = try pool.get(User, arena,
    "insert into users (id, name) values ($1, $2) returning id, name, email",
    .{ 2, "grace" });
```

`execScript` uses Postgres's simple protocol, which allows several statements
but no arguments. Use it for migrations and setup. **Never build its SQL from
user input.**

## Arguments

| Zig type                          | Sent as                         |
|-----------------------------------|---------------------------------|
| integers, floats                  | decimal text                    |
| `bool`                            | `t` / `f`                       |
| `[]const u8`, string literals     | as-is                           |
| enums                             | the tag name                    |
| `?T`, `null`                      | `NULL` when null                |
| `pg.Json(T)`                      | JSON (`std.json`)               |

Postgres infers each argument's type from the query. Add a cast where it can't,
for example `$1::int8` or `$1::jsonb`. An unsupported argument type is a
compile error that names its position.

```zig
const Prefs = struct { theme: []const u8 };
_ = try pool.exec("update users set prefs = $1 where id = $2", .{ pg.Json(Prefs){ .value = .{ .theme = "dark" } }, id });
```

## Decoding rows

Each field of `T` is filled from the column **with the same name**. Rename
columns with `as` when needed:

```zig
const Summary = struct { total: i64, newest: ?[]const u8 };
const s = try pool.get(Summary, arena, "select count(*) as total, max(name) as newest from users", .{});
```

- Field types: integers, floats, `bool`, `[]const u8`, enums (by tag name),
  `pg.Json(T)` (for `json`/`jsonb`), and optionals of these.
- `bytea` columns decode to raw bytes in `[]const u8` fields.
- Extra columns are ignored.
- A field with no matching column uses its default value, or fails with
  `error.ColumnMissing`.
- `NULL` into a non-optional field fails with `error.UnexpectedNull`.
- Text that doesn't parse, such as `"abc"` into an `i64`, fails with
  `error.InvalidValue`.
- `numeric`, dates and times aren't native types yet. Read them as
  `[]const u8`, or cast in SQL (`extract(epoch from created_at)::int8`).

## Transactions

```zig
var tx = try pool.begin();
defer tx.deinit();          // rolls back unless committed, then returns the connection

_ = try tx.exec("update accounts set balance = balance - $1 where id = $2", .{ amount, from });
_ = try tx.exec("update accounts set balance = balance + $1 where id = $2", .{ amount, to });
try tx.commit();
```

If any statement fails, every `try` returns early and `deinit` rolls back.
Calling `commit` after a failed statement returns `error.TransactionAborted`.
Postgres itself would answer such a `COMMIT` with a silent rollback.

On `error.SerializationFailure` (a serialization conflict or deadlock), the
whole transaction is safe to retry.

## Errors

| Error                     | When                                          | zag-http status |
|---------------------------|-----------------------------------------------|-----------------|
| `UniqueViolation`         | SQLSTATE 23505                                | 409 |
| `ForeignKeyViolation`     | 23503                                         | 409 |
| `ConstraintViolation`     | 23502 not null, 23514 check, 23P01 exclusion  | 422 |
| `SerializationFailure`    | 40001, 40P01; retry the transaction           | 503 |
| `QueryTimeout`            | 57014, including `statement_timeout`          | 504 |
| `QueryFailed`             | any other server error                        | 500 |
| `NotFound`                | `get` found no row                            | 404 |
| `PoolTimeout`             | no connection free within `acquire_timeout`   | 503 |
| `ConnectionFailed`        | can't connect, or the connection broke        | 500 |
| `AuthenticationFailed`    | wrong credentials or unsupported auth method  | 500 |
| `ColumnMissing`, `UnexpectedNull`, `InvalidValue` | row doesn't fit `T` | 500 |

The server's message, detail, hint and constraint name are logged at debug
level (`std.log` scope `zag_pg`). They are also available as `conn.last_error`
when you use a connection directly. They are never put in HTTP responses.

A query error leaves the connection usable. An I/O or protocol error marks it
broken. The pool then closes it and opens a fresh one next time.

## Using a connection directly

For several statements on the same session, borrow a connection, for example
to use `SET` or temporary tables:

```zig
const conn = try pool.acquire();
defer pool.release(conn);

try conn.execScript("set search_path = public; create temp table scratch (n int)");
_ = conn.exec("insert into scratch values ($1)", .{1}) catch |err| {
    if (conn.last_error) |d| std.log.warn("{s}: {s}", .{ d.code, d.message });
    return err;
};
```

`release` rolls back any transaction left open on the connection.

## With zag-http

Put the pool in your router state and `try` queries straight from handlers.
The errors above become the right statuses:

```zig
const State = struct { db: pg.Pool };

fn getTodo(ctx: *zag.Context, state: zag.State(State), path: zag.Path(struct { id: i64 })) !zag.Json(Todo) {
    return .{ .value = try state.value.db.get(Todo, ctx.arena, "select id, title, done from todos where id = $1", .{path.value.id}) };
}
```

The full service is [`examples/todos.zig`](examples/todos.zig):

```sh
make pg-up                          # Postgres in Docker/Colima on :54329
make run LIB=zag-pg EXAMPLE=todos   # the API on :3003
```

## Memory

| Lifetime     | Allocator         | Holds                                   |
|--------------|-------------------|-----------------------------------------|
| Pool         | `gpa`             | Connections, parsed config              |
| Connection   | `gpa`, reused     | 24 KiB of I/O buffers, message scratch  |
| Query result | your `arena`      | The returned rows and their strings     |

Rows are copied into your arena, so they stay valid after the connection goes
back to the pool. In a zag-http handler, pass `ctx.arena` and never free
anything.

## Running the tests

```sh
make pg-up      # Postgres 17 on :54329, with extra users for MD5 and cleartext auth
make test
make pg-down
```

The integration tests read `ZAG_PG_TEST_URL` (default
`postgres://zag:zag@127.0.0.1:54329/zag`). Without a running database they skip.
With `ZAG_PG_REQUIRE=1`, as CI sets it, they fail instead.

## Limitations

- **No TLS yet.** Connect over localhost, a private network, or a tunnel.
- Results are buffered: `query` holds every row in memory. Use `LIMIT` and
  paging for large tables.
- No prepared-statement cache yet: each query is parsed by the server.
- No `LISTEN/NOTIFY`, `COPY`, pipelining or binary format.
- No native `numeric`, date/time or array types.
