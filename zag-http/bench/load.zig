//! Closed-loop HTTP/1.1 load generator: `connections` keep-alive connections,
//! each sending the next request as soon as the previous response arrives.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    address: Io.net.IpAddress,
    /// Raw HTTP/1.1 request bytes, sent as-is.
    request: []const u8,
    connections: usize,
    duration: Io.Duration,
};

pub const Result = struct {
    requests: usize,
    errors: usize,
    seconds: f64,
    /// Sorted ascending, in microseconds.
    latencies: []const u32,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        gpa.free(self.latencies);
        self.* = undefined;
    }

    pub fn rps(self: Result) f64 {
        return @as(f64, @floatFromInt(self.requests)) / self.seconds;
    }

    /// Latency at quantile `q` (0..1) in microseconds.
    pub fn percentile(self: Result, q: f64) u32 {
        if (self.latencies.len == 0) return 0;
        const last: f64 = @floatFromInt(self.latencies.len - 1);
        return self.latencies[@intFromFloat(@round(last * q))];
    }
};

/// Runs the load until `options.duration` has passed.
pub fn run(io: Io, gpa: Allocator, options: Options) !Result {
    const workers = try gpa.alloc(Worker, options.connections);
    defer gpa.free(workers);

    const start = Io.Timestamp.now(io, .awake);
    const deadline = start.addDuration(options.duration);
    for (workers) |*w| w.* = .{ .io = io, .gpa = gpa, .options = options, .deadline = deadline };
    defer for (workers) |*w| w.latencies.deinit(gpa);

    var group: Io.Group = .init;
    for (workers) |*w| try group.concurrent(io, Worker.run, .{w});
    try group.await(io);

    const elapsed = start.untilNow(io, .awake);
    return collect(gpa, workers, elapsed);
}

fn collect(gpa: Allocator, workers: []const Worker, elapsed: Io.Duration) !Result {
    var all: std.ArrayList(u32) = .empty;
    errdefer all.deinit(gpa);
    var errors: usize = 0;
    for (workers) |w| {
        try all.appendSlice(gpa, w.latencies.items);
        errors += w.errors;
    }
    std.mem.sortUnstable(u32, all.items, {}, std.sort.asc(u32));
    const seconds = @as(f64, @floatFromInt(elapsed.toMicroseconds())) / std.time.us_per_s;
    return .{ .requests = all.items.len, .errors = errors, .seconds = seconds, .latencies = try all.toOwnedSlice(gpa) };
}

const Worker = struct {
    io: Io,
    gpa: Allocator,
    options: Options,
    deadline: Io.Timestamp,
    latencies: std.ArrayList(u32) = .empty,
    errors: usize = 0,

    fn run(w: *Worker) void {
        while (w.timeLeft()) {
            w.runConnection() catch {
                w.errors += 1;
            };
        }
    }

    /// Sends requests on one connection until the deadline or an error.
    fn runConnection(w: *Worker) !void {
        const stream = try w.options.address.connect(w.io, .{ .mode = .stream });
        defer stream.close(w.io);

        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(w.io, &read_buffer);
        var writer = stream.writer(w.io, &write_buffer);

        while (w.timeLeft()) {
            const start = Io.Timestamp.now(w.io, .awake);
            try writer.interface.writeAll(w.options.request);
            try writer.interface.flush();
            try readResponse(&reader.interface);
            const micros = start.untilNow(w.io, .awake).toMicroseconds();
            try w.latencies.append(w.gpa, @intCast(micros));
        }
    }

    fn timeLeft(w: *const Worker) bool {
        return Io.Timestamp.now(w.io, .awake).compare(.lt, w.deadline);
    }
};

/// Reads one response with a `content-length` body. Non-2xx is an error.
fn readResponse(r: *Io.Reader) !void {
    const status_line = try r.takeDelimiterInclusive('\n');
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 2")) return error.BadStatus;

    var content_length: usize = 0;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        if (line.len <= 2) break;
        const prefix = "content-length:";
        if (std.ascii.startsWithIgnoreCase(line, prefix)) {
            const value = std.mem.trim(u8, line[prefix.len..], " \t\r\n");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    try r.discardAll(content_length);
}

test readResponse {
    var reader: Io.Reader = .fixed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1 404 Not Found\r\n\r\n");
    try readResponse(&reader);
    try std.testing.expectError(error.BadStatus, readResponse(&reader));
}
