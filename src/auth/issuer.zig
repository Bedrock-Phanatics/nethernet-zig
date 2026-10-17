const std = @import("std");
const jwt = @import("token.zig");
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
            inline 256, 384, 512 => |length| try rsa.PKCS1v1_5Signature.verify(length, signature[0..length].*, signed, public_key, std.crypto.hash.sha2.Sha256),
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
