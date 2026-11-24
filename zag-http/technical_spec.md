# Zag — Technical Specification

> Status: draft v0.1 · Target: Zig 0.17.1 (`minimum_zig_version` in `build.zig.zon`)

Zag is an HTTP framework for Zig inspired by Rust's [Axum](https://github.com/tokio-rs/axum):
handlers are plain functions, request data is pulled in through typed **extractors**,
return values are turned into responses, and cross-cutting behaviour is added with
**middleware layers**. Zag uses Zig's comptime where Axum uses traits.

---

## 1. Goals and Non-Goals

### Goals

1. **Plain-function handlers.** A handler is a normal `fn`. Its parameter types say what
   it needs from the request. Its return type says how to respond.
2. **Type-safe extraction.** Path params, query strings, JSON bodies and shared state are
   parsed into Zig types at the edge. Handlers never parse raw bytes.
3. **Explicit resources.** No hidden allocations, no globals. Allocators and `std.Io`
   are passed in. Every request has its own arena.
4. **Built on `std`.** Use `std.http.Server` for HTTP/1.1 parsing and `std.Io` for
   networking and concurrency. Zero third-party dependencies in v1.
5. **Low cognitive complexity.** Anyone who knows Zig should be able to read any file in
   one pass. See §9.
6. **Testable without sockets.** Routers can be driven from in-memory requests.

### Non-Goals (v1)

- HTTP/2, HTTP/3
- TLS termination (run behind a reverse proxy)
- Templating, ORM, sessions, or other "full-stack" features
- Supporting Zig versions older than 0.17

---

## 2. Example: Target Developer Experience

This is the API we design toward. Exact signatures may change during implementation.

```zig
const std = @import("std");
const zag = @import("zag-http");

const AppState = struct {
    greeting: []const u8,
};

const User = struct {
    id: u64,
    name: []const u8,
};

fn index() []const u8 {
    return "hello from zag";
}

fn getUser(path: zag.Path(struct { id: u64 })) zag.Json(User) {
    return .{ .value = .{ .id = path.value.id, .name = "ziggy" } };
}

const CreateUser = struct { name: []const u8 };

fn createUser(
    state: zag.State(AppState),
    body: zag.Json(CreateUser),
) !zag.Response {
    std.log.info("{s}, {s}", .{ state.value.greeting, body.value.name });
    return .empty(.created);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var state: AppState = .{ .greeting = "hi" };

    var router: zag.Router(AppState) = .init(gpa, &state);
    defer router.deinit();

    try router.get("/", index);
    try router.get("/users/:id", getUser);
    try router.post("/users", createUser);
    try router.layer(zag.middleware.logger);

    try zag.serve(init.io, gpa, &router, .{ .port = 3000 });
}
```

Runnable versions live in `examples/` (`zig build run-example -Dexample=json_api`).

---

## 3. Architecture

```
          ┌──────────────┐  accept   ┌────────────────┐
 TCP ───▶ │  zag.serve   │ ────────▶ │ connection task│  (one per connection, Io.Group)
          └──────────────┘           └───────┬────────┘
                                             │ std.http.Server.receiveHead
                                             ▼
                                     ┌────────────────┐
                                     │   Request +    │  per-request arena
                                     │    Context     │
                                     └───────┬────────┘
                                             ▼
                                     ┌────────────────┐
                                     │ middleware     │  outer → inner
                                     │ chain          │
                                     └───────┬────────┘
                                             ▼
                                     ┌────────────────┐
                                     │ Router.match   │  method + path → Route
                                     └───────┬────────┘
                                             ▼
                                     ┌────────────────┐
                                     │ erased handler │  comptime-generated:
                                     │ (extract → call│  extract args, call user fn,
                                     │  → respond)    │  convert return value
                                     └───────┬────────┘
                                             ▼
                                        Response → writer → flush
```

### 3.1 Module Layout

One concern per file. Files that define one main type use `TitleCase.zig` and are the
type themselves (Zig's file-as-struct convention).

```
src/
  root.zig            Public API. Only re-exports; no logic.
  serve.zig           Listener, accept loop, one task per connection.
  Connection.zig      Keep-alive loop for one connection; reads the full request.
  Request.zig         A fully-read request (method, path, query, headers, body).
  Context.zig         Per-request data: request, arena, io, params, state pointer.
  router.zig          Router(S): registration, matching, dispatch.
  path.zig            Path pattern validation and matching (pure functions).
  handler.zig         Comptime handler erasure (the only "clever" file).
  Response.zig        Response type and builders.
  respond.zig         Return values and errors → Response.
  extract.zig         Built-in extractors.
  fields.zig          Flat struct from name/value pairs (used by Path, Query).
  middleware.zig      Middleware, Next, logger, cors.
  client/
    Client.zig        zag.Client: options, requests, responses, timeouts, retry loop.
    Stream.zig        Streaming responses.
    body.zig          Request bodies: bytes, JSON, form, multipart, stream.
    retry.zig         Retry policy (pure).
    url.zig           URL joining and query encoding (pure).
    tests.zig         Client tests against a real loopback server.
  testing.zig         Drive a router in tests; run one on a loopback port.
  tests.zig           End-to-end tests of the public API.
examples/
  hello.zig
  json_api.zig
```

### 3.2 Public API Surface (`root.zig`)

Keep it small. Anything not re-exported here is internal.

| Name               | Kind     | Purpose                                     |
|--------------------|----------|---------------------------------------------|
| `serve`            | fn       | Run a router on a TCP address               |
| `ServeOptions`     | type     | Address, port, buffer and body limits       |
| `Router(State)`    | type fn  | Route table bound to an app state type      |
| `Context`          | type     | Per-request context (handlers, extractors, middleware) |
| `Request`          | type     | The fully-read request inside `Context`     |
| `Response`         | type     | Status, headers, body                       |
| `ExtractError`     | error set| Errors returned by built-in extractors      |
| `Path(T)`          | type fn  | Path parameter extractor                    |
| `Query(T)`         | type fn  | Query string extractor                      |
| `Json(T)`          | type fn  | JSON body extractor and JSON response       |
| `State(T)`         | type fn  | Shared app state extractor                  |
| `Headers`          | type     | Raw header access                           |
| `Body`             | type     | Raw body bytes                              |
| `Client`           | type     | HTTP client for calling other services (§5) |
| `middleware`       | namespace| Built-in middleware                         |
| `testing`          | namespace| Test helpers (`request`, `serve`)           |

---

## 4. Core Concepts

### 4.1 Context

`Context` is the single object passed through middleware and into extractors.

```zig
request: Request,             // method, path, query, headers, body
arena: std.mem.Allocator,     // freed after the response is sent
io: std.Io,
params: path.Params = .{},    // filled and percent-decoded by the router
state: ?*anyopaque = null,    // cast back by State(T)
```

Rules:

- `Context` holds data. It has no business logic.
- Everything allocated from `ctx.arena` lives until the response is written. Nothing
  from the arena may escape the request.
- The connection reads the **whole request** (head copied into the arena, body read
  up to `max_body_size`) before dispatch. Handlers never touch the socket. This keeps
  extractors trivial and makes `Context` easy to build in tests.

### 4.2 Handlers

A handler is any function where:

- every parameter is an **extractor type** (§4.3) or `*zag.Context`, and
- the return type is **respondable** (§4.4), optionally as an error union.

`*zag.Context` is the escape hatch: use it for `ctx.arena`, `ctx.io`, or anything
the extractors don't cover.

`handler.zig` turns any such function into one shared runtime signature:

```zig
pub const Handler = *const fn (ctx: *Context) Response;

pub fn erase(comptime State: type, comptime label: []const u8, comptime func: anytype) Handler;
```

`erase` runs at comptime and:

1. Reads the parameter types with `@typeInfo(@TypeOf(func)).@"fn".param_types`.
2. For each parameter calls `T.extract(ctx)`, collecting results into a tuple.
3. Calls `func` with `@call(.auto, func, args)`.
4. Passes the result to `respond.into(ctx, result)`.
5. Maps any error to a response with `respond.fromError`, so the erased handler
   never fails and middleware always sees a real status.

Unsupported parameter or return types are a `@compileError` with a clear message that
names the route (`label`, e.g. `"GET /users/:id"`) and the bad type. Bad handlers fail at
build time, not at runtime.

### 4.3 Extractors

An extractor is any type with this declaration:

```zig
pub fn extract(ctx: *Context) Error!@This()
```

That is the whole contract. Users write their own extractors the same way.

| Extractor   | Source                    | Failure → status |
|-------------|---------------------------|------------------|
| `Path(T)`   | `:name` path segments     | 400              |
| `Query(T)`  | `?a=1&b=2`                | 400              |
| `Json(T)`   | body, `application/json`  | 415 / 400        |
| `State(T)`  | router's state pointer    | never fails      |
| `Headers`   | request headers           | never fails      |
| `Body`      | raw body bytes            | never fails      |

`Path(T)` and `Query(T)` take a flat struct whose fields are integers, floats, bools,
enums, `[]const u8`, or optionals of these. Field names map to param/query names.
Missing fields use the field default, then `null` if optional, else 400.
Anything else is a compile error.

Because the body is read before dispatch (§4.1), body extractors can appear anywhere
in the parameter list, and the 413 limit is enforced by the server, not the extractor.

`State(T)` is checked at comptime: `T` must equal the router's state type.

Extraction errors use a small, explicit error set (`zag.ExtractError`):

```zig
pub const Error = error{
    MissingParam,
    InvalidParam,
    UnsupportedMediaType,
    MalformedBody,
    OutOfMemory,
};
```

`respond.zig` maps each error to a status code in one `switch`.

### 4.4 Responses

A handler may return any of these (or an error union of them):

| Return type                         | Result                                |
|-------------------------------------|---------------------------------------|
| `void`                              | `204 No Content`                      |
| `[]const u8`                        | `200`, `text/plain; charset=utf-8`    |
| `std.http.Status`                   | that status, empty body               |
| `Response`                          | as given                              |
| `Json(T)`                           | `200`, `application/json`             |
| type with `pub fn toResponse(self, *Context) !Response` | custom          |

`Response` is a plain struct with decl-literal builders:

```zig
status: std.http.Status = .ok,
headers: []const std.http.Header = &.{},
body: []const u8 = "",

pub fn empty(status: std.http.Status) Response { ... }
pub fn text(body: []const u8) Response { ... }
pub fn json(arena: Allocator, value: anytype) !Response { ... }
```

Usage: `return .text("ok");`, `return .empty(.not_found);`.
(Zig forbids a field and a function with the same name, hence `empty`, not `status`.)

### 4.5 Errors from Handlers

- Errors in `extract.Error` → mapped to 4xx (above).
- `error.NotFound` → 404, `error.Unauthorized` → 401, `error.Forbidden` → 403.
- zag.Client errors → 502/504 (§5.6).
- zag-pg errors: `UniqueViolation`, `ForeignKeyViolation` → 409;
  `ConstraintViolation` → 422; `SerializationFailure`, `PoolTimeout` → 503;
  `QueryTimeout` → 504. zag-http does not depend on zag-pg; it matches error names.
- Anything else → `500 Internal Server Error`. The error name is logged with
  `std.log.err`. It is **never** sent to the client.

### 4.6 Router

```zig
pub fn Router(comptime State: type) type {
    return struct {
        /// `state` is `*State`, or `{}` for `Router(void)`.
        pub fn init(gpa: Allocator, state: StatePtr) @This();
        pub fn deinit(self: *@This()) void;

        pub fn get(self: *@This(), comptime pattern: []const u8, comptime h: anytype) !void;
        pub fn post(...)   // also put, patch, delete
        pub fn route(self: *@This(), comptime method: std.http.Method, comptime pattern: []const u8, comptime h: anytype) !void;
        pub fn nest(self: *@This(), comptime prefix: []const u8, other: *const @This()) !void;
        pub fn layer(self: *@This(), mw: Middleware) !void;
        pub fn fallback(self: *@This(), comptime h: anytype) void;
        pub fn handle(self: *const @This(), ctx: *Context) Response;  // never fails
    };
}
```

Path patterns:

- Static segments: `/users`
- Named params: `/users/:id`
- Trailing wildcard: `/static/*path` (only as the last segment)

Patterns are validated at **comptime**. A bad pattern is a compile error.

Matching (v1): routes are stored per method in registration order. Match is a linear
scan where each route is checked segment by segment. Static routes are checked before
param routes. This is simple and fast enough for a typical app (<100 routes). Replace it
with a radix tree only if benchmarks show the need — and keep the same `match` signature.

Behaviour:

- Path matches, method doesn't → `405 Method Not Allowed` with `Allow` header.
- No path matches → fallback handler, default `404`.
- `HEAD` falls back to the `GET` handler with the body dropped.
- Registering the same method + pattern twice returns `error.DuplicateRoute`.
- `nest` copies the other router's routes under the prefix. Its layers wrap only its
  own routes (inside the outer router's layers). Its fallback is ignored.

### 4.7 Middleware

Middleware wraps the next step in the chain:

```zig
pub const Next = struct {
    /// Never fails: errors from inner layers are already mapped to responses.
    pub fn run(self: Next, ctx: *Context) Response;
};

pub const Middleware = *const fn (ctx: *Context, next: Next) anyerror!Response;
```

Example:

```zig
pub fn logger(ctx: *Context, next: Next) anyerror!Response {
    const start = std.Io.Timestamp.now(ctx.io, .awake);
    const res = next.run(ctx);
    log.info("{s} {s} {d} {d}us", .{ ... });
    return res;
}
```

- Layers run in the order they were added: first added = outermost.
- Router layers wrap every request, including 404 and 405.
- A middleware can short-circuit by returning a `Response` (or an error) without
  calling `next`.
- Configurable middleware is a comptime function returning a `Middleware`:
  `zag.middleware.cors(.{ .origin = "https://example.com" })`.
- Built-ins: `logger`, `cors`. Error recovery is built into handlers (§4.2) and body
  limits into the server (`max_body_size`), so they need no middleware.

### 4.8 Server and Concurrency

```zig
pub const ServeOptions = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    read_buffer_size: usize = 8 * 1024,
    write_buffer_size: usize = 8 * 1024,
    max_body_size: usize = 1 * 1024 * 1024,
    keep_alive: bool = true,
};

pub fn serve(io: std.Io, gpa: Allocator, router: anytype, options: ServeOptions) !void;
```

- Listen with `std.Io.net.IpAddress.listen`, accept with `Server.accept(io)`.
- Each connection runs as a task in an `std.Io.Group` (`group.concurrent(...)`), so
  the concurrency model comes from the `Io` implementation the user picks
  (`Io.Threaded`, `Io.Evented`, …). Zag does not create threads itself.
- Each connection owns its read/write buffers and one `std.heap.ArenaAllocator`.
  The arena is reset with `.retain_capacity` after each request, so a keep-alive
  connection reuses memory.
- The router is **read-only after `serve` starts**. No locks needed on the hot path.
- App state is shared across connections. Making it thread-safe is the user's job
  (document this clearly; show a `std.Io.Mutex` example).
- Shutdown: `serve` returns when its `Io` task is canceled; open connections are
  canceled with `group.cancel`. (Draining in-flight requests is future work.)

---

## 5. HTTP Client

Most services also call other services. `zag.Client` makes that a one-liner with the
same conventions as the server: arena-owned results, typed JSON, and errors that map to
sensible statuses when returned from a handler.

### 5.1 Approach

`zag.Client` is a thin layer over `std.http.Client`, which already provides TLS,
connection pooling, redirects, gzip/deflate decoding, and thread safety. Zag adds:
base URL and default headers, typed JSON, query parameters, request bodies (bytes, JSON,
forms, multipart, streams), streaming responses, timeouts, retries, and status-code errors.

One `Client` is shared by the whole app (store it in `State`), so connections are reused
across handlers.

### 5.2 API

```zig
var client: zag.Client = .init(io, gpa, .{
    .base_url = "https://api.example.com",
    .headers = &.{.{ .name = "authorization", .value = "Bearer ..." }},
    .timeout = .fromSeconds(10),
});
defer client.deinit();

// Typed JSON. Non-2xx becomes an error (§5.6).
const user = try client.getJson(User, ctx.arena, "/users/42");
const created = try client.postJson(User, ctx.arena, "/users", new_user);

// Anything else: describe the request, get JSON back...
const page = try client.sendJson(Page, ctx.arena, .{
    .url = "/users",
    .query = &.{.{ .name = "page", .value = "2" }},
    .headers = &.{.{ .name = "x-request-id", .value = request_id }},
});

// ...or a raw response (no status check).
const res = try client.send(ctx.arena, .{
    .method = .PUT,
    .url = "/files/report.txt",
    .body = .{ .bytes = .{ .data = text, .content_type = "text/plain" } },
});
if (res.status != .ok) ...;

// Streaming download: read the body as it arrives.
var download = try client.stream(.{ .url = "https://example.com/big.bin" });
defer download.deinit();
_ = try download.reader().streamRemaining(file_writer);
```

```zig
pub const Request = struct {
    method: std.http.Method = .GET,
    url: []const u8,                       // absolute, or joined to base_url
    query: []const Param = &.{},           // percent-encoded and appended
    headers: []const std.http.Header = &.{},
    body: Body = .none,
    timeout: ?Io.Duration = null,          // overrides Options.timeout
    retry: ?Retry = null,                  // overrides Options.retry
};
```

| Function                           | Returns                         | Status check |
|------------------------------------|---------------------------------|--------------|
| `getJson(T, arena, url)`           | `T`                             | yes          |
| `postJson(T, arena, url, value)`   | `T`                             | yes          |
| `sendJson(T, arena, request)`      | `T`                             | yes          |
| `send(arena, request)`             | `Response` (buffered)           | no — read `res.status` |
| `stream(request)`                  | `*Stream` (caller calls `deinit`) | no         |

`Response` is buffered and arena-owned: `status`, `headers`, `body`,
`header(name)`, `json(T, arena)`, and `expectSuccess()` (§5.6).

### 5.3 Request Bodies

```zig
pub const Body = union(enum) {
    none,
    bytes: struct { data: []const u8, content_type: []const u8 = "application/octet-stream" },
    form: []const Param,           // application/x-www-form-urlencoded
    multipart: []const Part,       // multipart/form-data
    stream: struct { reader: *Io.Reader, length: ?u64 = null, content_type: []const u8 = ... },

    pub fn json(arena: Allocator, value: anytype) !Body;   // .bytes with application/json
};

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: union(enum) { bytes: []const u8, reader: *Io.Reader },
};
```

- `bytes`, `form`, and all-`bytes` multipart are sent with `content-length`.
- `stream` bodies, and multipart with any `reader` part, are sent with
  `transfer-encoding: chunked` unless a length is given.
- Multipart boundaries are random (from `io.random`) and checked not to occur in
  `bytes` parts.

### 5.4 Streaming Responses

`stream` returns once the response head has arrived. The body is read through
`reader()` (decompressed if needed) while the connection is held. `deinit` returns the
connection to the pool (or closes it if the body wasn't fully read). `Stream` is
heap-allocated because `std.http.Client.Response` points into its request.

### 5.5 Timeouts and Retries

**Timeout** (`Options.timeout`, per-request override): covers connect, send, and
receiving the response — for `send`/`*Json` the whole body, for `stream` only the head.
Implemented with `Io.Select`: the request runs as a task raced against a sleep; the loser
is canceled. On expiry: `error.Timeout`.

Cost: two extra tasks per attempt. With the default threaded `Io` that measured ~9 µs per
request on loopback (backend bench: 72k → 43k req/s) — under 1% of a real 1–50 ms
upstream call. `timeout = null` removes it. A cheaper design (one long-lived watchdog
task per client that shuts down the socket of an expired request) is possible later.

**Retries** (`Options.retry`):

```zig
pub const Retry = struct {
    max_attempts: u8 = 3,          // 1 disables retries
    base_delay: Io.Duration = .fromMilliseconds(100),
    max_delay: Io.Duration = .fromSeconds(2),
    retry_non_idempotent: bool = false,
};
```

- Only idempotent methods (GET, HEAD, PUT, DELETE, OPTIONS) are retried by default, so a
  retry can never create something twice.
- Retried on: connection/transport errors, timeouts, and status 429, 502, 503, 504.
- Delay: exponential backoff with full jitter, capped at `max_delay`. A `Retry-After`
  header (in seconds) is honoured, also capped at `max_delay`.
- Never retried: `stream` bodies (they can't be replayed) and errors that can't succeed
  on retry (bad URL, response too large, out of memory, canceled).

### 5.6 Errors

Status errors (from the `*Json` helpers and `Response.expectSuccess`) are chosen so a
handler can simply `try` them and zag-http's error mapping (§4.5) does the right thing:

| Upstream status | Error                | If a handler returns it |
|-----------------|----------------------|-------------------------|
| 401             | `error.Unauthorized` | 401 |
| 403             | `error.Forbidden`    | 403 |
| 404             | `error.NotFound`     | 404 |
| other 4xx / 5xx | `error.UpstreamStatus` | 502 Bad Gateway |
| timeout         | `error.Timeout`      | 504 Gateway Timeout |
| connection failure | `error.UpstreamUnavailable` | 502 Bad Gateway |

The upstream response is still logged at debug level with its status, but its body is
never forwarded to the client.

### 5.7 Limits and Memory

- `Options.max_response_size` (default 10 MiB) caps buffered bodies → `error.ResponseTooLarge`.
- Buffered results (`Response`, decoded JSON) live in the arena passed in. `Stream` is
  allocated with the client's `gpa` and freed by `deinit`.
- Request headers: per-request headers override client defaults with the same name.
- Redirects are followed only for bodiless requests **without credentials**
  (`authorization`, `proxy-authorization`, `cookie`); otherwise the 3xx is returned.
  Zig 0.17.1's `std.http.Client` never sends its `privileged_headers`, and anything else
  would be forwarded to a different host on redirect. Revisit when std fixes this.

### 5.8 Testing

`zag.testing.serve(&router)` runs a router on `127.0.0.1:0` and returns its URL, so code
that calls a "remote" API can be tested against a fake one built as an ordinary zag router.
Every client feature (retries, streaming, multipart) runs through a real socket in tests.

---

## 6. Memory Model

| Lifetime     | Allocator                    | Examples                          |
|--------------|------------------------------|-----------------------------------|
| Process      | `gpa` passed to `Router.init`| route table, middleware list      |
| Connection   | fixed buffers                | read/write buffers                |
| Request      | per-connection arena         | parsed JSON, params, response body|

Rules:

- Zag never uses a global allocator.
- Handlers get the arena through `Context` (or an `Allocator` extractor).
  They should never `free` from it.
- Long-lived data that a handler wants to keep must be copied into state using an
  allocator the user owns.
- All tests use `std.testing.allocator` so leaks fail the build.

---

## 7. Security Defaults

- Max header size bounded by `read_buffer_size`; oversize → `431`.
- Max body size (`max_body_size`) enforced before reading; oversize → `413`.
- Path params are percent-decoded once. `..` segments are rejected for wildcard params.
- Internal error details never reach the client.
- Request smuggling: rely on `std.http.Server` parsing; reject requests that have both
  `Content-Length` and `Transfer-Encoding` (400). Compressed request bodies get 415.
- Malformed chunked bodies get 400.
- Response headers containing CR/LF are refused (500), so handlers can't inject headers.
- **Not yet:** read timeouts for slow clients (slowloris). Until then, run behind a
  reverse proxy that enforces them.

---

## 8. Zig Best Practices (Project Rules)

### 8.1 Style

- Run `zig fmt` (CI fails if `zig fmt --check .` fails).
- Naming, per the Zig style guide:
  - Types and type-returning functions: `TitleCase` (`Router`, `Json`).
  - Functions: `camelCase` (`receiveHead`, `extract`).
  - Variables, fields, constants: `snake_case` (`max_body_size`).
  - Files: `TitleCase.zig` if the file is a struct type, otherwise `snake_case.zig`.
- No redundant names: `zag.Router`, not `zag.ZagRouter`; `Router.match`, not
  `Router.matchRoute`.
- Doc comments (`///`) on every public declaration. `//!` at the top of each file
  saying what it is for.

### 8.2 Memory and Resources

- Every function that allocates takes an `Allocator` parameter (or gets one from
  `Context`). No hidden allocation.
- Pair every acquire with `defer`; use `errdefer` for cleanup on the error path.
  Put the `defer` on the line right after the acquire.
- Prefer unmanaged containers (`std.ArrayList(T)` with `.empty`, passing `gpa` to each
  call) — this is the 0.17 default.
- Prefer fixed buffers and arenas over many small allocations on the hot path.
- Use `init`/`deinit` naming. `deinit` takes `*Self` and sets `self.* = undefined`.

### 8.3 Errors

- Use explicit error sets on public functions. `anyerror` only at the erased handler /
  middleware boundary, where it is unavoidable.
- Never ignore errors with `catch {}`. If an error is truly ignorable, write
  `catch |err| log.debug(...)` and say why in a comment.
- No `unreachable` for things that can happen at runtime with bad input.
  `unreachable` means "this is a bug in Zag".

### 8.4 I/O

- Take `std.Io` as a parameter; never create one inside the library.
- Read and write through `*std.Io.Reader` / `*std.Io.Writer` interfaces.
- Always `flush` writers explicitly.

### 8.5 Comptime

- Use comptime to **check** things (handler shape, route patterns) and to **remove
  boilerplate** (extractor dispatch). Not to be clever.
- All the reflection lives in `handler.zig` and the extractor files. Other files are
  plain runtime code.
- Every `@compileError` message says what is wrong and how to fix it:
  `"handler 'getUser': parameter 2 has type 'u64', expected an extractor (e.g. zag.Path(struct { id: u64 }))"`.
- Avoid `anytype` in public APIs except where the type is genuinely open
  (handlers, `Response.json` values). Prefer a concrete type or a type parameter.

### 8.6 Safety

- Default dev build is `Debug`; recommended production build is `ReleaseSafe`.
- Integer casts use `@intCast` only after a bounds check, or `std.math.cast` which
  returns an optional.
- No `@ptrCast` except in `State(T)` (single, documented place for `*anyopaque`).

---

## 9. Low Cognitive Complexity Rules

Code is read far more than it is written. These rules are enforced in review.

### 9.1 Hard Limits

| Metric                                   | Limit |
|------------------------------------------|-------|
| Function length                          | ≤ 40 lines (excluding doc comments) |
| Nesting depth (if/while/for/switch)      | ≤ 3   |
| Parameters per function                  | ≤ 4 (else pass an options struct) |
| Cognitive complexity per function¹       | ≤ 10  |
| File length                              | ≤ 400 lines (tests excluded) |

¹ As defined by SonarSource: +1 for each `if`, `else if`, `switch`, loop, `catch`,
`orelse` with a block, and boolean operator sequence; +1 extra per nesting level.

Exceeding a limit needs a one-line comment explaining why.

### 9.2 Guidelines

- **Return early.** Handle errors and edge cases first, then the main path un-indented.

  ```zig
  // Good
  const route = router.match(method, path) orelse return notFound(ctx);
  return route.handler(ctx);

  // Avoid
  if (router.match(method, path)) |route| {
      return route.handler(ctx);
  } else {
      return notFound(ctx);
  }
  ```

- **One level of abstraction per function.** `Connection.run` calls `readRequest`,
  `dispatch`, `writeResponse` — it does not also parse headers.
- **Pure functions where possible.** `path.zig` takes slices and returns results; it
  knows nothing about sockets or allocators. Pure code is easy to test and reason about.
- **`switch` over chains of `if`.** Exhaustive switches on enums and error sets let the
  compiler check you handled every case.
- **Name boolean conditions.** `const is_body_too_large = len > max;` before `if`.
- **No boolean parameters that change behaviour.** Use an enum or two functions.
- **Data in, data out.** Prefer returning values over mutating through out-params.
- **Options structs with defaults** instead of many parameters or builder chains.
- **No premature abstraction.** Write it plainly; extract a helper on the third copy,
  not the first.
- **Comments say *why*, not *what*.**

---

## 10. Testing Strategy

| Level        | Where                         | How                                          |
|--------------|-------------------------------|----------------------------------------------|
| Unit         | `test` blocks in each file    | Pure functions: path matching, query parsing |
| Router       | `src/testing.zig` helpers     | In-memory request → `Response`, no sockets   |
| End-to-end   | `src/tests.zig`               | Router tests + one real listener on `127.0.0.1:0` |
| Fuzz         | `zig build test --fuzz`       | Path matching (more targets later)           |
| Compile-fail | (future)                      | Bad handlers/patterns must not compile       |

Router test example:

```zig
test "GET /users/:id returns json" {
    var router: zag.Router(void) = .init(std.testing.allocator, {});
    defer router.deinit();
    try router.get("/users/:id", getUser);

    var res = try zag.testing.request(&router, .GET, "/users/7", .{});
    defer res.deinit();

    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("{\"id\":7,\"name\":\"ziggy\"}", res.body);
}
```

Rules:

- Every bug fix adds a test that failed before the fix.
- Tests use `std.testing.allocator` (leak detection).
- `zig build test` must pass with no network access except loopback.

---

## 11. Build and Tooling

- `zig build` — library + examples.
- `zig build test` — all tests.
- `zig build run-example -Dexample=hello` — run an example (`hello`, `json_api`).
- `zig build bench` — benchmark suite in `bench/` (always ReleaseFast): plaintext, json, params, echo, backend. Pass flags after `--`: `--connections N --duration S --only NAME`.
- CI: `zig fmt --check .`, `zig build test` in `Debug` and `ReleaseSafe`, on Linux and macOS.
- Consumers add the Zag repo with `zig fetch --save <url>` and import `b.dependency("zag", .{}).module("zag-http")` (see the root README). Inside this repo, `zag-http` is also a standalone package.

---

## 12. Milestones

| # | Milestone        | Scope                                                                 | Status |
|---|------------------|-----------------------------------------------------------------------|--------|
| 1 | Hello            | `serve`, `Connection`, `Response`, router with static routes          | Done   |
| 2 | Extractors       | `handler.erase`, `Path`, `Query`, `State`, `Headers`, path params      | Done (compile-fail tests pending) |
| 3 | JSON + Bodies    | `Json`, `Body`, body limits, error→status mapping                     | Done   |
| 4 | Middleware       | `Middleware`, `Next`, `logger`, `cors`; `nest`                        | Done |
| 4b | HTTP client     | `zag.Client`: JSON, bodies incl. multipart/stream, streaming responses, timeouts, retries | Done |
| 5 | Hardening        | Read timeouts, more fuzz targets, graceful drain, docs                | Next   |
| — | Later            | Radix-tree router, WebSockets (`std.http.Server.WebSocket`), SSE, streaming responses, static files | — |

---

## 13. Open Questions

1. Should `State(T)` support sub-state (Axum's `FromRef`), e.g. `State(Db)` from a
   larger `AppState`, via a field-type lookup at comptime?
2. Streaming responses: expose `std.http.Server.Request.respondStreaming` directly, or
   wrap it in a `Stream` response type? (Requires lazy body reading for uploads too.)
3. Read timeouts: per-connection deadline via `Io` timeouts, or a `timeout` middleware?

Resolved: the router stays runtime (v1). Handlers that need memory take `*zag.Context`
and use `ctx.arena` rather than a separate `Allocator` extractor.
