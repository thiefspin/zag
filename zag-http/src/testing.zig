//! Drive a router from tests without opening sockets.

const std = @import("std");
const Context = @import("Context.zig");
const Request = @import("Request.zig");

pub const RequestOptions = struct {
    body: []const u8 = "",
    headers: []const std.http.Header = &.{},
};

/// The result of `request`. Call `deinit` to free it.
pub const TestResponse = struct {
    arena: *std.heap.ArenaAllocator,
    status: std.http.Status,
    headers: []const std.http.Header,
    body: []const u8,

    pub fn deinit(self: *TestResponse) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }

    /// Returns the first response header named `name` (case-insensitive).
    pub fn header(self: *const TestResponse, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

/// Runs one request through `router` (a `*Router(S)`). Uses
/// `std.testing.allocator`, so leaks fail the test.
pub fn request(
    router: anytype,
    method: std.http.Method,
    target: []const u8,
    options: RequestOptions,
) !TestResponse {
    const gpa = std.testing.allocator;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    const path, const query = Request.splitTarget(target);
    var ctx: Context = .{
        .request = .{ .method = method, .path = path, .query = query, .headers = options.headers, .body = options.body },
        .arena = arena.allocator(),
        .io = std.testing.io,
    };
    const res = router.handle(&ctx);
    return .{ .arena = arena, .status = res.status, .headers = res.headers, .body = res.body };
}

/// A router running on `127.0.0.1` on a free port, for testing code that
/// calls an HTTP service (e.g. with `zag.Client`). Call `deinit` to stop it.
pub const TestServer = struct {
    listener: std.Io.net.Server,
    task: std.Io.Future(std.Io.Cancelable!void),
    url_buffer: [32]u8,
    /// `http://127.0.0.1:<port>`
    url: []const u8,

    pub fn deinit(self: *TestServer) void {
        const io = std.testing.io;
        self.task.cancel(io) catch {};
        self.listener.deinit(io);
        std.testing.allocator.destroy(self);
    }
};

/// Serves `router` (a `*Router(S)`) on a loopback port until `deinit`.
pub fn serve(router: anytype) !*TestServer {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const serve_impl = @import("serve.zig");

    const self = try gpa.create(TestServer);
    errdefer gpa.destroy(self);
    self.listener = try serve_impl.listen(io, .{ .port = 0 });
    errdefer self.listener.deinit(io);
    const port = self.listener.socket.address.getPort();
    self.url = try std.fmt.bufPrint(&self.url_buffer, "http://127.0.0.1:{d}", .{port});

    const shared: serve_impl.Shared = .{ .io = io, .gpa = gpa, .dispatch = .of(router), .options = .{} };
    self.task = try io.concurrent(serve_impl.accept, .{ shared, &self.listener });
    return self;
}
