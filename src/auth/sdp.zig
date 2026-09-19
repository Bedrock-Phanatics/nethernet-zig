//! SDP identity assertion creation and verification.

const std = @import("std");

const jwt = @import("token.zig");
pub const Key = jwt.Scheme.PublicKey;
pub const KeyPair = jwt.Scheme.KeyPair;
pub const IdentityKind = jwt.IdentityKind;

pub const Fingerprint = struct {
    algorithm: []const u8,
    digest: []const u8,
};

pub const Verifier = struct {
    context: ?*anyopaque = null,
    verify: *const fn (?*anyopaque, []const u8) anyerror!?Key,
};

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
        const space = std.mem.indexOfScalar(u8, value, ' ') orelse
            return error.InvalidIdentity;
        if (space == 0 or space + 1 == value.len) return error.InvalidIdentity;

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

    if (fingerprints.items.len == 0) return error.InvalidIdentity;

    return std.json.Stringify.valueAlloc(
        allocator,
        .{ .fingerprint = fingerprints.items },
        .{},
    );
}

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

    var media = sdp.len;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, sdp, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trimEnd(u8, line_with_cr, "\r");
        if (std.mem.startsWith(u8, line, "m=")) {
            media = offset;
            break;
        }
        offset += line_with_cr.len + 1;
    }

    const separator = if (media == sdp.len and sdp.len != 0 and
        !std.mem.endsWith(u8, sdp, "\n")) "\r\n" else "";

    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}{s}a=identity:{s}\r\n{s}",
        .{ sdp[0..media], separator, encoded, sdp[media..] },
        0,
    );
}

pub fn verify(
    allocator: std.mem.Allocator,
    sdp: []const u8,
    now: i64,
    kind: IdentityKind,
    verifier: ?Verifier,
) !?Key {
    if (sdp.len > jwt.maximum_size) return error.IdentityTooLarge;

    var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");

    var media_started = false;
    var encoded: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "m=")) {
            media_started = true;
            continue;
        }

        if (!std.mem.startsWith(u8, line, "a=identity:")) continue;
        if (media_started or encoded != null) return error.InvalidIdentity;

        encoded = line[11..];
    }

    const assertion_text = encoded orelse return null;

    const json = try jwt.decode64(allocator, assertion_text);
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

    try jwt.verify(allocator, signature, key, payload);

    if (verifier) |application_verifier| {
        const verified_key = (try application_verifier.verify(
            application_verifier.context,
            token,
        )) orelse return error.InvalidIdentity;
        try jwt.verify(allocator, signature, verified_key, payload);
        key = verified_key;
    }

    return key;
}

test "SDP identity requires a valid fingerprint and explicit verifier acceptance" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidIdentity, fingerprintPayload(allocator, "v=0\r\n"));
    try std.testing.expectError(error.InvalidIdentity, fingerprintPayload(allocator, "a=fingerprint:sha-256\r\n"));
    try std.testing.expectError(error.InvalidIdentity, fingerprintPayload(allocator, "a=fingerprint: 00:11\r\n"));
    try std.testing.expectError(error.InvalidIdentity, fingerprintPayload(allocator, "a=fingerprint:sha-256 \r\n"));

    const Rejector = struct {
        fn reject(_: ?*anyopaque, _: []const u8) anyerror!?Key {
            return null;
        }
    };
    const key = try jwt.Scheme.KeyPair.generateDeterministic(.{3} ** 48);
    const token = try jwt.serverToken(allocator, key, 1000);
    defer allocator.free(token);
    const signed = try add(
        allocator,
        "v=0\r\na=fingerprint:sha-256 00:11\r\n",
        .{ .key = key, .token = token },
    );
    defer allocator.free(signed);
    try std.testing.expectError(
        error.InvalidIdentity,
        verify(allocator, signed, 1000, .server, .{ .verify = Rejector.reject }),
    );
}

test "identity insertion ignores m equals inside attribute values" {
    const allocator = std.testing.allocator;
    const key = try jwt.Scheme.KeyPair.generateDeterministic(.{4} ** 48);
    const token = try jwt.serverToken(allocator, key, 1000);
    defer allocator.free(token);
    const source =
        "v=0\r\n" ++
        "a=x:term=value\r\n" ++
        "a=fingerprint:sha-256 00:11\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n";
    const signed = try add(allocator, source, .{ .key = key, .token = token });
    defer allocator.free(signed);
    try std.testing.expect(std.mem.indexOf(u8, signed, "a=x:term=value\r\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, signed, "a=identity:").? <
            std.mem.indexOf(u8, signed, "m=application").?,
    );
}

test "duplicate SDP identity assertions are rejected" {
    const allocator = std.testing.allocator;
    const key = try jwt.Scheme.KeyPair.generateDeterministic(.{5} ** 48);
    const token = try jwt.serverToken(allocator, key, 1000);
    defer allocator.free(token);

    const source = "v=0\r\na=fingerprint:sha-256 00:11\r\n";
    const signed = try add(allocator, source, .{ .key = key, .token = token });
    defer allocator.free(signed);

    const identity_start = std.mem.indexOf(u8, signed, "a=identity:").?;
    const identity_end = std.mem.indexOfPos(u8, signed, identity_start, "\r\n").? + 2;
    const duplicated = try std.fmt.allocPrint(allocator, "{s}{s}", .{ signed, signed[identity_start..identity_end] });
    defer allocator.free(duplicated);

    try std.testing.expectError(error.InvalidIdentity, verify(allocator, duplicated, 1000, .server, null));
}

test "SDP identity assertions must be session level" {
    const allocator = std.testing.allocator;
    const key = try jwt.Scheme.KeyPair.generateDeterministic(.{6} ** 48);
    const token = try jwt.serverToken(allocator, key, 1000);
    defer allocator.free(token);

    const source =
        "v=0\r\n" ++
        "a=fingerprint:sha-256 00:11\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n";
    const signed = try add(allocator, source, .{ .key = key, .token = token });
    defer allocator.free(signed);

    const identity_start = std.mem.indexOf(u8, signed, "a=identity:").?;
    const identity_end = std.mem.indexOfPos(u8, signed, identity_start, "\r\n").? + 2;
    const media_level = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        signed[0..identity_start],
        signed[identity_end..],
        signed[identity_start..identity_end],
    });
    defer allocator.free(media_level);

    try std.testing.expectError(error.InvalidIdentity, verify(allocator, media_level, 1000, .server, null));
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
