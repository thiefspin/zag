//! Integration tests against a real Postgres (`make pg-up`). The URL comes
//! from ZAG_PG_TEST_URL; when nothing is listening the tests are skipped,
//! unless ZAG_PG_REQUIRE is set (CI sets it, so a missing database fails).

const std = @import("std");
const testing = std.testing;
const pg = @import("root.zig");

const default_url = "postgres://zag:zag@127.0.0.1:54329/zag";

fn testUrl() []const u8 {
    return testing.environ.getPosix("ZAG_PG_TEST_URL") orelse default_url;
}

/// Skips the test because Postgres is unreachable, or fails it on CI.
fn noDatabase() error{ SkipZigTest, DatabaseUnavailable } {
    if (testing.environ.getPosix("ZAG_PG_REQUIRE") != null) return error.DatabaseUnavailable;
    return error.SkipZigTest;
}

const Fixture = struct {
    pool: pg.Pool,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Fixture, options: pg.Pool.Options) !void {
        var opts = options;
        if (opts.url == null and opts.config == null) opts.url = testUrl();
        self.pool = try .init(testing.io, testing.allocator, opts);
        errdefer self.pool.deinit();
        self.arena_state = .init(testing.allocator);
        self.pool.execScript("select 1") catch |err| switch (err) {
            error.ConnectionFailed => return noDatabase(),
            else => return err,
        };
    }

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
        self.pool.deinit();
    }

    fn arena(self: *Fixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

test "query, queryOne, get and exec" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();

    try f.pool.execScript(
        \\create temp table if not exists people (id int8 primary key, name text not null, email text, active bool not null);
        \\truncate people;
    );
    // Temp tables are per connection; with one pooled connection that's fine,
    // but use a real table for anything that spans connections.
    try testing.expectEqual(2, try f.pool.exec("insert into people values ($1, $2, $3, $4), (2, 'grace', null, false)", .{ 1, "ada", "ada@example.com", true }));

    const Person = struct { id: i64, name: []const u8, email: ?[]const u8, active: bool };
    const people = try f.pool.query(Person, f.arena(), "select * from people order by id", .{});
    try testing.expectEqual(2, people.len);
    try testing.expectEqualStrings("ada@example.com", people[0].email.?);
    try testing.expectEqual(null, people[1].email);
    try testing.expect(!people[1].active);

    const grace = try f.pool.get(Person, f.arena(), "select * from people where name = $1", .{"grace"});
    try testing.expectEqual(2, grace.id);
    try testing.expectEqual(null, try f.pool.queryOne(Person, f.arena(), "select * from people where id = $1", .{99}));
    try testing.expectError(error.NotFound, f.pool.get(Person, f.arena(), "select * from people where id = $1", .{99}));
}

test "types round trip" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();

    const Mood = enum { happy, sad };
    const Row = struct {
        small: i16,
        big: i64,
        ratio: f64,
        flag: bool,
        mood: Mood,
        blob: []const u8,
        doc: pg.Json(struct { tags: []const []const u8 }),
        nothing: ?i32,
        unicode: []const u8,
    };
    const row = try f.pool.get(Row, f.arena(),
        \\select $1::int2 as small, $2::int8 as big, $3::float8 as ratio, $4::bool as flag,
        \\  $5::text as mood, decode('7a6167', 'hex') as blob, $6::jsonb as doc,
        \\  $7::int4 as nothing, $8::text as unicode
    , .{
        -12,                                                                                  std.math.maxInt(i64), 0.25, true, Mood.sad,
        pg.Json(struct { tags: []const []const u8 }){ .value = .{ .tags = &.{ "a", "b" } } }, @as(?i32, null),
        "zig ⚡ postgres",
    });
    try testing.expectEqual(-12, row.small);
    try testing.expectEqual(std.math.maxInt(i64), row.big);
    try testing.expectEqual(0.25, row.ratio);
    try testing.expect(row.flag);
    try testing.expectEqual(.sad, row.mood);
    try testing.expectEqualStrings("zag", row.blob);
    try testing.expectEqualStrings("b", row.doc.value.tags[1]);
    try testing.expectEqual(null, row.nothing);
    try testing.expectEqualStrings("zig ⚡ postgres", row.unicode);
}

test "server errors map to Zig errors and keep the connection usable" {
    var f: Fixture = undefined;
    try f.init(.{ .max_connections = 1 });
    defer f.deinit();

    try f.pool.execScript("create temp table uniq (k text primary key); insert into uniq values ('a');");
    try testing.expectError(error.UniqueViolation, f.pool.exec("insert into uniq values ($1)", .{"a"}));
    try testing.expectError(error.QueryFailed, f.pool.exec("selec nonsense", .{}));
    try testing.expectError(error.ConstraintViolation, f.pool.exec("insert into uniq values ($1)", .{@as(?[]const u8, null)}));

    const conn = try f.pool.acquire();
    defer f.pool.release(conn);
    try testing.expectError(error.QueryTimeout, conn.execScript("set statement_timeout = 50; select pg_sleep(1)"));
    try testing.expectEqualStrings("57014", conn.last_error.?.code);
    try conn.execScript("reset statement_timeout");

    const One = struct { one: i32 };
    try testing.expectEqual(1, (try conn.get(One, f.arena(), "select 1 as one", .{})).one);
    try testing.expectError(error.ColumnMissing, conn.get(One, f.arena(), "select 1 as two", .{}));
    try testing.expectError(error.UnexpectedNull, conn.get(One, f.arena(), "select null::int as one", .{}));
    try testing.expectEqual(1, (try conn.get(One, f.arena(), "select 1 as one", .{})).one);
}

test "transactions commit, roll back, and abort" {
    var f: Fixture = undefined;
    try f.init(.{ .max_connections = 1 });
    defer f.deinit();
    try f.pool.execScript("create temp table ledger (n int not null)");
    const Count = struct { count: i64 };

    {
        var tx = try f.pool.begin();
        defer tx.deinit();
        _ = try tx.exec("insert into ledger values ($1)", .{1});
        try tx.commit();
    }
    {
        var tx = try f.pool.begin();
        defer tx.deinit(); // no commit: rolled back
        _ = try tx.exec("insert into ledger values ($1)", .{2});
    }
    {
        var tx = try f.pool.begin();
        defer tx.deinit();
        try testing.expectError(error.QueryFailed, tx.exec("insert into ledger values ('x')", .{}));
        try testing.expectError(error.TransactionAborted, tx.commit());
    }
    const total = try f.pool.get(Count, f.arena(), "select count(*) from ledger", .{});
    try testing.expectEqual(1, total.count);
}

test "authentication methods" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const base = try pg.Config.parseUrl(arena_state.allocator(), testUrl());

    const Case = struct { user: []const u8, password: []const u8, cleartext: bool = false, fails: bool = false };
    const cases = [_]Case{
        .{ .user = "zag", .password = "zag" }, // SCRAM-SHA-256
        .{ .user = "zag", .password = "wrong", .fails = true },
        .{ .user = "md5user", .password = "md5pass" },
        .{ .user = "md5user", .password = "wrong", .fails = true },
        .{ .user = "plainuser", .password = "plainpass", .fails = true }, // cleartext not allowed
        .{ .user = "plainuser", .password = "plainpass", .cleartext = true },
    };
    for (cases) |case| {
        var config = base;
        config.user = case.user;
        config.password = case.password;
        config.database = "zag";
        config.allow_cleartext_password = case.cleartext;
        const outcome: pg.Conn.Error!void = if (pg.Conn.open(testing.io, testing.allocator, config)) |conn| conn.close() else |err| err;
        if (outcome == error.ConnectionFailed) return noDatabase();
        if (case.fails) try testing.expectError(error.AuthenticationFailed, outcome) else try outcome;
    }
}

test "pool waits for a free connection and times out" {
    var f: Fixture = undefined;
    try f.init(.{ .max_connections = 1, .acquire_timeout = .fromMilliseconds(50) });
    defer f.deinit();

    const held = try f.pool.acquire();
    try testing.expectError(error.PoolTimeout, f.pool.acquire());
    f.pool.release(held);
    const again = try f.pool.acquire();
    try testing.expectEqual(held, again); // the same connection, reused
    f.pool.release(again);
}

test "pool replaces broken connections" {
    var f: Fixture = undefined;
    try f.init(.{ .max_connections = 1 });
    defer f.deinit();

    const victim = try f.pool.acquire();
    const Pid = struct { pid: i32 };
    const pid = (try victim.get(Pid, f.arena(), "select pg_backend_pid() as pid", .{})).pid;
    f.pool.release(victim);

    // Kill the pooled connection from another one.
    var config = f.pool.config;
    config.application_name = "zag-pg-killer";
    const killer = try pg.Conn.open(testing.io, testing.allocator, config);
    defer killer.close();
    _ = try killer.exec("select pg_terminate_backend($1)", .{pid});

    const conn = try f.pool.acquire();
    try testing.expectError(error.ConnectionFailed, conn.execScript("select 1"));
    f.pool.release(conn); // broken: closed, slot freed

    const fresh = try f.pool.get(Pid, f.arena(), "select pg_backend_pid() as pid", .{});
    try testing.expect(fresh.pid != pid);
}

test "pool shares connections between concurrent tasks" {
    var f: Fixture = undefined;
    try f.init(.{ .max_connections = 3 });
    defer f.deinit();
    try f.pool.execScript("create table if not exists zag_pg_counter (n int not null); truncate zag_pg_counter;");
    defer f.pool.execScript("drop table zag_pg_counter") catch {};

    var group: std.Io.Group = .init;
    defer group.cancel(testing.io);
    for (0..24) |i| group.concurrent(testing.io, insertSlowly, .{ &f.pool, i }) catch return error.SkipZigTest;
    try group.await(testing.io);

    const Total = struct { count: i64, sum: i64 };
    const total = try f.pool.get(Total, f.arena(), "select count(*), coalesce(sum(n), 0)::int8 as sum from zag_pg_counter", .{});
    try testing.expectEqual(24, total.count);
    try testing.expectEqual(276, total.sum); // 0 + 1 + … + 23
    try testing.expect(f.pool.open_count <= 3);
}

fn insertSlowly(pool: *pg.Pool, i: usize) void {
    _ = pool.exec("insert into zag_pg_counter select $1 from pg_sleep(0.01)", .{i}) catch |err|
        std.debug.panic("insert {d} failed: {s}", .{ i, @errorName(err) });
}
