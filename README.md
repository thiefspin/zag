# Zag

[![CI](https://github.com/thiefspin/zag/actions/workflows/ci.yml/badge.svg)](https://github.com/thiefspin/zag/actions/workflows/ci.yml)
[![Docs](https://github.com/thiefspin/zag/actions/workflows/docs.yml/badge.svg)](https://thiefspin.github.io/zag/)
![Zig 0.17.1](https://img.shields.io/badge/zig-0.17.1-f7a41d)

Small, independent Zig libraries for building web services. Use only the ones
you need.

| Library                 | What it is                                                        | Guide |
|-------------------------|-------------------------------------------------------------------|-------|
| [`zag-http`](zag-http)  | HTTP server in the style of Rust's Axum, plus an HTTP client      | [README](zag-http/README.md) · [spec](zag-http/technical_spec.md) |
| [`zag-pg`](zag-pg)      | PostgreSQL client: typed queries, pool, transactions. Pure Zig.   | [README](zag-pg/README.md) · [spec](zag-pg/technical_spec.md) |

API reference: **<https://thiefspin.github.io/zag/>**

```zig
const std = @import("std");
const zag = @import("zag-http");
const pg = @import("zag-pg");

const Todo = struct { id: i64, title: []const u8, done: bool };
const State = struct { db: pg.Pool };

// No row → error.NotFound → 404. Bad id → 400. Database down → 500, logged.
fn getTodo(ctx: *zag.Context, state: zag.State(State), path: zag.Path(struct { id: i64 })) !zag.Json(Todo) {
    return .{ .value = try state.value.db.get(Todo, ctx.arena, "select id, title, done from todos where id = $1", .{path.value.id}) };
}

pub fn main(init: std.process.Init) !void {
    var state: State = .{ .db = try .init(init.io, init.gpa, .{ .url = "postgres://app:secret@localhost/app" }) };
    defer state.db.deinit();

    var router: zag.Router(State) = .init(init.gpa, &state);
    defer router.deinit();
    try router.get("/todos/:id", getTodo);
    try router.layer(zag.middleware.logger);

    try zag.serve(init.io, init.gpa, &router, .{ .port = 3000 });
}
```

## Why Zag

- **Plain functions, typed inputs.** Handlers declare what they need (path
  parameters, query, JSON body, app state) as typed parameters. Mismatches are
  compile errors, not runtime surprises.
- **No memory bookkeeping in handlers.** Each request gets an arena, and
  database rows and client responses are allocated in it.
- **Errors carry meaning across libraries.** A unique-key violation in zag-pg is
  a 409 in zag-http, and a timed-out upstream call is a 504. Internal details are
  logged, never sent to clients.
- **Modular.** Each library is a standalone package with no third-party
  dependencies. You download one repo, and Zig compiles only what you import.
- **Plain Zig.** Built on `std.Io` and `std.crypto`, with explicit allocators
  and no global state or C.

## Install

Requires Zig 0.17.1.

```sh
zig fetch --save git+https://github.com/thiefspin/zag        # latest main
zig fetch --save git+https://github.com/thiefspin/zag#v0.1.0 # a release
```

```zig
// build.zig
const zag = b.dependency("zag", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zag-http", zag.module("zag-http"));
exe.root_module.addImport("zag-pg", zag.module("zag-pg")); // only if you need it
```

## Examples

| Run                                  | What it is |
|--------------------------------------|------------|
| `make run EXAMPLE=hello`             | The smallest server |
| `make run EXAMPLE=json_api`          | In-memory todo API on :3000 |
| `make run EXAMPLE=gateway`           | A service calling `json_api` with `zag.Client` |
| `make run EXAMPLE=client_tour`       | Every HTTP client feature, offline |
| `make pg-up && make run LIB=zag-pg EXAMPLE=todos` | Todo API backed by Postgres on :3003 |

## Repository layout

Each `zag-*` folder is a complete Zig package with its own `build.zig`,
`build.zig.zon`, tests, examples, README and design spec. The root package only
re-exports their modules, so a library could move to its own repo without
changing its code.

```
build.zig         re-exports every library's module; tests and docs for all of them
build.zig.zon     lists each library as a path dependency
Makefile          the commands below
zag-http/         HTTP framework and client
zag-pg/           PostgreSQL client
.github/          CI, docs and release workflows
```

## Development

```sh
make              # list every command
make test         # test every library (OPTIMIZE=ReleaseSafe for release mode)
make pg-up        # Postgres 17 in Docker/Colima for zag-pg's tests (make pg-down to stop)
make check        # format check + tests in Debug and ReleaseSafe, as CI runs
make docs         # API reference into zig-out/docs
make bench        # benchmark zag-http
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the code rules, how CI works, and
how releases are cut. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Status

Pre-1.0: the API may change between minor versions, and the changelog calls
out breaking changes. Known gaps: no TLS in zag-pg yet, and the server speaks
HTTP/1.1 only (run it behind a TLS-terminating proxy). Each library's README
lists its limitations.
