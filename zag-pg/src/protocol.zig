//! Postgres wire protocol v3 framing: building frontend messages and reading
//! backend messages. No I/O decisions here beyond reading/writing bytes.
//! Reference: https://www.postgresql.org/docs/current/protocol-message-formats.html

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const protocol_version: u32 = 196608; // 3.0

pub const Error = error{ProtocolViolation};

/// Builds one frontend message in a reusable buffer, then writes it with its
/// length prefix. Usage: `begin(tag)`, add fields, `send(writer)`.
pub const Builder = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Where the 4-byte length goes: after the tag, or at 0 for startup.
    length_at: usize = 0,

    pub fn deinit(self: *Builder) void {
        self.bytes.deinit(self.gpa);
    }

    /// Starts a message. Only the startup message has no tag (`null`).
    pub fn begin(self: *Builder, tag: ?u8) Allocator.Error!void {
        self.bytes.clearRetainingCapacity();
        if (tag) |t| try self.bytes.append(self.gpa, t);
        self.length_at = self.bytes.items.len;
        try self.int32(0); // patched in `finish`
    }

    pub fn int16(self: *Builder, value: i16) Allocator.Error!void {
        try self.bytes.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToBig(i16, value)));
    }

    pub fn int32(self: *Builder, value: i32) Allocator.Error!void {
        try self.bytes.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToBig(i32, value)));
    }

    pub fn cstring(self: *Builder, value: []const u8) Allocator.Error!void {
        try self.bytes.appendSlice(self.gpa, value);
        try self.bytes.append(self.gpa, 0);
    }

    pub fn raw(self: *Builder, value: []const u8) Allocator.Error!void {
        try self.bytes.appendSlice(self.gpa, value);
    }

    /// Patches the length (which excludes the tag) and returns the message.
    pub fn finish(self: *Builder) []const u8 {
        const length: i32 = @intCast(self.bytes.items.len - self.length_at);
        self.bytes.items[self.length_at..][0..4].* = std.mem.toBytes(std.mem.nativeToBig(i32, length));
        return self.bytes.items;
    }

    /// Appends the finished message to `w` (not flushed).
    pub fn send(self: *Builder, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(self.finish());
    }
};

/// One backend message. `body` is valid until the next read.
pub const Message = struct {
    tag: u8,
    body: []const u8,

    pub fn parser(self: Message) Parser {
        return .{ .bytes = self.body };
    }
};

/// Reads the next backend message. Bodies larger than the reader's buffer are
/// read into `large`, which grows as needed and is reused.
pub fn readMessage(r: *Io.Reader, gpa: Allocator, large: *std.ArrayList(u8)) !Message {
    const tag = try r.takeByte();
    const length = try r.takeInt(u32, .big);
    if (length < 4) return error.ProtocolViolation;
    const body_len = length - 4;
    if (body_len <= r.buffer.len) return .{ .tag = tag, .body = try r.take(body_len) };

    try large.resize(gpa, body_len);
    try r.readSliceAll(large.items);
    return .{ .tag = tag, .body = large.items };
}

/// Reads fields from a message body. Every read is bounds-checked.
pub const Parser = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn int16(self: *Parser) Error!i16 {
        const slice = try self.take(2);
        return std.mem.readInt(i16, slice[0..2], .big);
    }

    pub fn int32(self: *Parser) Error!i32 {
        const slice = try self.take(4);
        return std.mem.readInt(i32, slice[0..4], .big);
    }

    pub fn byte(self: *Parser) Error!u8 {
        return (try self.take(1))[0];
    }

    /// A NUL-terminated string, without the NUL.
    pub fn cstring(self: *Parser) Error![]const u8 {
        const remaining = self.bytes[self.pos..];
        const end = std.mem.findScalar(u8, remaining, 0) orelse return error.ProtocolViolation;
        self.pos += end + 1;
        return remaining[0..end];
    }

    pub fn take(self: *Parser, n: usize) Error![]const u8 {
        if (self.bytes.len - self.pos < n) return error.ProtocolViolation;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    pub fn rest(self: *Parser) []const u8 {
        defer self.pos = self.bytes.len;
        return self.bytes[self.pos..];
    }
};

const testing = std.testing;

test "builder frames tagged and startup messages" {
    var b: Builder = .{ .gpa = testing.allocator };
    defer b.deinit();

    try b.begin('Q');
    try b.cstring("select 1");
    try testing.expectEqualSlices(u8, "Q\x00\x00\x00\x0dselect 1\x00", b.finish());

    try b.begin(null);
    try b.int32(protocol_version);
    try b.cstring("user");
    try b.cstring("zag");
    try b.raw(&.{0});
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x12\x00\x03\x00\x00user\x00zag\x00\x00", b.finish());
}

test readMessage {
    var r: Io.Reader = .fixed("Z\x00\x00\x00\x05I" ++ "C\x00\x00\x00\x0dSELECT 1\x00");
    var large: std.ArrayList(u8) = .empty;
    defer large.deinit(testing.allocator);

    const ready = try readMessage(&r, testing.allocator, &large);
    try testing.expectEqual('Z', ready.tag);
    try testing.expectEqualStrings("I", ready.body);
    const complete = try readMessage(&r, testing.allocator, &large);
    try testing.expectEqual('C', complete.tag);
    try testing.expectEqualStrings("SELECT 1\x00", complete.body);
}

test Parser {
    var p: Parser = .{ .bytes = "\x00\x02\x00\x00\x00\x07name\x00rest" };
    try testing.expectEqual(2, try p.int16());
    try testing.expectEqual(7, try p.int32());
    try testing.expectEqualStrings("name", try p.cstring());
    try testing.expectEqualStrings("rest", p.rest());
    try testing.expectError(error.ProtocolViolation, p.int16());
}
