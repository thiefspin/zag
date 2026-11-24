//! SCRAM-SHA-256 client (RFC 5802, RFC 7677), as used by Postgres. Pure: the
//! caller supplies the nonce and moves messages to and from the server.
//!
//!   client-first  → server-first  → client-final  → server-final
//!   `clientFirst`   `clientFinal`                    `verifyServerFinal`

const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64 = std.base64.standard;

pub const mechanism = "SCRAM-SHA-256";

pub const Error = error{ AuthenticationFailed, OutOfMemory };

const key_len = HmacSha256.mac_length;

pub const Scram = struct {
    arena: Allocator,
    /// Postgres ignores the SCRAM user name and uses the startup user, so it
    /// is usually empty.
    user: []const u8,
    password: []const u8,
    client_nonce: []const u8,
    /// Set by `clientFinal`, checked by `verifyServerFinal`.
    server_signature: [key_len]u8 = undefined,
    client_first_bare: []const u8 = "",

    /// `n,,n=<user>,r=<nonce>`
    pub fn clientFirst(self: *Scram) Error![]const u8 {
        self.client_first_bare = try std.fmt.allocPrint(self.arena, "n={s},r={s}", .{ self.user, self.client_nonce });
        return std.fmt.allocPrint(self.arena, "n,,{s}", .{self.client_first_bare});
    }

    /// Answers the server's challenge with a proof that we know the password.
    pub fn clientFinal(self: *Scram, server_first: []const u8) Error![]const u8 {
        const challenge = try parseServerFirst(self.arena, server_first);
        if (!std.mem.startsWith(u8, challenge.nonce, self.client_nonce)) return error.AuthenticationFailed;

        var salted: [key_len]u8 = undefined;
        std.crypto.pwhash.pbkdf2(&salted, self.password, challenge.salt, challenge.iterations, HmacSha256) catch
            return error.AuthenticationFailed;

        const client_key = hmac(&salted, "Client Key");
        var stored_key: [key_len]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        // "biws" is base64("n,,"), the GS2 header: no channel binding.
        const without_proof = try std.fmt.allocPrint(self.arena, "c=biws,r={s}", .{challenge.nonce});
        const auth_message = try std.fmt.allocPrint(self.arena, "{s},{s},{s}", .{ self.client_first_bare, server_first, without_proof });

        const client_signature = hmac(&stored_key, auth_message);
        var proof: [key_len]u8 = undefined;
        for (&proof, client_key, client_signature) |*p, k, s| p.* = k ^ s;

        const server_key = hmac(&salted, "Server Key");
        self.server_signature = hmac(&server_key, auth_message);

        var proof_b64: [base64.Encoder.calcSize(key_len)]u8 = undefined;
        return std.fmt.allocPrint(self.arena, "{s},p={s}", .{ without_proof, base64.Encoder.encode(&proof_b64, &proof) });
    }

    /// Checks that the server also knows the password (`v=<signature>`).
    pub fn verifyServerFinal(self: *const Scram, server_final: []const u8) Error!void {
        const prefix = "v=";
        if (!std.mem.startsWith(u8, server_final, prefix)) return error.AuthenticationFailed;
        const b64_len = comptime base64.Encoder.calcSize(key_len);
        var expected: [b64_len]u8 = undefined;
        _ = base64.Encoder.encode(&expected, &self.server_signature);
        const received = std.mem.trimEnd(u8, server_final[prefix.len..], "\r\n ");
        if (received.len != b64_len) return error.AuthenticationFailed;
        if (!std.crypto.timing_safe.eql([b64_len]u8, received[0..b64_len].*, expected)) return error.AuthenticationFailed;
    }
};

const Challenge = struct { nonce: []const u8, salt: []const u8, iterations: u32 };

/// Parses `r=<nonce>,s=<base64 salt>,i=<iterations>`.
fn parseServerFirst(arena: Allocator, message: []const u8) Error!Challenge {
    var nonce: ?[]const u8 = null;
    var salt_b64: ?[]const u8 = null;
    var iterations: ?u32 = null;
    var it = std.mem.splitScalar(u8, message, ',');
    while (it.next()) |attr| {
        if (attr.len < 2 or attr[1] != '=') return error.AuthenticationFailed;
        const value = attr[2..];
        switch (attr[0]) {
            'r' => nonce = value,
            's' => salt_b64 = value,
            'i' => iterations = std.fmt.parseInt(u32, value, 10) catch return error.AuthenticationFailed,
            else => {},
        }
    }
    const encoded_salt = salt_b64 orelse return error.AuthenticationFailed;
    const salt = try arena.alloc(u8, base64.Decoder.calcSizeForSlice(encoded_salt) catch return error.AuthenticationFailed);
    base64.Decoder.decode(salt, encoded_salt) catch return error.AuthenticationFailed;
    const rounds = iterations orelse return error.AuthenticationFailed;
    if (rounds == 0) return error.AuthenticationFailed;
    return .{ .nonce = nonce orelse return error.AuthenticationFailed, .salt = salt, .iterations = rounds };
}

fn hmac(key: []const u8, message: []const u8) [key_len]u8 {
    var out: [key_len]u8 = undefined;
    HmacSha256.create(&out, message, key);
    return out;
}

/// A random printable nonce (base64 of 18 random bytes).
pub fn makeNonce(arena: Allocator, random: [18]u8) Error![]const u8 {
    var buffer: [base64.Encoder.calcSize(18)]u8 = undefined;
    return arena.dupe(u8, base64.Encoder.encode(&buffer, &random));
}

/// Postgres's legacy MD5 scheme: `"md5" ++ hex(md5(hex(md5(password ++ user)) ++ salt))`.
pub fn md5Password(user: []const u8, password: []const u8, salt: [4]u8) [35]u8 {
    const Md5 = std.crypto.hash.Md5;
    var inner: [Md5.digest_length]u8 = undefined;
    var h = Md5.init(.{});
    h.update(password);
    h.update(user);
    h.final(&inner);
    const inner_hex = std.fmt.bytesToHex(inner, .lower);

    var outer: [Md5.digest_length]u8 = undefined;
    h = Md5.init(.{});
    h.update(&inner_hex);
    h.update(&salt);
    h.final(&outer);
    return ("md5" ++ std.fmt.bytesToHex(outer, .lower)).*;
}

const testing = std.testing;

test "RFC 7677 test vector" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var scram: Scram = .{
        .arena = arena_state.allocator(),
        .user = "user",
        .password = "pencil",
        .client_nonce = "rOprNGfwEbeRWgbNEkqO",
    };
    try testing.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", try scram.clientFirst());

    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    try testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        try scram.clientFinal(server_first),
    );
    try scram.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
    try testing.expectError(error.AuthenticationFailed, scram.verifyServerFinal("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
}

test "server nonce must extend ours" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var scram: Scram = .{ .arena = arena_state.allocator(), .user = "", .password = "p", .client_nonce = "abc" };
    _ = try scram.clientFirst();
    try testing.expectError(error.AuthenticationFailed, scram.clientFinal("r=xyz,s=c2FsdA==,i=4096"));
}

test md5Password {
    // Expected value computed independently with Python's hashlib.
    const hashed = md5Password("zag", "secret", .{ 1, 2, 3, 4 });
    try testing.expectEqualStrings("md5536a14c7cdc04bb66be4ede6e3ec8fe8", &hashed);
}
