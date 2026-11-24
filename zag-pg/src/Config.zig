//! Connection settings, set directly or parsed from a `postgres://` URL.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Config = @This();

host: []const u8 = "127.0.0.1",
port: u16 = 5432,
user: []const u8,
password: ?[]const u8 = null,
/// Defaults to `user`, like libpq.
database: ?[]const u8 = null,
application_name: []const u8 = "zag-pg",
/// Sent as the `statement_timeout` startup parameter; the server cancels
/// slower statements with `error.QueryTimeout`. null = server default.
statement_timeout: ?Io.Duration = .fromSeconds(30),
connect_timeout: Io.Duration = .fromSeconds(10),
/// Cleartext password auth sends the password as-is; refused unless set.
allow_cleartext_password: bool = false,

pub const ParseError = error{ InvalidUrl, OutOfMemory };

/// Parses `postgres://user:password@host:port/database?application_name=x`.
/// Strings are percent-decoded into `arena`.
pub fn parseUrl(arena: Allocator, url: []const u8) ParseError!Config {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const is_postgres = std.mem.eql(u8, uri.scheme, "postgres") or std.mem.eql(u8, uri.scheme, "postgresql");
    if (!is_postgres) return error.InvalidUrl;

    var config: Config = .{ .user = try component(arena, uri.user) orelse return error.InvalidUrl };
    config.password = try component(arena, uri.password);
    if (try component(arena, uri.host)) |host| config.host = host;
    if (uri.port) |port| config.port = port;

    const path = try component(arena, uri.path) orelse "";
    const database = std.mem.trimStart(u8, path, "/");
    if (database.len > 0) config.database = database;

    if (try component(arena, uri.query)) |query| try applyQuery(&config, query);
    return config;
}

/// Supported: `application_name`, `sslmode=disable|prefer` (TLS is not
/// implemented yet, so `require` and stricter are rejected).
fn applyQuery(config: *Config, query: []const u8) ParseError!void {
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse return error.InvalidUrl;
        const name = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, name, "application_name")) {
            config.application_name = value;
        } else if (std.mem.eql(u8, name, "sslmode")) {
            const plain = std.mem.eql(u8, value, "disable") or std.mem.eql(u8, value, "prefer") or std.mem.eql(u8, value, "allow");
            if (!plain) return error.InvalidUrl;
        } else {
            return error.InvalidUrl;
        }
    }
}

fn component(arena: Allocator, value: ?std.Uri.Component) error{OutOfMemory}!?[]const u8 {
    const c = value orelse return null;
    const text = try c.toRawMaybeAlloc(arena);
    if (text.len == 0) return null;
    return text;
}

const testing = std.testing;

test parseUrl {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const full = try parseUrl(arena, "postgres://app:p%40ss@db.internal:6543/main?application_name=api&sslmode=disable");
    try testing.expectEqualStrings("app", full.user);
    try testing.expectEqualStrings("p@ss", full.password.?);
    try testing.expectEqualStrings("db.internal", full.host);
    try testing.expectEqual(6543, full.port);
    try testing.expectEqualStrings("main", full.database.?);
    try testing.expectEqualStrings("api", full.application_name);

    const minimal = try parseUrl(arena, "postgresql://zag@localhost");
    try testing.expectEqual(5432, minimal.port);
    try testing.expectEqual(null, minimal.database);
    try testing.expectEqual(null, minimal.password);

    try testing.expectError(error.InvalidUrl, parseUrl(arena, "mysql://a@b/c"));
    try testing.expectError(error.InvalidUrl, parseUrl(arena, "postgres://host-only"));
    try testing.expectError(error.InvalidUrl, parseUrl(arena, "postgres://a@b/c?sslmode=require"));
}
