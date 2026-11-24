//! Benchmark runner: starts `bench-server`, runs each scenario with `load.zig`,
//! and prints throughput, latency and peak memory.
//!
//! Usage: bench <server-exe> [--connections N] [--duration SECONDS] [--only NAME]

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const load = @import("load.zig");

const port = 3900;
const warmup_seconds = 1;

const Scenario = struct { name: []const u8, about: []const u8, request: []const u8 };

const scenarios = [_]Scenario{
    .{ .name = "plaintext", .about = "static text", .request = get("/plaintext") },
    .{ .name = "json", .about = "serialize a small struct", .request = get("/json") },
    .{ .name = "params", .about = "path + query extractors", .request = get("/users/42/posts/hello-world?limit=5") },
    .{ .name = "echo", .about = "parse + serialize JSON body", .request = post("/echo", "{\"name\":\"zag\",\"tags\":[\"fast\",\"small\"],\"count\":3}") },
    .{ .name = "backend", .about = "outbound HTTP call + 6 KB JSON parse", .request = get("/element?symbol=He") },
};

const Options = struct {
    server_exe: []const u8,
    connections: usize = 32,
    duration_seconds: i64 = 5,
    only: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const options = try parseArgs(try init.minimal.args.toSlice(init.arena.allocator()));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var server = try startServer(io, options.server_exe);
    defer server.kill(io);
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    try waitReady(io, address);

    try out.print("zag-http bench · {d} connections · {d}s per scenario (+{d}s warmup) · ReleaseFast\n\n", .{
        options.connections, options.duration_seconds, warmup_seconds,
    });
    try out.writeAll("| scenario  |     req/s |     p50 |     p99 |     max | errors | peak RSS | what it measures\n");
    try out.writeAll("|-----------|-----------|---------|---------|---------|--------|----------|-----------------\n");
    try out.flush();

    const bench: Bench = .{ .io = io, .gpa = gpa, .out = out, .pid = server.id.?, .address = address, .options = options };
    for (scenarios) |scenario| {
        if (options.only) |only| if (!std.mem.eql(u8, only, scenario.name)) continue;
        try bench.runScenario(scenario);
        try out.flush();
    }
    try out.writeAll("\nThe load generator runs on the same machine and competes for CPU; compare runs on the same machine only.\n");
    try out.flush();
}

/// Everything a scenario run needs.
const Bench = struct {
    io: Io,
    gpa: Allocator,
    out: *Io.Writer,
    pid: std.process.Child.Id,
    address: Io.net.IpAddress,
    options: Options,

    /// Warms up, measures with RSS sampling, and prints one table row.
    fn runScenario(b: Bench, scenario: Scenario) !void {
        const load_options: load.Options = .{
            .address = b.address,
            .request = scenario.request,
            .connections = b.options.connections,
            .duration = .fromSeconds(warmup_seconds),
        };
        var warmup = try load.run(b.io, b.gpa, load_options);
        warmup.deinit(b.gpa);

        var sampler: RssSampler = .{ .io = b.io, .gpa = b.gpa, .pid = b.pid };
        var sampling = try b.io.concurrent(RssSampler.run, .{&sampler});
        const measured = load.run(b.io, b.gpa, withDuration(load_options, b.options.duration_seconds));
        sampler.stop.store(true, .release);
        sampling.await(b.io);
        var result = try measured;
        defer result.deinit(b.gpa);
        try b.printRow(scenario, result, sampler.peak_kb);
    }

    fn printRow(b: Bench, scenario: Scenario, result: load.Result, peak_kb: u64) !void {
        var p50: [16]u8 = undefined;
        var p99: [16]u8 = undefined;
        var max: [16]u8 = undefined;
        try b.out.print("| {s:<9} | {d:>9.0} | {s:>7} | {s:>7} | {s:>7} | {d:>6} | {d:>5.1} MB | {s}\n", .{
            scenario.name,
            result.rps(),
            formatMicros(&p50, result.percentile(0.50)),
            formatMicros(&p99, result.percentile(0.99)),
            formatMicros(&max, result.percentile(1.0)),
            result.errors,
            @as(f64, @floatFromInt(peak_kb)) / 1024,
            scenario.about,
        });
    }
};

fn withDuration(options: load.Options, seconds: i64) load.Options {
    var copy = options;
    copy.duration = .fromSeconds(seconds);
    return copy;
}

/// Samples the server's resident memory every 100 ms while load runs.
const RssSampler = struct {
    io: Io,
    gpa: Allocator,
    pid: std.process.Child.Id,
    stop: std.atomic.Value(bool) = .init(false),
    peak_kb: u64 = 0,

    fn run(s: *RssSampler) void {
        while (!s.stop.load(.acquire)) {
            const kb = readRssKb(s.io, s.gpa, s.pid) catch 0;
            s.peak_kb = @max(s.peak_kb, kb);
            s.io.sleep(.fromMilliseconds(100), .awake) catch return;
        }
    }
};

/// Asks `ps` (macOS and Linux) for the resident set size in KB.
fn readRssKb(io: Io, gpa: Allocator, pid: std.process.Child.Id) !u64 {
    var pid_buffer: [16]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "ps", "-o", "rss=", "-p", pid_text } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return std.fmt.parseInt(u64, std.mem.trim(u8, result.stdout, " \t\r\n"), 10);
}

fn startServer(io: Io, exe: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ exe, std.fmt.comptimePrint("{d}", .{port}) },
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// Retries connecting for up to 5 seconds.
fn waitReady(io: Io, address: Io.net.IpAddress) !void {
    for (0..100) |_| {
        if (address.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
            return;
        } else |_| {
            try io.sleep(.fromMilliseconds(50), .awake);
        }
    }
    return error.ServerDidNotStart;
}

fn parseArgs(args: []const []const u8) !Options {
    if (args.len < 2) return error.MissingServerExe;
    var options: Options = .{ .server_exe = args[1] };
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--connections")) {
            options.connections = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, flag, "--duration")) {
            options.duration_seconds = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, flag, "--only")) {
            options.only = value;
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

fn formatMicros(buffer: []u8, micros: u32) []const u8 {
    const result = if (micros < 1000)
        std.fmt.bufPrint(buffer, "{d}us", .{micros})
    else
        std.fmt.bufPrint(buffer, "{d:.2}ms", .{@as(f64, @floatFromInt(micros)) / 1000});
    return result catch "?";
}

fn get(comptime path: []const u8) []const u8 {
    return "GET " ++ path ++ " HTTP/1.1\r\nhost: bench\r\n\r\n";
}

fn post(comptime path: []const u8, comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "POST {s} HTTP/1.1\r\nhost: bench\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ path, body.len, body },
    );
}
