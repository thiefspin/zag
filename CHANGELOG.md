# Changelog

All notable changes to Zag. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Every library in the repo shares one
version. Before 1.0, minor versions may contain breaking changes.

## [Unreleased]

## [0.1.0] - unreleased

First release.

### zag-http

- Router with static, `:param` and `*wildcard` segments, nested routers,
  fallback handler, automatic `405` with `allow`, and `HEAD` for `GET` routes.
- Plain-function handlers with typed extractors: `Path`, `Query`, `Json`,
  `State`, `Headers`, `Body`, and user-defined extractors.
- Handlers return `Response`, a status, a string, `void`, or `Json(T)`. Errors
  map to status codes, and internal errors never reach the client.
- Middleware layers, plus built-in `logger` and `cors`.
- A per-request arena: handlers never free memory.
- `zag.Client`, an HTTP client with JSON helpers, query strings, form,
  multipart and streamed bodies, streaming downloads, retries with backoff
  and `Retry-After`, timeouts, and redirect handling.
- `zag.testing`: in-process requests and a real test server.
- A benchmark (`make bench`).

### zag-pg

- Pure-Zig PostgreSQL client over the v3 wire protocol.
- SCRAM-SHA-256, MD5 and opt-in cleartext authentication.
- Parameterized queries decoded into structs: `query`, `queryOne`, `get`,
  `exec`, `execScript`.
- Threadsafe connection pool with lazy connects, acquire timeout and
  broken-connection replacement.
- Transactions that roll back unless committed.
- SQLSTATE mapping to Zig errors that zag-http turns into 409, 422, 503 and 504.

[Unreleased]: https://github.com/thiefspin/zag/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/thiefspin/zag/releases/tag/v0.1.0
