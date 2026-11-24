# zag-http

An HTTP server framework for Zig in the style of Rust's [Axum](https://github.com/tokio-rs/axum),
plus an HTTP client for calling other services.

- **Handlers are plain functions.** Their parameters say what they need from the
  request, and their return type says what they send back.
- **Typed extractors.** Path parameters, query strings and JSON bodies arrive as
  your own structs. Mistakes in the handler signature are compile errors.
- **No manual memory management in handlers.** Each request gets an arena, and
  everything is freed when the response is sent.
- **Errors are statuses.** `return error.NotFound` sends a 404. Unexpected
  errors become a logged 500 and are never shown to the client.
- **Built on `std.Io`.** No hidden threads or global state, and no
  dependencies beyond the standard library.

Requires Zig 0.17.1. See [technical_spec.md](technical_spec.md) for the design.

## Contents

- [Install](#install)
- [Hello, world](#hello-world)
- [Routing](#routing)
- [Handlers](#handlers)
- [Extractors](#extractors)
- [Responses](#responses)
- [Errors](#errors)
- [Shared state](#shared-state)
- [Middleware](#middleware)
- [Serving](#serving)
- [Calling other services: `zag.Client`](#calling-other-services-zagclient)
- [Testing](#testing)
- [Examples](#examples)
- [Performance](#performance)
- [Limitations](#limitations)

## Install

```sh
zig fetch --save git+https://github.com/thiefspin/zag
```

```zig
// build.zig
const zag = b.dependency("zag", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zag-http", zag.module("zag-http"));
```

## Hello, world

```zig
const std = @import("std");
const zag = @import("zag-http");

fn hello() []const u8 {
    return "Hello, world!";
}

fn greet(path: zag.Path(struct { name: []const u8 })) !zag.Json(struct { message: []const u8 }) {
    return .{ .value = .{ .message = path.value.name } };
}

pub fn main(init: std.process.Init) !void {
    var router: zag.Router(void) = .init(init.gpa, {});
    defer router.deinit();

    try router.get("/", hello);
    try router.get("/greet/:name", greet);
    try router.layer(zag.middleware.logger);

    try zag.serve(init.io, init.gpa, &router, .{ .port = 3000 });
}
```

```sh
curl localhost:3000/greet/ada      # {"message":"ada"}
```

## Routing

```zig
var router: zag.Router(AppState) = .init(gpa, &state); // or zag.Router(void) = .init(gpa, {})

try router.get("/users", listUsers);
try router.post("/users", createUser);
try router.get("/users/:id", getUser);          // :id matches one segment
try router.delete("/users/:id", deleteUser);
try router.get("/files/*path", serveFile);      // *path matches the rest of the path
try router.route(.OPTIONS, "/users", options);  // any method
```

- `get`, `post`, `put`, `patch`, `delete` and `route(method, …)` register handlers.
- Patterns are checked at compile time. A wildcard must be the last segment.
- Static segments win over parameters: `/users/me` matches before `/users/:id`.
- Trailing and repeated slashes are ignored: `/users/` matches `/users`.
- A path that matches but with the wrong method gets `405 Method Not Allowed`
  with an `allow` header. `HEAD` requests use the `GET` handler and drop the body.
- Captured values are percent-decoded. A value containing a `..` segment is
  rejected with 400, so `*path` can't escape a directory.

**Nesting** mounts one router's routes under a prefix. The nested router's
middleware applies only to its own routes:

```zig
var api: zag.Router(AppState) = .init(gpa, &state);
try api.get("/users", listUsers);            // becomes /api/v1/users
try api.layer(requireApiKey);

try router.nest("/api/v1", &api);
```

**Fallback** replaces the default 404 for unmatched paths:

```zig
router.fallback(notFoundPage);
```

## Handlers

A handler is any function whose parameters are extractors, optionally
`*zag.Context`, in any order. It returns a response type, or an error union of
one:

```zig
fn getUser(
    ctx: *zag.Context,                         // the request, the arena, io
    state: zag.State(AppState),                // shared app state
    path: zag.Path(struct { id: u64 }),        // /users/:id
    query: zag.Query(struct { fields: ?[]const u8 = null }),
) !zag.Json(User) { ... }
```

`zag.Context` gives you:

| Field           | Type                 |                                             |
|-----------------|----------------------|---------------------------------------------|
| `ctx.request`   | `zag.Request`        | `method`, `path`, `query`, `headers`, `body`, `header(name)` |
| `ctx.arena`     | `std.mem.Allocator`  | Freed after the response is sent            |
| `ctx.io`        | `std.Io`             | For sleeping, locking, calling other services |

The whole request body is read before your handler runs (up to `max_body_size`),
so handlers never deal with partial bodies.

## Extractors

| Extractor                 | Gives you                                   | Fails with |
|---------------------------|---------------------------------------------|------------|
| `zag.Path(T)`             | Path parameters as struct `T`               | 400 |
| `zag.Query(T)`            | Query string as struct `T`                  | 400 |
| `zag.Json(T)`             | JSON body as `T`, ignoring unknown fields   | 415 if not `application/json`, 400 if malformed |
| `zag.State(T)`            | `*T`, the router's state (`state.value`)    | compile error if `T` isn't the router's state type |
| `zag.Headers`             | `headers.get(name)`, case-insensitive       | — |
| `zag.Body`                | `body.bytes`, the raw body                  | — |

`Path` and `Query` fields can be integers, floats, `bool`, enums (by name),
`[]const u8`, or optionals of these. A missing field uses its default value,
then `null` if it is optional, and otherwise fails with 400:

```zig
const Page = struct { page: u32 = 1, per_page: u32 = 20, search: ?[]const u8 = null };

fn list(query: zag.Query(Page)) ... // /items?page=2&search=zig%20http
```

**Custom extractors** are any type with `pub fn extract(ctx: *zag.Context) !@This()`.
Errors they return become statuses the same way handler errors do:

```zig
const ApiUser = struct {
    token: []const u8,

    pub fn extract(ctx: *zag.Context) !ApiUser {
        const value = ctx.request.header("authorization") orelse return error.Unauthorized;
        if (!std.mem.startsWith(u8, value, "Bearer ")) return error.Unauthorized;
        return .{ .token = value["Bearer ".len..] };
    }
};

fn me(user: ApiUser) []const u8 {
    return user.token;
}
```

## Responses

| Return type                 | Sends                                         |
|-----------------------------|-----------------------------------------------|
| `[]const u8` / string literal | 200, `text/plain; charset=utf-8`            |
| `zag.Json(T)`               | 200, JSON                                     |
| `void`                      | 204 No Content                                |
| `std.http.Status`           | that status, empty body                       |
| `zag.Response`              | exactly what you build                        |
| any type with `pub fn toResponse(self, ctx: *zag.Context) !zag.Response` | whatever it returns |

```zig
fn create(ctx: *zag.Context, body: zag.Json(NewUser)) !zag.Response {
    const user = try save(body.value);
    var res: zag.Response = try .json(ctx.arena, user);
    res.status = .created;
    res.headers = try ctx.arena.dupe(std.http.Header, &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "location", .value = try std.fmt.allocPrint(ctx.arena, "/users/{d}", .{user.id}) },
    });
    return res;
}
```

Constructors: `zag.Response.text(body)`, `.json(arena, value)`, `.empty(status)`.

The response is sent after your handler returns, so its body and headers must
not point at the handler's stack. Allocate them in `ctx.arena`, as above, or
use comptime-known values. `res.headers = &.{ … }` with a runtime value is a
dangling pointer, and assigning `headers` replaces the `content-type` set by
`.json`.

## Errors

Return an error and zag picks the status:

| Error                                                   | Status |
|---------------------------------------------------------|--------|
| `MissingParam`, `InvalidParam`, `MalformedBody`         | 400 |
| `Unauthorized`                                          | 401 |
| `Forbidden`                                             | 403 |
| `NotFound`                                              | 404 |
| `PayloadTooLarge`                                       | 413 |
| `UnsupportedMediaType`                                  | 415 |
| `UniqueViolation`, `ForeignKeyViolation` (zag-pg)       | 409 |
| `ConstraintViolation` (zag-pg)                          | 422 |
| `UpstreamStatus`, `UpstreamUnavailable`, `UpstreamInvalidResponse`, `ResponseTooLarge` (zag.Client) | 502 |
| `Canceled` (shutting down), `SerializationFailure`, `PoolTimeout` (zag-pg) | 503 |
| `Timeout` (zag.Client), `QueryTimeout` (zag-pg)          | 504 |
| anything else                                           | 500, error name logged with `std.log.err` |

Error bodies are empty. To send a body with an error status, return a
`zag.Response` instead.

## Shared state

The router owns no state; it holds a pointer to yours. Handlers get it with
`zag.State(T)`. State is shared by every connection, so protect mutable fields
with a `std.Io.Mutex`:

```zig
const AppState = struct {
    mutex: std.Io.Mutex = .init,
    hits: u64 = 0,
};

fn count(ctx: *zag.Context, state: zag.State(AppState)) !zag.Response {
    try state.value.mutex.lock(ctx.io);
    defer state.value.mutex.unlock(ctx.io);
    state.value.hits += 1;
    return .text(try std.fmt.allocPrint(ctx.arena, "{d}", .{state.value.hits}));
}

var state: AppState = .{};
var router: zag.Router(AppState) = .init(gpa, &state);
```

Things that are already threadsafe, like `zag.Client` or a `zag-pg` `Pool`, can
sit in state without a mutex.

## Middleware

A middleware is `fn (ctx: *zag.Context, next: zag.middleware.Next) anyerror!zag.Response`.
Call `next.run(ctx)` to continue, or return early:

```zig
fn requireApiKey(ctx: *zag.Context, next: zag.middleware.Next) anyerror!zag.Response {
    const key = ctx.request.header("x-api-key") orelse return .empty(.unauthorized);
    if (!std.mem.eql(u8, key, "let-me-in")) return .empty(.forbidden);
    return next.run(ctx);
}

try router.layer(zag.middleware.logger);          // first added = outermost
try router.layer(zag.middleware.cors(.{ .origin = "https://example.com" }));
try router.layer(requireApiKey);
```

Layers wrap every request to the router, including 404s and 405s.

Built-in:
- `zag.middleware.logger` logs `METHOD /path status duration` at info level.
- `zag.middleware.cors(options)` adds CORS headers and answers preflight
  `OPTIONS` requests. The options are `origin`, `methods` and `headers`.

## Serving

```zig
try zag.serve(io, gpa, &router, .{
    .address = "0.0.0.0",          // default 127.0.0.1
    .port = 8080,                  // default 3000; 0 picks a free port
    .max_body_size = 4 << 20,      // default 1 MiB; larger bodies get 413
    .read_buffer_size = 16 << 10,  // also the request-head limit; larger heads get 431
    .keep_alive = true,
});
```

`serve` runs until the task calling it is canceled. Each connection runs as its
own concurrent task on `io`. To shut down cleanly, run `serve` in a task and
cancel it. Open connections are canceled, and in-flight handlers see
`error.Canceled`.

## Calling other services: `zag.Client`

One client per app, shared by all handlers. It is threadsafe and reuses
connections.

```zig
var client: zag.Client = .init(io, gpa, .{
    .base_url = "https://api.example.com",
    .headers = &.{.{ .name = "authorization", .value = "Bearer …" }},
    .timeout = .fromSeconds(5),                        // default 30s, per attempt
    .retry = .{ .max_attempts = 3 },                   // default
});
defer client.deinit();
```

**JSON helpers.** A non-2xx status becomes an error, which a handler can return
directly (see [Errors](#errors)):

```zig
const user = try client.getJson(User, ctx.arena, "/users/7");
const created = try client.postJson(User, ctx.arena, "/users", NewUser{ .name = "ada" });
```

**Full control** with `send`, which returns any status without treating it as
an error:

```zig
const res = try client.send(ctx.arena, .{
    .method = .GET,
    .url = "/search",
    .query = &.{.{ .name = "q", .value = "zig & http" }},   // encoded for you
    .headers = &.{.{ .name = "x-request-id", .value = id }},
    .timeout = .fromMilliseconds(500),                     // per-request override
});
try res.expectSuccess();               // or check res.status yourself
const page = try res.json(Page, ctx.arena);
```

**Request bodies:**

```zig
.body = try .json(ctx.arena, value),                                         // application/json
.body = .{ .bytes = .{ .data = csv, .content_type = "text/csv" } },
.body = .{ .form = &.{.{ .name = "user", .value = "ada" }} },               // urlencoded
.body = .{ .multipart = &.{
    .{ .name = "title", .data = .{ .bytes = "Report" } },
    .{ .name = "file", .filename = "report.pdf", .content_type = "application/pdf", .data = .{ .reader = &file_reader } },
} },
.body = .{ .stream = .{ .reader = &reader, .content_type = "application/octet-stream" } },  // chunked
```

**Streaming downloads**, without buffering the whole body:

```zig
var download = try client.stream(.{ .url = "/exports/big.csv" });
defer download.deinit();
const reader = try download.reader();
// read from `reader` in chunks...
```

**Retries** use exponential backoff with jitter and respect `Retry-After`. Only
safe requests are retried by default: idempotent methods, on connection
errors, timeouts, 429, 502, 503 and 504. A POST is retried only if you set
`.retry = .{ .retry_non_idempotent = true }`, and never with a streamed body.

**Redirects** are followed (up to `max_redirects`, default 3) for requests
without a body or credentials. A request with an `authorization` header is
never redirected, so the token can't leak to another host.

**Limits.** Responses over `max_response_size` (default 10 MiB) fail with
`error.ResponseTooLarge`; use `stream` for large downloads.

## Testing

`zag.testing.request` runs one request through a router in-process, using
`std.testing.allocator` so leaks fail the test:

```zig
test "get user" {
    var router = try buildRouter(std.testing.allocator);
    defer router.deinit();

    var res = try zag.testing.request(&router, .GET, "/users/7", .{});
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("application/json", res.header("content-type").?);
}

// With a body:
var res = try zag.testing.request(&router, .POST, "/users", .{
    .headers = &.{.{ .name = "content-type", .value = "application/json" }},
    .body = "{\"name\":\"ada\"}",
});
```

`zag.testing.serve(&router)` starts a real server on a free port. Use it to test
code that makes HTTP calls, such as a `zag.Client`:

```zig
const server = try zag.testing.serve(&fake_upstream);
defer server.deinit();
var client: zag.Client = .init(std.testing.io, std.testing.allocator, .{ .base_url = server.url });
```

## Examples

In [`examples/`](examples); run with `make run EXAMPLE=<name>` from the repo root.

| Example        | Shows |
|----------------|-------|
| `hello`        | The smallest server |
| `json_api`     | A todo API on :3000: state with a mutex, JSON in and out, logger and CORS |
| `gateway`      | A service on :3001 calling `json_api` with `zag.Client`, and how upstream errors map to 404/502/504 |
| `client_tour`  | Every client feature against an in-process fake service; runs offline |

## Performance

`make bench` runs a closed-loop load test against an in-process server. On an
Apple M-series laptop, simple routes do about 160–200k requests/s over 32
keep-alive connections, which is limited by the load generator. Memory is
about 50 KB per open connection.

Build with `-Doptimize=ReleaseFast` or `ReleaseSafe` for real deployments.
Debug builds use a safety allocator that never reuses memory, so their RSS
keeps growing.

## Limitations

- HTTP/1.1 only. There is no TLS in the server; put it behind a reverse proxy
  such as Caddy or nginx.
- Request bodies are read fully before the handler runs. No streaming uploads
  to handlers yet.
- No WebSockets or server-sent events yet.
- The client's timeout costs about 9 µs per request, because it uses a
  concurrent timer task.
