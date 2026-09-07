const std = @import("std");
const jwt = @import("identity.zig");
pub const Key = jwt.Scheme.PublicKey;
pub const IdentityKind = jwt.IdentityKind;
pub const Fingerprint = struct { algorithm: []const u8, digest: []const u8 };
pub const Verifier = struct {
    context: ?*anyopaque = null,
    verify: *const fn (?*anyopaque, []const u8) anyerror!?Key,
};

/// Token and domain are borrowed; the key is a value. Caller owns token memory.
pub const Identity = struct {
    key: jwt.Scheme.KeyPair,
    token: []const u8,
    domain: []const u8 = "self",
};

pub fn fingerprintPayload(a: std.mem.Allocator, sdp: []const u8) ![]u8 {
    if (sdp.len > jwt.maximum_size) return error.IdentityTooLarge;
    var list: std.ArrayList(Fingerprint) = .empty;
    defer list.deinit(a);
    var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "a=fingerprint:")) continue;
        const value = line[14..];
        const space = std.mem.indexOfScalar(u8, value, ' ') orelse continue;
        const fingerprint: Fingerprint = .{ .algorithm = value[0..space], .digest = value[space + 1 ..] };
        var duplicate = false;
        for (list.items) |existing| if (std.mem.eql(u8, existing.algorithm, fingerprint.algorithm) and std.mem.eql(u8, existing.digest, fingerprint.digest)) {
            duplicate = true;
            break;
        };
        if (!duplicate) {
            if (list.items.len >= 64) return error.IdentityTooLarge;
            try list.append(a, fingerprint);
        }
    }
    return std.json.Stringify.valueAlloc(a, .{ .fingerprint = list.items }, .{});
}

/// Returned SDP is owned by caller. Assertion is a nested JSON string, not an
/// object, and is inserted before the first media section.
pub fn add(a: std.mem.Allocator, sdp: []const u8, identity: Identity) ![:0]u8 {
    if (identity.domain.len == 0) return error.InvalidIdentity;
    const payload = try fingerprintPayload(a, sdp);
    defer a.free(payload);
    const signature = try jwt.sign(a, identity.key, "{\"alg\":\"ES384\"}", payload, true);
    defer a.free(signature);
    const assertion = try std.json.Stringify.valueAlloc(a, .{ .fingerprints = signature, .token = identity.token }, .{});
    defer a.free(assertion);
    const json = try std.json.Stringify.valueAlloc(a, .{ .assertion = assertion, .idp = .{ .domain = identity.domain, .protocol = "default" } }, .{});
    defer a.free(json);
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    defer a.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, json);
    const media = std.mem.indexOf(u8, sdp, "m=") orelse sdp.len;
    return std.fmt.allocPrintSentinel(a, "{s}a=identity:{s}\r\n{s}", .{ sdp[0..media], encoded, sdp[media..] }, 0);
}

/// Null denotes no identity attribute. Verifies the detached fingerprint proof
/// even when an external issuer verifier supplies a replacement cpk.
pub fn verify(a: std.mem.Allocator, sdp: []const u8, now: i64, kind: IdentityKind, verifier: ?Verifier) !?Key {
    if (sdp.len > jwt.maximum_size) return error.IdentityTooLarge;
    var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");
    const encoded = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "a=identity:")) break line[11..];
    } else return null;
    const json = try jwt.decode64(a, encoded);
    defer a.free(json);
    const root = try jwt.parse(a, json);
    defer root.deinit();
    const provider = try jwt.field(root.value, "idp");
    if ((try jwt.string(try jwt.field(provider, "domain"))).len == 0 or !std.mem.eql(u8, try jwt.string(try jwt.field(provider, "protocol")), "default")) return error.InvalidIdentity;
    const inner = try jwt.parse(a, try jwt.string(try jwt.field(root.value, "assertion")));
    defer inner.deinit();
    const token = try jwt.string(try jwt.field(inner.value, "token"));
    const signature = try jwt.string(try jwt.field(inner.value, "fingerprints"));
    var key = try jwt.claimPublicKey(a, token, now, kind);
    const payload = try fingerprintPayload(a, sdp);
    defer a.free(payload);
    // Verify key possession before asking the application to trust the identity.
    try jwt.verify(a, signature, key, payload);
    if (verifier) |v| if (try v.verify(v.context, token)) |verified| {
        try jwt.verify(a, signature, verified, payload);
        key = verified;
    };
    return key;
}

test "SDP identity nesting, fingerprint deduplication and proof binding" {
    const a = std.testing.allocator;
    const key = try jwt.Scheme.KeyPair.generateDeterministic(.{2} ** 48);
    const token = try jwt.serverToken(a, key, 1000);
    defer a.free(token);
    const source = "v=0\r\na=fingerprint:sha-256 00:11\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=fingerprint:sha-256 00:11\r\n";
    const payload = try fingerprintPayload(a, source);
    defer a.free(payload);
    try std.testing.expectEqualStrings("{\"fingerprint\":[{\"algorithm\":\"sha-256\",\"digest\":\"00:11\"}]}", payload);
    const signed = try add(a, source, .{ .key = key, .token = token });
    defer a.free(signed);
    try std.testing.expect((try verify(a, signed, 1000, .server, null)) != null);
    const offset = std.mem.indexOf(u8, signed, "00:11").?;
    signed[offset] = 'f';
    if (verify(a, signed, 1000, .server, null)) |_| return error.TamperingAccepted else |_| {}
}
