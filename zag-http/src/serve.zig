//! TCP listener and accept loop. Each connection runs as its own task in an
//! `std.Io.Group`, so the concurrency model is whatever `Io` the caller picks.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Connection = @import("Connection.zig");

const log = std.log.scoped(.zag);

pub const ServeOptions = struct {
    address: []const u8 = "127.0.0.1",
    /// 0 picks a free port.
    port: u16 = 3000,
    /// Also the maximum size of a request head; larger heads get 431.
    read_buffer_size: usize = 8 * 1024,
    write_buffer_size: usize = 8 * 1024,
    /// Larger bodies get 413.
    max_body_size: usize = 1024 * 1024,
    keep_alive: bool = true,
};

/// Listens on `options.address:port` and serves `router` until the calling
/// task is canceled. Open connections are canceled on return.
pub fn serve(io: Io, gpa: Allocator, router: anytype, options: ServeOptions) !void {
    var listener = try listen(io, options);
    defer listener.deinit(io);
    log.info("listening on {f}", .{listener.socket.address});
    return accept(.{ .io = io, .gpa = gpa, .dispatch = .of(router), .options = options }, &listener);
}

/// Everything a connection task needs besides its stream.
pub const Shared = struct {
    io: Io,
    gpa: Allocator,
    dispatch: Connection.Dispatch,
    options: ServeOptions,
};

/// Binds the listening socket. Split from `serve` so tests can read the port.
pub fn listen(io: Io, options: ServeOptions) !Io.net.Server {
    const address = try Io.net.IpAddress.parse(options.address, options.port);
    return address.listen(io, .{ .reuse_address = true });
}

/// Accepts connections forever, one task per connection.
pub fn accept(shared: Shared, listener: *Io.net.Server) Io.Cancelable!void {
    const io = shared.io;
    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.warn("accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        group.concurrent(io, serveConnection, .{ shared, stream }) catch |err| {
            log.warn("could not start connection task: {s}", .{@errorName(err)});
            stream.close(io);
        };
    }
}

fn serveConnection(shared: Shared, stream: Io.net.Stream) void {
    const io = shared.io;
    const gpa = shared.gpa;
    const options = shared.options;
    defer stream.close(io);

    const buffer = gpa.alloc(u8, options.read_buffer_size + options.write_buffer_size) catch {
        log.warn("out of memory for connection buffers", .{});
        return;
    };
    defer gpa.free(buffer);

    var reader = stream.reader(io, buffer[0..options.read_buffer_size]);
    var writer = stream.writer(io, buffer[options.read_buffer_size..]);
    var connection: Connection = .{
        .io = io,
        .dispatch = shared.dispatch,
        .options = .{ .max_body_size = options.max_body_size, .keep_alive = options.keep_alive },
        .server = .init(&reader.interface, &writer.interface),
        .arena = .init(gpa),
    };
    defer connection.arena.deinit();
    connection.run();
}
