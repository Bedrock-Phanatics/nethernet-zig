const std = @import("std");
const jwt = @import("token.zig");
const sdp = @import("sdp.zig");
const rsa = std.crypto.Certificate.rsa;

/// The host supplies trusted keys and replaces this snapshot when the issuer rotates them.
pub const Keys = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    parsed: std.json.Parsed(std.json.Value),
    issuer: []const u8,
    audience: []const u8,

    pub fn init(allocator: std.mem.Allocator, jwks: []const u8, issuer: []const u8, audience: []const u8) !Keys {
        if (jwks.len > 64 * 1024) return error.IdentityTooLarge;
        const source = try allocator.dupe(u8, jwks);
        errdefer allocator.free(source);
        const parsed = try jwt.parse(allocator, source);
        errdefer parsed.deinit();
        const keys = try jwt.field(parsed.value, "keys");
        if (keys != .array or keys.array.items.len == 0 or keys.array.items.len > 64)
            return error.InvalidIdentity;
        return .{ .allocator = allocator, .source = source, .parsed = parsed, .issuer = issuer, .audience = audience };
    }

    pub fn deinit(self: Keys) void {
        self.parsed.deinit();
        self.allocator.free(self.source);
    }

    pub fn verify(self: *const Keys, allocator: std.mem.Allocator, token: []const u8, now: i64) !jwt.Scheme.PublicKey {
        const parts = try jwt.split(token);
        const header_bytes = try jwt.decode64(allocator, parts[0]);
        defer allocator.free(header_bytes);
        const header = try jwt.parse(allocator, header_bytes);
        defer header.deinit();
        if (!std.mem.eql(u8, try jwt.string(try jwt.field(header.value, "alg")), "RS256"))
            return error.UnsupportedAlgorithm;
        if (header.value.object.get("crit") != null or header.value.object.get("b64") != null)
            return error.UnsupportedAlgorithm;
        const kid = try jwt.string(try jwt.field(header.value, "kid"));
        var selected: ?std.json.Value = null;
        for ((try jwt.field(self.parsed.value, "keys")).array.items) |key| {
            if (!std.mem.eql(u8, try jwt.string(try jwt.field(key, "kid")), kid)) continue;
            if (selected != null) return error.InvalidIdentity;
            selected = key;
        }
        const key = selected orelse return error.UnknownSigningKey;
        if (!std.mem.eql(u8, try jwt.string(try jwt.field(key, "kty")), "RSA"))
            return error.UnsupportedKey;
        if (key.object.get("use")) |use| {
            if (!std.mem.eql(u8, try jwt.string(use), "sig")) return error.UnsupportedKey;
        }
        if (key.object.get("alg")) |algorithm| {
            if (!std.mem.eql(u8, try jwt.string(algorithm), "RS256")) return error.UnsupportedAlgorithm;
        }
        const modulus = try jwt.decode64(allocator, try jwt.string(try jwt.field(key, "n")));
        defer allocator.free(modulus);
        const exponent = try jwt.decode64(allocator, try jwt.string(try jwt.field(key, "e")));
        defer allocator.free(exponent);
        if (modulus.len < 256 or modulus.len > 512 or modulus[0] & 0x80 == 0)
            return error.UnsupportedKey;
        const public_key = try rsa.PublicKey.fromBytes(exponent, modulus);
        const signature = try jwt.decode64(allocator, parts[2]);
        defer allocator.free(signature);
        if (signature.len != modulus.len) return error.InvalidIdentity;
        const signed = token[0 .. parts[0].len + 1 + parts[1].len];
        switch (modulus.len) {
            inline 256, 384, 512 => |length| rsa.PKCS1v1_5Signature.verify(length, signature[0..length].*, signed, public_key, std.crypto.hash.sha2.Sha256) catch return error.SignatureVerificationFailed,
            else => return error.UnsupportedKey,
        }
        const claims_bytes = try jwt.decode64(allocator, parts[1]);
        defer allocator.free(claims_bytes);
        const claims = try jwt.parse(allocator, claims_bytes);
        defer claims.deinit();
        if (!std.mem.eql(u8, try jwt.string(try jwt.field(claims.value, "iss")), self.issuer))
            return error.UntrustedIssuer;
        const audience = try jwt.field(claims.value, "aud");
        const matches = switch (audience) {
            .string => |value| std.mem.eql(u8, value, self.audience),
            .array => |values| found: {
                var matched = false;
                for (values.items) |value| {
                    if (std.mem.eql(u8, try jwt.string(value), self.audience)) matched = true;
                }
                break :found matched;
            },
            else => return error.InvalidIdentity,
        };
        if (!matches) return error.InvalidAudience;
        return jwt.claimPublicKey(allocator, token, now, .client);
    }
};

pub const minecraft_keys_url = "https://authorization.franchise.minecraft-services.net/.well-known/keys";
pub const minecraft_issuer = "https://authorization.franchise.minecraft-services.net/";
pub const minecraft_audience = "api://auth-minecraft-services/multiplayer";
const refresh_interval_seconds = 60;
const fetch_timeout_seconds = 15;

/// Verifies Minecraft multiplayer tokens and refetches signing keys when an unknown key ID shows up.
pub const Authority = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // ponytail: one lock for verify and refresh, a key fetch can stall joins for up to 15 seconds once a minute.
    mutex: std.Io.Mutex = .init,
    keys: ?Keys = null,
    refreshed: ?std.Io.Timestamp = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Authority {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Authority) void {
        if (self.keys) |keys| keys.deinit();
        self.keys = null;
    }

    pub fn verifier(self: *Authority) sdp.Verifier {
        return .{ .context = self, .verify = verifyToken };
    }

    pub fn refresh(self: *Authority) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.refreshLocked();
    }

    fn refreshLocked(self: *Authority) !void {
        self.refreshed = std.Io.Clock.awake.now(self.io);
        const keys = try fetch(self.allocator, self.io);
        if (self.keys) |old| old.deinit();
        self.keys = keys;
    }

    fn verifyToken(context: ?*anyopaque, token: []const u8) anyerror!?sdp.Key {
        const self: *Authority = @ptrCast(@alignCast(context.?));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const now = std.Io.Clock.real.now(self.io).toSeconds();
        if (self.keys) |*keys| {
            if (keys.verify(self.allocator, token, now)) |key| return key else |err| {
                if (err != error.UnknownSigningKey) return err;
            }
        }
        if (self.refreshed) |last| {
            if (last.durationTo(std.Io.Clock.awake.now(self.io)).toSeconds() < refresh_interval_seconds)
                return error.UnknownSigningKey;
        }
        try self.refreshLocked();
        return try self.keys.?.verify(self.allocator, token, now);
    }
};

fn fetch(allocator: std.mem.Allocator, io: std.Io) !Keys {
    const Result = union(enum) { keys: anyerror!Keys, timeout: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer while (select.cancel()) |pending| {
        if (pending == .keys) {
            const keys = pending.keys catch continue;
            keys.deinit();
        }
    };
    try select.concurrent(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(fetch_timeout_seconds), .awake });
    try select.concurrent(.keys, download, .{ allocator, io });
    return switch (try select.await()) {
        .keys => |result| result,
        .timeout => |result| {
            try result;
            return error.IssuerFetchTimeout;
        },
    };
}

fn download(allocator: std.mem.Allocator, io: std.Io) !Keys {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const result = try client.fetch(.{
        .location = .{ .url = minecraft_keys_url },
        .response_writer = &writer,
    });
    if (result.status != .ok) return error.IssuerFetchFailed;
    return Keys.init(allocator, writer.buffered(), minecraft_issuer, minecraft_audience);
}

test "authority refreshes unknown signing keys at most once per interval" {
    var authority = Authority.init(std.testing.allocator, std.testing.io);
    defer authority.deinit();
    authority.keys = try Keys.init(std.testing.allocator, "{\"keys\":[{\"kid\":\"a\",\"kty\":\"RSA\",\"n\":\"\",\"e\":\"\"}]}", minecraft_issuer, minecraft_audience);
    authority.refreshed = std.Io.Clock.awake.now(std.testing.io);
    const token = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImIifQ.e30.AA";
    try std.testing.expectError(error.UnknownSigningKey, authority.verifier().verify(&authority, token));
}
