//! Middleware: functions that wrap the rest of the request pipeline.

const std = @import("std");
const Context = @import("Context.zig");
const Response = @import("Response.zig");
const respond = @import("respond.zig");

const log = std.log.scoped(.zag);

/// A middleware calls `next.run(ctx)` to continue, or returns a response
/// directly to short-circuit.
pub const Middleware = *const fn (ctx: *Context, next: Next) anyerror!Response;

/// A type-erased handler. Never fails: errors are already mapped to responses.
pub const Handler = *const fn (ctx: *Context) Response;

/// What runs after all middleware: a handler, or a response the router has
/// already decided on (e.g. 405 Method Not Allowed).
pub const Endpoint = union(enum) {
    handler: Handler,
    response: Response,
};

/// The rest of the pipeline after the current middleware.
pub const Next = struct {
    layers: []const Middleware,
    endpoint: Endpoint,

    pub fn run(self: Next, ctx: *Context) Response {
        if (self.layers.len == 0) return switch (self.endpoint) {
            .handler => |handler| handler(ctx),
            .response => |response| response,
        };
        const rest: Next = .{ .layers = self.layers[1..], .endpoint = self.endpoint };
        return self.layers[0](ctx, rest) catch |err| respond.fromError(err);
    }
};

/// Logs method, path, status and duration of every request.
pub fn logger(ctx: *Context, next: Next) anyerror!Response {
    const start = std.Io.Timestamp.now(ctx.io, .awake);
    const res = next.run(ctx);
    const elapsed = start.untilNow(ctx.io, .awake);
    log.info("{s} {s} {d} {d}us", .{
        @tagName(ctx.request.method),
        ctx.request.path,
        @backingInt(res.status),
        elapsed.toMicroseconds(),
    });
    return res;
}

pub const CorsOptions = struct {
    origin: []const u8 = "*",
    methods: []const u8 = "GET, POST, PUT, PATCH, DELETE, OPTIONS",
    headers: []const u8 = "content-type, authorization",
};

/// Returns a middleware that adds CORS headers and answers preflight
/// `OPTIONS` requests. `try router.layer(zag.middleware.cors(.{}));`
pub fn cors(comptime options: CorsOptions) Middleware {
    const allow_origin: std.http.Header = .{ .name = "access-control-allow-origin", .value = options.origin };
    const preflight_headers = [_]std.http.Header{
        allow_origin,
        .{ .name = "access-control-allow-methods", .value = options.methods },
        .{ .name = "access-control-allow-headers", .value = options.headers },
    };
    return struct {
        fn run(ctx: *Context, next: Next) anyerror!Response {
            if (ctx.request.method == .OPTIONS) {
                return .{ .status = .no_content, .headers = &preflight_headers };
            }
            var res = next.run(ctx);
            res.headers = try appendHeader(ctx.arena, res.headers, allow_origin);
            return res;
        }
    }.run;
}

fn appendHeader(
    arena: std.mem.Allocator,
    headers: []const std.http.Header,
    extra: std.http.Header,
) error{OutOfMemory}![]const std.http.Header {
    const result = try arena.alloc(std.http.Header, headers.len + 1);
    @memcpy(result[0..headers.len], headers);
    result[headers.len] = extra;
    return result;
}
