//! Retry policy: which failures are retried and how long to wait. Pure functions.

const std = @import("std");
const Io = std.Io;
const Method = std.http.Method;
const Status = std.http.Status;

pub const Retry = struct {
    /// Total tries including the first. 1 disables retries.
    max_attempts: u8 = 3,
    base_delay: Io.Duration = .fromMilliseconds(100),
    max_delay: Io.Duration = .fromSeconds(2),
    /// Also retry POST and PATCH. Only safe if the server deduplicates.
    retry_non_idempotent: bool = false,
};

/// The result of one attempt, as far as retrying is concerned.
pub const Outcome = union(enum) {
    /// The attempt failed with a transport-level error (see `isTransient`).
    failed: anyerror,
    /// A response arrived. `retry_after` is the raw `Retry-After` header.
    status: struct { code: Status, retry_after: ?[]const u8 = null },
};

pub const Attempt = struct {
    /// 1 for the first try.
    number: u8,
    method: Method,
    /// False for bodies that can't be sent twice (streams).
    replayable: bool,
    outcome: Outcome,
};

/// How long to wait before the next attempt, or null to stop and return the
/// outcome as-is. `random` supplies the jitter.
pub fn nextDelay(config: Retry, attempt: Attempt, random: u64) ?Io.Duration {
    if (attempt.number >= config.max_attempts) return null;
    if (!attempt.replayable) return null;
    if (!config.retry_non_idempotent and !isIdempotent(attempt.method)) return null;

    switch (attempt.outcome) {
        .failed => |err| {
            if (!isTransient(err)) return null;
            return backoff(config, attempt.number, random);
        },
        .status => |status| {
            if (!isRetryableStatus(status.code)) return null;
            const server_hint = parseRetryAfter(status.retry_after) orelse return backoff(config, attempt.number, random);
            return min(server_hint, config.max_delay);
        },
    }
}

/// Exponential backoff with full jitter: a random wait in
/// `[0, min(max_delay, base_delay * 2^(attempt-1))]`.
fn backoff(config: Retry, attempt: u8, random: u64) Io.Duration {
    const base: u64 = @intCast(config.base_delay.toNanoseconds());
    const cap: u64 = @intCast(config.max_delay.toNanoseconds());
    const shift: u6 = @intCast(@min(attempt - 1, 32));
    const ceiling = @min(cap, std.math.shl(u64, base, shift));
    return .fromNanoseconds(random % (ceiling + 1));
}

/// Methods that have the same effect when sent twice.
fn isIdempotent(method: Method) bool {
    return switch (method) {
        .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE, .QUERY => true,
        .POST, .PATCH, .CONNECT => false,
    };
}

fn isRetryableStatus(status: Status) bool {
    return switch (status) {
        .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout => true,
        else => false,
    };
}

/// Errors where trying again might succeed.
fn isTransient(err: anyerror) bool {
    return err == error.Timeout or err == error.UpstreamUnavailable;
}

/// Only the seconds form (`Retry-After: 3`) is supported; dates are ignored.
fn parseRetryAfter(value: ?[]const u8) ?Io.Duration {
    const text = value orelse return null;
    const seconds = std.fmt.parseInt(u32, std.mem.trim(u8, text, " "), 10) catch return null;
    return .fromSeconds(seconds);
}

fn min(a: Io.Duration, b: Io.Duration) Io.Duration {
    return if (a.toNanoseconds() < b.toNanoseconds()) a else b;
}

const testing = std.testing;

fn attemptWith(number: u8, method: Method, outcome: Outcome) Attempt {
    return .{ .number = number, .method = method, .replayable = true, .outcome = outcome };
}

test "retries transient failures and retryable statuses" {
    const config: Retry = .{};
    try testing.expect(nextDelay(config, attemptWith(1, .GET, .{ .failed = error.UpstreamUnavailable }), 0) != null);
    try testing.expect(nextDelay(config, attemptWith(1, .GET, .{ .failed = error.Timeout }), 0) != null);
    try testing.expect(nextDelay(config, attemptWith(1, .GET, .{ .status = .{ .code = .service_unavailable } }), 0) != null);
}

test "does not retry" {
    const config: Retry = .{};
    // Last attempt.
    try testing.expectEqual(null, nextDelay(config, attemptWith(3, .GET, .{ .failed = error.Timeout }), 0));
    // Non-idempotent method.
    try testing.expectEqual(null, nextDelay(config, attemptWith(1, .POST, .{ .failed = error.Timeout }), 0));
    // Permanent error and success / client-error statuses.
    try testing.expectEqual(null, nextDelay(config, attemptWith(1, .GET, .{ .failed = error.InvalidRequest }), 0));
    try testing.expectEqual(null, nextDelay(config, attemptWith(1, .GET, .{ .status = .{ .code = .ok } }), 0));
    try testing.expectEqual(null, nextDelay(config, attemptWith(1, .GET, .{ .status = .{ .code = .bad_request } }), 0));
    // Streams can't be replayed.
    var stream_attempt = attemptWith(1, .PUT, .{ .failed = error.Timeout });
    stream_attempt.replayable = false;
    try testing.expectEqual(null, nextDelay(config, stream_attempt, 0));
    // Opt-in for POST.
    try testing.expect(nextDelay(.{ .retry_non_idempotent = true }, attemptWith(1, .POST, .{ .failed = error.Timeout }), 0) != null);
}

test "backoff grows, is capped, and honours Retry-After" {
    const config: Retry = .{ .base_delay = .fromMilliseconds(100), .max_delay = .fromSeconds(1) };
    const huge = std.math.maxInt(u64) - 1;
    const timeout: Outcome = .{ .failed = error.Timeout };
    // With maximal jitter the delay hits the ceiling: 100ms, 200ms, 400ms, then the 1s cap.
    try testing.expectEqual(100, nextDelay(config, attemptWith(1, .GET, timeout), 100_000_000).?.toMilliseconds());
    try testing.expectEqual(200, nextDelay(config, attemptWith(2, .GET, timeout), 200_000_000).?.toMilliseconds());
    const capped: Retry = .{ .max_attempts = 10, .base_delay = .fromMilliseconds(100), .max_delay = .fromSeconds(1) };
    try testing.expect(nextDelay(capped, attemptWith(8, .GET, timeout), huge).?.toMilliseconds() <= 1000);

    const limited: Outcome = .{ .status = .{ .code = .too_many_requests, .retry_after = "3" } };
    try testing.expectEqual(1000, nextDelay(config, attemptWith(1, .GET, limited), 0).?.toMilliseconds());
    const roomy: Retry = .{ .max_delay = .fromSeconds(10) };
    try testing.expectEqual(3000, nextDelay(roomy, attemptWith(1, .GET, limited), 0).?.toMilliseconds());
}
