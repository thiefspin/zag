//! The authentication exchange after the startup message.
//! Supports SCRAM-SHA-256, MD5 and (opt-in) cleartext passwords.

const std = @import("std");
const Conn = @import("Conn.zig");
const Config = @import("Config.zig");
const protocol = @import("protocol.zig");
const scram = @import("scram.zig");

const log = std.log.scoped(.zag_pg);

// AuthenticationRequest codes.
const ok = 0;
const cleartext = 3;
const md5 = 5;
const sasl = 10;
const sasl_continue = 11;
const sasl_final = 12;

/// Runs until the server sends AuthenticationOk.
pub fn authenticate(conn: *Conn, config: Config) Conn.Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(conn.gpa);
    defer arena_state.deinit();
    var p = try request(conn);
    const code = try p.int32();
    switch (code) {
        ok => return,
        cleartext => try sendCleartext(conn, config),
        md5 => try sendMd5(conn, config, try p.take(4)),
        sasl => try runScram(conn, config, arena_state.allocator(), p.rest()),
        else => return refuse(conn, "unsupported authentication method {d}", .{code}),
    }
    p = try request(conn);
    if (try p.int32() != ok) return conn.protocolViolation('R');
}

/// Reads an AuthenticationRequest; the parser is positioned at its code.
fn request(conn: *Conn) Conn.Error!protocol.Parser {
    const message = try conn.read();
    switch (message.tag) {
        'R' => return message.parser(),
        'E' => return conn.startupFailed(message),
        else => return conn.protocolViolation(message.tag),
    }
}

fn password(conn: *Conn, config: Config) Conn.Error![]const u8 {
    return config.password orelse refuse(conn, "server requires a password and none is configured", .{});
}

fn sendPassword(conn: *Conn, value: []const u8) Conn.Error!void {
    try conn.out.begin('p');
    try conn.out.cstring(value);
    try conn.sendAndFlush();
}

fn sendCleartext(conn: *Conn, config: Config) Conn.Error!void {
    if (!config.allow_cleartext_password) {
        return refuse(conn, "server asked for a cleartext password; set allow_cleartext_password to allow it", .{});
    }
    try sendPassword(conn, try password(conn, config));
}

fn sendMd5(conn: *Conn, config: Config, salt: []const u8) Conn.Error!void {
    const hashed = scram.md5Password(config.user, try password(conn, config), salt[0..4].*);
    try sendPassword(conn, &hashed);
}

fn runScram(conn: *Conn, config: Config, arena: std.mem.Allocator, mechanisms: []const u8) Conn.Error!void {
    if (std.mem.find(u8, mechanisms, scram.mechanism ++ "\x00") == null) {
        return refuse(conn, "server offers no supported SASL mechanism", .{});
    }
    var random: [18]u8 = undefined;
    conn.io.random(&random);
    var client: scram.Scram = .{
        .arena = arena,
        .user = "", // Postgres uses the startup user
        .password = try password(conn, config),
        .client_nonce = try scram.makeNonce(arena, random),
    };

    // SASLInitialResponse: mechanism, then the client-first message.
    const first = try client.clientFirst();
    try conn.out.begin('p');
    try conn.out.cstring(scram.mechanism);
    try conn.out.int32(@intCast(first.len));
    try conn.out.raw(first);
    try conn.sendAndFlush();

    const server_first = try saslData(conn, sasl_continue);
    const final = client.clientFinal(server_first) catch return refuse(conn, "invalid SCRAM challenge", .{});
    try conn.out.begin('p'); // SASLResponse
    try conn.out.raw(final);
    try conn.sendAndFlush();

    const server_final = try saslData(conn, sasl_final);
    client.verifyServerFinal(server_final) catch return refuse(conn, "server failed SCRAM verification", .{});
}

fn saslData(conn: *Conn, expected: i32) Conn.Error![]const u8 {
    var p = try request(conn);
    if (try p.int32() != expected) return conn.protocolViolation('R');
    return p.rest();
}

fn refuse(conn: *Conn, comptime reason: []const u8, args: anytype) Conn.Error {
    log.debug(reason, args);
    conn.broken = true;
    return error.AuthenticationFailed;
}
