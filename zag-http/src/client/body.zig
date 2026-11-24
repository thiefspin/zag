//! Request bodies: what a client request can send, and how each kind is written.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const StdRequest = std.http.Client.Request;
const url = @import("url.zig");

pub const Param = url.Param;

/// One field of a `multipart/form-data` body.
pub const Part = struct {
    name: []const u8,
    /// Set for file uploads; makes servers treat the part as a file.
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: union(enum) {
        bytes: []const u8,
        /// Read to the end while sending. Makes the request non-retryable.
        reader: *Io.Reader,
    },
};

pub const Body = union(enum) {
    none,
    bytes: struct { data: []const u8, content_type: []const u8 = "application/octet-stream" },
    /// `application/x-www-form-urlencoded`.
    form: []const Param,
    /// `multipart/form-data`.
    multipart: []const Part,
    /// Read to the end while sending. Not retryable. Without `length` it is
    /// sent with chunked transfer encoding.
    stream: struct {
        reader: *Io.Reader,
        length: ?u64 = null,
        content_type: []const u8 = "application/octet-stream",
    },

    /// A JSON body. The encoded bytes are allocated in `arena`.
    pub fn json(arena: Allocator, value: anytype) error{OutOfMemory}!Body {
        const data = try std.json.Stringify.valueAlloc(arena, value, .{});
        return .{ .bytes = .{ .data = data, .content_type = "application/json" } };
    }

    /// Whether the body can be sent again on retry.
    pub fn isReplayable(body: Body) bool {
        return switch (body) {
            .none, .bytes, .form => true,
            .stream => false,
            .multipart => |parts| !hasReaderPart(parts),
        };
    }

    /// Rejects multipart field values that would break the encoding.
    pub fn validate(body: Body) error{InvalidRequest}!void {
        const parts = switch (body) {
            .multipart => |parts| parts,
            else => return,
        };
        for (parts) |part| {
            if (!isSafeToken(part.name)) return error.InvalidRequest;
            if (part.filename) |name| if (!isSafeToken(name)) return error.InvalidRequest;
            if (part.content_type) |ct| if (!isSafeToken(ct)) return error.InvalidRequest;
        }
    }
};

/// Sends `body` on `request` (head included) and flushes.
pub fn send(request: *StdRequest, arena: Allocator, io: Io, body: Body) !void {
    switch (body) {
        .none => return request.sendBodiless(),
        .bytes => |b| return sendBytes(request, b.content_type, b.data),
        .form => |params| return sendBytes(request, "application/x-www-form-urlencoded", try url.encodePairs(arena, params)),
        .multipart => |parts| return sendMultipart(request, arena, io, parts),
        .stream => |s| return sendStream(request, s.content_type, s.reader, s.length),
    }
}

fn sendBytes(request: *StdRequest, content_type: []const u8, data: []const u8) !void {
    request.headers.content_type = .{ .override = content_type };
    request.transfer_encoding = .{ .content_length = data.len };
    var body_writer = try request.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(data);
    try body_writer.end();
    try request.connection.?.flush();
}

fn sendStream(request: *StdRequest, content_type: []const u8, reader: *Io.Reader, length: ?u64) !void {
    request.headers.content_type = .{ .override = content_type };
    request.transfer_encoding = if (length) |len| .{ .content_length = len } else .chunked;
    var buffer: [4096]u8 = undefined;
    var body_writer = try request.sendBodyUnflushed(&buffer);
    _ = try reader.streamRemaining(&body_writer.writer);
    try body_writer.end();
    try request.connection.?.flush();
}

fn sendMultipart(request: *StdRequest, arena: Allocator, io: Io, parts: []const Part) !void {
    const boundary = try makeBoundary(arena, io, parts);
    request.headers.content_type = .{ .override = try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{boundary}) };
    request.transfer_encoding = if (multipartLength(parts, boundary)) |len| .{ .content_length = len } else .chunked;
    var buffer: [4096]u8 = undefined;
    var body_writer = try request.sendBodyUnflushed(&buffer);
    try writeMultipart(&body_writer.writer, parts, boundary);
    try body_writer.end();
    try request.connection.?.flush();
}

/// Writes the multipart encoding of `parts` (RFC 7578).
pub fn writeMultipart(w: *Io.Writer, parts: []const Part, boundary: []const u8) !void {
    for (parts) |part| {
        try w.print("--{s}\r\ncontent-disposition: form-data; name=\"{s}\"", .{ boundary, part.name });
        if (part.filename) |filename| try w.print("; filename=\"{s}\"", .{filename});
        try w.writeAll("\r\n");
        if (part.content_type) |content_type| try w.print("content-type: {s}\r\n", .{content_type});
        try w.writeAll("\r\n");
        switch (part.data) {
            .bytes => |bytes| try w.writeAll(bytes),
            .reader => |reader| _ = try reader.streamRemaining(w),
        }
        try w.writeAll("\r\n");
    }
    try w.print("--{s}--\r\n", .{boundary});
}

/// Exact encoded size, or null if a part is a reader (size unknown).
fn multipartLength(parts: []const Part, boundary: []const u8) ?u64 {
    if (hasReaderPart(parts)) return null;
    var counter: Io.Writer.Discarding = .init(&.{});
    // Discarding never fails and there are no readers to fail.
    writeMultipart(&counter.writer, parts, boundary) catch unreachable;
    return counter.fullCount();
}

/// A random boundary that doesn't occur in any `bytes` part.
fn makeBoundary(arena: Allocator, io: Io, parts: []const Part) ![]const u8 {
    while (true) {
        var random: [16]u8 = undefined;
        io.random(&random);
        const boundary = try std.fmt.allocPrint(arena, "zag-{x}", .{&random});
        if (!occursInParts(parts, boundary)) return boundary;
    }
}

fn occursInParts(parts: []const Part, boundary: []const u8) bool {
    for (parts) |part| switch (part.data) {
        .bytes => |bytes| if (std.mem.find(u8, bytes, boundary) != null) return true,
        .reader => {},
    };
    return false;
}

fn hasReaderPart(parts: []const Part) bool {
    for (parts) |part| if (part.data == .reader) return true;
    return false;
}

/// No quotes or line breaks, which would break out of the part headers.
fn isSafeToken(value: []const u8) bool {
    return std.mem.findAny(u8, value, "\"\r\n") == null;
}

const testing = std.testing;

test writeMultipart {
    var reader: Io.Reader = .fixed("streamed");
    const parts = [_]Part{
        .{ .name = "title", .data = .{ .bytes = "hi" } },
        .{ .name = "file", .filename = "a.txt", .content_type = "text/plain", .data = .{ .reader = &reader } },
    };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeMultipart(&out.writer, &parts, "B");
    try testing.expectEqualStrings(
        "--B\r\ncontent-disposition: form-data; name=\"title\"\r\n\r\nhi\r\n" ++
            "--B\r\ncontent-disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\ncontent-type: text/plain\r\n\r\nstreamed\r\n" ++
            "--B--\r\n",
        out.written(),
    );
}

test multipartLength {
    const parts = [_]Part{.{ .name = "a", .data = .{ .bytes = "12345" } }};
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeMultipart(&out.writer, &parts, "xyz");
    try testing.expectEqual(out.written().len, multipartLength(&parts, "xyz").?);
}

test "replayable and validate" {
    var reader: Io.Reader = .fixed("x");
    const with_reader: Body = .{ .multipart = &.{.{ .name = "f", .data = .{ .reader = &reader } }} };
    try testing.expect(!with_reader.isReplayable());
    try testing.expect((Body{ .form = &.{} }).isReplayable());

    const bad: Body = .{ .multipart = &.{.{ .name = "a\"b", .data = .{ .bytes = "" } }} };
    try testing.expectError(error.InvalidRequest, bad.validate());
}
