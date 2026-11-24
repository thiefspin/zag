//! Route table: registration, matching and dispatch.
//!
//! The router is read-only once serving starts, so it needs no locks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Method = std.http.Method;

const Context = @import("Context.zig");
const Response = @import("Response.zig");
const handler = @import("handler.zig");
const middleware = @import("middleware.zig");
const path = @import("path.zig");
const respond = @import("respond.zig");

const Handler = middleware.Handler;
const Middleware = middleware.Middleware;
const Next = middleware.Next;

/// One registered route. `pattern` and `layers` are owned by the router.
const Route = struct {
    method: Method,
    pattern: []const u8,
    handler: Handler,
    /// Layers from a nested router; they run after the router's own layers.
    layers: []const Middleware,
};

/// A router whose handlers can use `zag.State(S)`. Use `Router(void)` for no state.
pub fn Router(comptime S: type) type {
    return struct {
        const Self = @This();

        /// What `init` takes as state: `*S`, or `{}` when `S` is `void`.
        pub const StatePtr = if (S == void) void else *S;

        gpa: Allocator,
        state: ?*anyopaque,
        /// Routes without captures. Checked first, so `/users/me` beats `/users/:id`.
        static_routes: std.ArrayList(Route) = .empty,
        dynamic_routes: std.ArrayList(Route) = .empty,
        layers: std.ArrayList(Middleware) = .empty,
        fallback_handler: Handler = handler.erase(S, "fallback", notFound),

        pub fn init(gpa: Allocator, state: StatePtr) Self {
            return .{ .gpa = gpa, .state = if (S == void) null else state };
        }

        pub fn deinit(self: *Self) void {
            for (self.routeLists()) |routes| {
                for (routes) |r| {
                    self.gpa.free(r.pattern);
                    self.gpa.free(r.layers);
                }
            }
            self.static_routes.deinit(self.gpa);
            self.dynamic_routes.deinit(self.gpa);
            self.layers.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn get(self: *Self, comptime pattern: []const u8, comptime h: anytype) !void {
            return self.route(.GET, pattern, h);
        }
        pub fn post(self: *Self, comptime pattern: []const u8, comptime h: anytype) !void {
            return self.route(.POST, pattern, h);
        }
        pub fn put(self: *Self, comptime pattern: []const u8, comptime h: anytype) !void {
            return self.route(.PUT, pattern, h);
        }
        pub fn patch(self: *Self, comptime pattern: []const u8, comptime h: anytype) !void {
            return self.route(.PATCH, pattern, h);
        }
        pub fn delete(self: *Self, comptime pattern: []const u8, comptime h: anytype) !void {
            return self.route(.DELETE, pattern, h);
        }

        /// Registers `h` for `method` and `pattern`. Bad patterns and bad
        /// handler signatures are compile errors.
        pub fn route(self: *Self, comptime method: Method, comptime pattern: []const u8, comptime h: anytype) !void {
            comptime path.validate(pattern);
            const erased = handler.erase(S, @tagName(method) ++ " " ++ pattern, h);
            try self.addRoute(.{ .method = method, .pattern = pattern, .handler = erased, .layers = &.{} });
        }

        /// Copies every route of `other` under `prefix`. `other`'s layers apply
        /// only to its own routes; its fallback is ignored.
        pub fn nest(self: *Self, comptime prefix: []const u8, other: *const Self) !void {
            comptime path.validate(prefix);
            for (other.routeLists()) |routes| {
                for (routes) |r| try self.nestRoute(prefix, other.layers.items, r);
            }
        }

        /// Adds a middleware that wraps every request, including 404s.
        /// The first layer added is the outermost.
        pub fn layer(self: *Self, mw: Middleware) !void {
            try self.layers.append(self.gpa, mw);
        }

        /// Sets the handler used when no route matches. Default: 404.
        pub fn fallback(self: *Self, comptime h: anytype) void {
            self.fallback_handler = handler.erase(S, "fallback", h);
        }

        /// Runs the full pipeline for one request. Never fails.
        pub fn handle(self: *const Self, ctx: *Context) Response {
            ctx.state = self.state;
            const next = self.resolve(ctx) catch |err| return respond.fromError(err);
            return next.run(ctx);
        }

        fn resolve(self: *const Self, ctx: *Context) Allocator.Error!Next {
            const found = self.find(ctx.request.method, ctx) orelse
                self.findHeadAsGet(ctx) orelse
                return self.unmatched(ctx);

            path.decodeParams(ctx.arena, &ctx.params) catch |err| switch (err) {
                error.InvalidParam => return self.wrap(.{ .response = .empty(.bad_request) }),
                error.OutOfMemory => return error.OutOfMemory,
            };
            const layers = try std.mem.concat(ctx.arena, Middleware, &.{ self.layers.items, found.layers });
            return .{ .layers = layers, .endpoint = .{ .handler = found.handler } };
        }

        /// Finds a route for `method` and the request path, filling `ctx.params`.
        fn find(self: *const Self, method: Method, ctx: *Context) ?*const Route {
            for (self.routeLists()) |routes| {
                for (routes) |*r| {
                    if (r.method == method and path.match(r.pattern, ctx.request.path, &ctx.params)) return r;
                }
            }
            return null;
        }

        /// `HEAD` uses the `GET` handler; the server drops the body.
        fn findHeadAsGet(self: *const Self, ctx: *Context) ?*const Route {
            if (ctx.request.method != .HEAD) return null;
            return self.find(.GET, ctx);
        }

        /// 405 if the path exists under another method, otherwise the fallback.
        fn unmatched(self: *const Self, ctx: *Context) Allocator.Error!Next {
            const allow = try self.allowedMethods(ctx) orelse
                return self.wrap(.{ .handler = self.fallback_handler });
            const headers = try ctx.arena.dupe(std.http.Header, &.{.{ .name = "allow", .value = allow }});
            return self.wrap(.{ .response = .{ .status = .method_not_allowed, .headers = headers } });
        }

        /// Comma-separated methods registered for the request path, or null.
        fn allowedMethods(self: *const Self, ctx: *Context) Allocator.Error!?[]const u8 {
            var methods: std.EnumSet(Method) = .empty;
            var scratch: path.Params = .{};
            for (self.routeLists()) |routes| {
                for (routes) |r| {
                    if (path.match(r.pattern, ctx.request.path, &scratch)) methods.insert(r.method);
                }
            }
            if (methods.count() == 0) return null;

            var list: std.ArrayList(u8) = .empty;
            var it = methods.iterator();
            while (it.next()) |method| {
                if (list.items.len > 0) try list.appendSlice(ctx.arena, ", ");
                try list.appendSlice(ctx.arena, @tagName(method));
            }
            return list.items;
        }

        fn wrap(self: *const Self, endpoint: middleware.Endpoint) Next {
            return .{ .layers = self.layers.items, .endpoint = endpoint };
        }

        fn nestRoute(self: *Self, comptime prefix: []const u8, outer: []const Middleware, r: Route) !void {
            const pattern = try std.mem.concat(self.gpa, u8, &.{ prefix, r.pattern });
            defer self.gpa.free(pattern);
            const layers = try std.mem.concat(self.gpa, Middleware, &.{ outer, r.layers });
            defer self.gpa.free(layers);
            try self.addRoute(.{ .method = r.method, .pattern = pattern, .handler = r.handler, .layers = layers });
        }

        /// Stores a copy of `r` (pattern and layers are duplicated).
        fn addRoute(self: *Self, r: Route) !void {
            if (self.contains(r.method, r.pattern)) return error.DuplicateRoute;

            const pattern = try self.gpa.dupe(u8, r.pattern);
            errdefer self.gpa.free(pattern);
            const layers = try self.gpa.dupe(Middleware, r.layers);
            errdefer self.gpa.free(layers);

            const list = if (path.isStatic(pattern)) &self.static_routes else &self.dynamic_routes;
            try list.append(self.gpa, .{ .method = r.method, .pattern = pattern, .handler = r.handler, .layers = layers });
        }

        fn contains(self: *const Self, method: Method, pattern: []const u8) bool {
            for (self.routeLists()) |routes| {
                for (routes) |r| {
                    if (r.method == method and std.mem.eql(u8, r.pattern, pattern)) return true;
                }
            }
            return false;
        }

        fn routeLists(self: *const Self) [2][]const Route {
            return .{ self.static_routes.items, self.dynamic_routes.items };
        }
    };
}

fn notFound() std.http.Status {
    return .not_found;
}
