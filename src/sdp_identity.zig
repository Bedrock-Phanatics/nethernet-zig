const std = @import("std");

const jwt = @import("identity.zig");

pub const Key = jwt.Scheme.PublicKey;
pub const IdentityKind = jwt.IdentityKind;

pub const Fingerprint = struct {
    algorithm: []const u8,
    digest: []const u8,
};

pub const Verifier = struct {
    context: ?*anyopaque = null,
    verify: *const fn (?*anyopaque, []const u8) anyerror!?Key,
};

/// The token and domain are borrowed. The caller keeps the token alive.
pub const Identity = struct {
    key: jwt.Scheme.KeyPair,
    token: []const u8,
    domain: []const u8 = "self",
};

pub fn fingerprintPayload(
    allocator: std.mem.Allocator,
    sdp: []const u8,
) ![]u8 {
    if (sdp.len > jwt.maximum_size) return error.IdentityTooLarge;

    var fingerprints: std.ArrayList(Fingerprint) = .empty;
    defer fingerprints.deinit(allocator);

    var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "a=fingerprint:")) continue;

        const value = line[14..];
        const space = std.mem.indexOfScalar(u8, value, ' ') orelse continue;

        const fingerprint: Fingerprint = .{
            .algorithm = value[0..space],
            .digest = value[space + 1 ..],
        };

        var duplicate = false;

        for (fingerprints.items) |existing| {
            if (std.mem.eql(u8, existing.algorithm, fingerprint.algorithm) and
                std.mem.eql(u8, existing.digest, fingerprint.digest))
            {
                duplicate = true;
                break;
            }
        }

        if (duplicate) continue;

        if (fingerprints.items.len >= 64) {
            return error.IdentityTooLarge;
        }

        try fingerprints.append(allocator, fingerprint);
    }

    return std.json.Stringify.valueAlloc(
        allocator,
        .{ .fingerprint = fingerprints.items },
        .{},
    );
}

/// Returns owned SDP with the identity assertion before the first media section.
pub fn add(
    allocator: std.mem.Allocator,
    sdp: []const u8,
    identity: Identity,
) ![:0]u8 {
    if (identity.domain.len == 0) return error.InvalidIdentity;

    const payload = try fingerprintPayload(allocator, sdp);
    defer allocator.free(payload);

    const signature = try jwt.sign(
        allocator,
        identity.key,
        "{\"alg\":\"ES384\"}",
        payload,
        true,
    );
    defer allocator.free(signature);

    const assertion = try std.json.Stringify.valueAlloc(
        allocator,
        .{
            .fingerprints = signature,
            .token = identity.token,
        },
        .{},
    );
    defer allocator.free(assertion);

    const json = try std.json.Stringify.valueAlloc(
        allocator,
        .{
            .assertion = assertion,
            .idp = .{
                .domain = identity.domain,
                .protocol = "default",
            },
        },
        .{},
    );
    defer allocator.free(json);

    const encoded = try allocator.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(json.len),
    );
    defer allocator.free(encoded);

    _ = std.base64.standard.Encoder.encode(encoded, json);

    const media = std.mem.indexOf(u8, sdp, "m=") orelse sdp.len;

    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}a=identity:{s}\r\n{s}",
        .{ sdp[0..media], encoded, sdp[media..] },
        0,
    );
}

/// Returns null when no identity is present. Otherwise it verifies key possession.
pub fn verify(
    allocator: std.mem.Allocator,
    sdp: []const u8,
    now: i64,
    kind: IdentityKind,
    verifier: ?Verifier,
) !?Key {
    if (sdp.len > jwt.maximum_size) return error.IdentityTooLarge;

    var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");

    const encoded = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "a=identity:")) {
            break line[11..];
        }
    } else return null;

    const json = try jwt.decode64(allocator, encoded);
    defer allocator.free(json);

    const root = try jwt.parse(allocator, json);
    defer root.deinit();

    const provider = try jwt.field(root.value, "idp");
    const domain = try jwt.string(try jwt.field(provider, "domain"));
    const protocol = try jwt.string(try jwt.field(provider, "protocol"));

    if (domain.len == 0 or !std.mem.eql(u8, protocol, "default")) {
        return error.InvalidIdentity;
    }

    const assertion = try jwt.string(
        try jwt.field(root.value, "assertion"),
    );

    const inner = try jwt.parse(allocator, assertion);
    defer inner.deinit();

    const token = try jwt.string(try jwt.field(inner.value, "token"));
    const signature = try jwt.string(
        try jwt.field(inner.value, "fingerprints"),
    );

    var key = try jwt.claimPublicKey(
        allocator,
        token,
        now,
        kind,
    );

    const payload = try fingerprintPayload(allocator, sdp);
    defer allocator.free(payload);

    // Prove key possession before asking the application to trust the identity.
    try jwt.verify(allocator, signature, key, payload);

    if (verifier) |application_verifier| {
        if (try application_verifier.verify(
            application_verifier.context,
            token,
        )) |verified_key| {
            try jwt.verify(
                allocator,
                signature,
                verified_key,
                payload,
            );

            key = verified_key;
        }
    }

    return key;
}

test "SDP identity nesting, fingerprint deduplication and proof binding" {
    const allocator = std.testing.allocator;
    const key = try jwt.Scheme.KeyPair.generateDeterministic(.{2} ** 48);

    const token = try jwt.serverToken(allocator, key, 1000);
    defer allocator.free(token);

    const source =
        "v=0\r\n" ++
        "a=fingerprint:sha-256 00:11\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=fingerprint:sha-256 00:11\r\n";

    const payload = try fingerprintPayload(allocator, source);
    defer allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"fingerprint\":[{\"algorithm\":\"sha-256\",\"digest\":\"00:11\"}]}",
        payload,
    );

    const signed = try add(allocator, source, .{
        .key = key,
        .token = token,
    });
    defer allocator.free(signed);

    try std.testing.expect(
        (try verify(allocator, signed, 1000, .server, null)) != null,
    );

    const offset = std.mem.indexOf(u8, signed, "00:11").?;
    signed[offset] = 'f';

    if (verify(allocator, signed, 1000, .server, null)) |_| {
        return error.TamperingAccepted;
    } else |_| {}
}
