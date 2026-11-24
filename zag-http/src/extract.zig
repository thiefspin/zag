//! Built-in extractors. An extractor is any type with
//! `pub fn extract(ctx: *Context) !@This()`; users write their own the same way.

const std = @import("std");
const Context = @import("Context.zig");
const Response = @import("Response.zig");
const fields = @import("fields.zig");

/// Errors the built-in extractors return. `respond.fromError` maps each to a
/// 4xx status.
pub const Error = error{
    MissingParam,
    InvalidParam,
    UnsupportedMediaType,
    MalformedBody,
    OutOfMemory,
};

/// Path parameters, e.g. `Path(struct { id: u64 })` for `/users/:id`.
pub fn Path(comptime T: type) type {
    comptime fields.check(T);
    return struct {
        value: T,

        pub fn extract(ctx: *Context) Error!@This() {
            return .{ .value = try fields.parseStruct(T, &ctx.params) };
        }
    };
}

/// Query string parameters, e.g. `Query(struct { page: u32 = 1 })`.
pub fn Query(comptime T: type) type {
    comptime fields.check(T);
    return struct {
        value: T,

        pub fn extract(ctx: *Context) Error!@This() {
            const pairs = try fields.parseQuery(ctx.arena, ctx.request.query);
            return .{ .value = try fields.parseStruct(T, pairs) };
        }
    };
}

/// A JSON request body, and a JSON response when returned from a handler.
/// Unknown fields in the request are ignored.
pub fn Json(comptime T: type) type {
    return struct {
        value: T,

        pub fn extract(ctx: *Context) Error!@This() {
            const content_type = ctx.request.header("content-type") orelse "";
            if (!std.mem.startsWith(u8, content_type, "application/json")) {
                return error.UnsupportedMediaType;
            }
            const value = std.json.parseFromSliceLeaky(T, ctx.arena, ctx.request.body, .{
                .ignore_unknown_fields = true,
            }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.MalformedBody,
            };
            return .{ .value = value };
        }

        pub fn toResponse(self: @This(), ctx: *Context) error{OutOfMemory}!Response {
            return .json(ctx.arena, self.value);
        }
    };
}

/// The router's shared app state. `T` must match the router's state type
/// (checked at compile time). State is shared by all connections, so guard
/// mutable fields with a `std.Io.Mutex`.
pub fn State(comptime T: type) type {
    return struct {
        value: *T,

        /// Lets the router check that `T` matches its own state type.
        pub const StateType = T;

        pub fn extract(ctx: *Context) Error!@This() {
            // Safe: the router stores a `*T` here and checked `T` at comptime.
            return .{ .value = @ptrCast(@alignCast(ctx.state.?)) };
        }
    };
}

/// All request headers.
pub const Headers = struct {
    items: []const std.http.Header,

    pub fn extract(ctx: *Context) Error!Headers {
        return .{ .items = ctx.request.headers };
    }

    /// Returns the first header named `name` (case-insensitive).
    pub fn get(self: Headers, name: []const u8) ?[]const u8 {
        for (self.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

/// The raw request body.
pub const Body = struct {
    bytes: []const u8,

    pub fn extract(ctx: *Context) Error!Body {
        return .{ .bytes = ctx.request.body };
    }
};
