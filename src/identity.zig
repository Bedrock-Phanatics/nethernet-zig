const std = @import("std");

pub const Scheme = std.crypto.sign.ecdsa.EcdsaP384Sha384;

const base64_url = std.base64.url_safe_no_pad;
const public_key_prefix = [_]u8{
    0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86,
    0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b,
    0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
};

pub const maximum_size = 1024 * 1024;
pub const server_iat_clock_skew_seconds: i64 = 60;

pub const IdentityKind = enum {
    client,
    server,
};

pub fn encode64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, base64_url.Encoder.calcSize(data.len));
    _ = base64_url.Encoder.encode(output, data);
    return output;
}

pub fn decode64(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len > maximum_size) return error.IdentityTooLarge;

    const codec = if (std.mem.indexOfAny(u8, text, "+/") != null)
        std.base64.standard_no_pad
    else
        base64_url;

    const unpadded = std.mem.trimEnd(u8, text, "=");
    const output = try allocator.alloc(
        u8,
        try codec.Decoder.calcSizeForSlice(unpadded),
    );
    errdefer allocator.free(output);

    try codec.Decoder.decode(output, unpadded);
    return output;
}

fn split(text: []const u8) ![3][]const u8 {
    if (text.len > maximum_size) return error.IdentityTooLarge;

    var iterator = std.mem.splitScalar(u8, text, '.');
    var parts: [3][]const u8 = undefined;

    for (&parts) |*part| {
        part.* = iterator.next() orelse return error.InvalidIdentity;
    }

    if (iterator.next() != null) return error.InvalidIdentity;
    return parts;
}

pub fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidIdentity;
    return value.object.get(name) orelse error.InvalidIdentity;
}

pub fn string(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidIdentity;
    return value.string;
}

fn integer(value: std.json.Value) !i64 {
    if (value != .integer) return error.InvalidIdentity;
    return value.integer;
}

pub fn parse(
    allocator: std.mem.Allocator,
    data: []const u8,
) !std.json.Parsed(std.json.Value) {
    if (data.len > maximum_size) return error.IdentityTooLarge;

    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{ .max_value_len = maximum_size },
    );
}

/// The caller owns the returned JWS. Detached signatures use the encoded payload,
/// matching jose-jwt without RFC 7797 options.
pub fn sign(
    allocator: std.mem.Allocator,
    key: Scheme.KeyPair,
    header: []const u8,
    payload: []const u8,
    detached: bool,
) ![]u8 {
    if (header.len > maximum_size or payload.len > maximum_size) {
        return error.IdentityTooLarge;
    }

    const encoded_header = try encode64(allocator, header);
    defer allocator.free(encoded_header);

    const encoded_payload = try encode64(allocator, payload);
    defer allocator.free(encoded_payload);

    const input = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ encoded_header, encoded_payload },
    );
    defer allocator.free(input);

    const signature = try key.sign(input, null);
    const encoded_signature = try encode64(allocator, &signature.toBytes());
    defer allocator.free(encoded_signature);

    return std.fmt.allocPrint(
        allocator,
        "{s}.{s}.{s}",
        .{
            encoded_header,
            if (detached) "" else encoded_payload,
            encoded_signature,
        },
    );
}

pub fn verify(
    allocator: std.mem.Allocator,
    token: []const u8,
    key: Scheme.PublicKey,
    detached: ?[]const u8,
) !void {
    const parts = try split(token);

    const decoded_header = try decode64(allocator, parts[0]);
    defer allocator.free(decoded_header);

    const header = try parse(allocator, decoded_header);
    defer header.deinit();

    if (!std.mem.eql(
        u8,
        try string(try field(header.value, "alg")),
        "ES384",
    )) {
        return error.UnsupportedAlgorithm;
    }

    if (header.value.object.get("crit") != null or
        header.value.object.get("b64") != null)
    {
        return error.UnsupportedAlgorithm;
    }

    const signature = try decode64(allocator, parts[2]);
    defer allocator.free(signature);

    if (signature.len != 96) return error.InvalidIdentity;

    const encoded_payload = if (detached) |payload|
        try encode64(allocator, payload)
    else
        null;
    defer if (encoded_payload) |bytes| allocator.free(bytes);

    if (detached != null and parts[1].len != 0) {
        return error.InvalidIdentity;
    }

    const input = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ parts[0], encoded_payload orelse parts[1] },
    );
    defer allocator.free(input);

    try Scheme.Signature.fromBytes(signature[0..96].*).verify(input, key);
}

/// JWT timestamps use Unix time. Connection deadlines use a monotonic clock.
pub fn serverToken(
    allocator: std.mem.Allocator,
    key: Scheme.KeyPair,
    now: i64,
) ![]u8 {
    var der: [120]u8 = undefined;
    @memcpy(der[0..public_key_prefix.len], &public_key_prefix);
    @memcpy(
        der[public_key_prefix.len..],
        &key.public_key.toUncompressedSec1(),
    );

    var encoded_buffer: [160]u8 = undefined;
    const encoded_key = std.base64.standard.Encoder.encode(
        &encoded_buffer,
        &der,
    );

    const claims = try std.json.Stringify.valueAlloc(
        allocator,
        .{
            .exp = try std.math.add(i64, now, 60),
            .iat = now,
            .cpk = encoded_key,
        },
        .{},
    );
    defer allocator.free(claims);

    const header = try std.json.Stringify.valueAlloc(
        allocator,
        .{
            .alg = "ES384",
            .x5u = encoded_key,
        },
        .{},
    );
    defer allocator.free(header);

    return sign(allocator, key, header, claims, false);
}

/// Client tokens use standard time checks. Bedrock server tokens skip exp and nbf,
/// but still require a bounded iat and a valid ES384 self-signature.
pub fn claimPublicKey(
    allocator: std.mem.Allocator,
    token: []const u8,
    now: i64,
    kind: IdentityKind,
) !Scheme.PublicKey {
    const parts = try split(token);

    const decoded_header = try decode64(allocator, parts[0]);
    defer allocator.free(decoded_header);

    const header = try parse(allocator, decoded_header);
    defer header.deinit();

    const algorithm = try string(try field(header.value, "alg"));

    if (kind == .server) {
        if (!std.mem.eql(u8, algorithm, "ES384")) {
            return error.UnsupportedAlgorithm;
        }
    } else if (!std.mem.eql(u8, algorithm, "ES384") and
        !std.mem.eql(u8, algorithm, "RS256"))
    {
        return error.UnsupportedAlgorithm;
    }

    const decoded_payload = try decode64(allocator, parts[1]);
    defer allocator.free(decoded_payload);

    const claims = try parse(allocator, decoded_payload);
    defer claims.deinit();

    switch (kind) {
        .client => {
            const expiration = try integer(try field(claims.value, "exp"));

            if (@as(i128, expiration) < @as(i128, now) - 60) {
                return error.ExpiredIdentity;
            }

            for ([_][]const u8{ "nbf", "iat" }) |name| {
                if (claims.value.object.get(name)) |value| {
                    if (@as(i128, try integer(value)) > @as(i128, now) + 60) {
                        return error.InvalidIdentity;
                    }
                }
            }
        },

        .server => {
            const issued_at = try integer(try field(claims.value, "iat"));
            const delta = @as(i128, issued_at) - @as(i128, now);

            if (delta < -server_iat_clock_skew_seconds or
                delta > server_iat_clock_skew_seconds)
            {
                return error.InvalidIdentity;
            }
        },
    }

    const claim = try field(claims.value, "cpk");

    const key = if (claim == .string) blk: {
        const der = try decode64(allocator, claim.string);
        defer allocator.free(der);

        if (der.len != public_key_prefix.len + 97 or
            !std.mem.startsWith(u8, der, &public_key_prefix))
        {
            return error.UnsupportedKey;
        }

        break :blk try Scheme.PublicKey.fromSec1(
            der[public_key_prefix.len..],
        );
    } else blk: {
        if (!std.mem.eql(
            u8,
            try string(try field(claim, "kty")),
            "EC",
        ) or !std.mem.eql(
            u8,
            try string(try field(claim, "crv")),
            "P-384",
        )) {
            return error.UnsupportedKey;
        }

        const x = try decode64(
            allocator,
            try string(try field(claim, "x")),
        );
        defer allocator.free(x);

        const y = try decode64(
            allocator,
            try string(try field(claim, "y")),
        );
        defer allocator.free(y);

        if (x.len != 48 or y.len != 48) {
            return error.InvalidIdentity;
        }

        var sec1: [97]u8 = undefined;
        sec1[0] = 4;
        @memcpy(sec1[1..49], x);
        @memcpy(sec1[49..], y);

        break :blk try Scheme.PublicKey.fromSec1(&sec1);
    };

    if (kind == .server) {
        try verify(allocator, token, key, null);
    }

    return key;
}

test "server identity, expiry, detached signatures, and tampering" {
    const allocator = std.testing.allocator;
    const key = try Scheme.KeyPair.generateDeterministic(.{1} ** 48);

    const token = try serverToken(allocator, key, 1000);
    defer allocator.free(token);

    const public_key = try claimPublicKey(
        allocator,
        token,
        1000,
        .server,
    );

    try std.testing.expectError(
        error.InvalidIdentity,
        claimPublicKey(allocator, token, 1121, .server),
    );

    const signature = try sign(
        allocator,
        key,
        "{\"alg\":\"ES384\"}",
        "fingerprints",
        true,
    );
    defer allocator.free(signature);

    try verify(allocator, signature, public_key, "fingerprints");

    if (verify(allocator, signature, public_key, "tampered")) |_| {
        return error.TamperingAccepted;
    } else |_| {}
}

fn testPublicKey(key: Scheme.KeyPair, output: *[160]u8) []const u8 {
    var der: [120]u8 = undefined;

    @memcpy(der[0..public_key_prefix.len], &public_key_prefix);
    @memcpy(
        der[public_key_prefix.len..],
        &key.public_key.toUncompressedSec1(),
    );

    return std.base64.standard.Encoder.encode(output, &der);
}

fn testToken(
    allocator: std.mem.Allocator,
    key: Scheme.KeyPair,
    algorithm: []const u8,
    claims: []const u8,
) ![]u8 {
    const header = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .alg = algorithm },
        .{},
    );
    defer allocator.free(header);

    return sign(allocator, key, header, claims, false);
}

test "client and server identity validation policies" {
    const allocator = std.testing.allocator;
    const key = try Scheme.KeyPair.generateDeterministic(.{4} ** 48);

    var encoded_key_buffer: [160]u8 = undefined;
    const encoded_key = testPublicKey(key, &encoded_key_buffer);

    const valid_client_claims = try std.fmt.allocPrint(
        allocator,
        "{{\"exp\":1060,\"nbf\":940,\"iat\":1000,\"cpk\":\"{s}\"}}",
        .{encoded_key},
    );
    defer allocator.free(valid_client_claims);

    const valid_client = try testToken(
        allocator,
        key,
        "ES384",
        valid_client_claims,
    );
    defer allocator.free(valid_client);

    _ = try claimPublicKey(allocator, valid_client, 1000, .client);

    try std.testing.expectError(
        error.ExpiredIdentity,
        claimPublicKey(allocator, valid_client, 1121, .client),
    );

    const future_client_claims = try std.fmt.allocPrint(
        allocator,
        "{{\"exp\":1200,\"nbf\":1061,\"iat\":1061,\"cpk\":\"{s}\"}}",
        .{encoded_key},
    );
    defer allocator.free(future_client_claims);

    const future_client = try testToken(
        allocator,
        key,
        "ES384",
        future_client_claims,
    );
    defer allocator.free(future_client);

    try std.testing.expectError(
        error.InvalidIdentity,
        claimPublicKey(allocator, future_client, 1000, .client),
    );

    const expired_server_claims = try std.fmt.allocPrint(
        allocator,
        "{{\"exp\":0,\"nbf\":2000,\"iat\":1000,\"cpk\":\"{s}\"}}",
        .{encoded_key},
    );
    defer allocator.free(expired_server_claims);

    const expired_server = try testToken(
        allocator,
        key,
        "ES384",
        expired_server_claims,
    );
    defer allocator.free(expired_server);

    _ = try claimPublicKey(allocator, expired_server, 1060, .server);

    try std.testing.expectError(
        error.InvalidIdentity,
        claimPublicKey(allocator, expired_server, 1061, .server),
    );

    const other_key = try Scheme.KeyPair.generateDeterministic(.{5} ** 48);
    const wrongly_signed = try testToken(
        allocator,
        other_key,
        "ES384",
        expired_server_claims,
    );
    defer allocator.free(wrongly_signed);

    if (claimPublicKey(allocator, wrongly_signed, 1000, .server)) |_| {
        return error.InvalidSignatureAccepted;
    } else |_| {}

    const wrong_algorithm = try testToken(
        allocator,
        key,
        "RS256",
        expired_server_claims,
    );
    defer allocator.free(wrong_algorithm);

    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        claimPublicKey(allocator, wrong_algorithm, 1000, .server),
    );

    const missing_cpk = try testToken(
        allocator,
        key,
        "ES384",
        "{\"exp\":0,\"iat\":1000}",
    );
    defer allocator.free(missing_cpk);

    try std.testing.expectError(
        error.InvalidIdentity,
        claimPublicKey(allocator, missing_cpk, 1000, .server),
    );

    const malformed_cpk = try testToken(
        allocator,
        key,
        "ES384",
        "{\"exp\":0,\"iat\":1000,\"cpk\":\"not-a-key\"}",
    );
    defer allocator.free(malformed_cpk);

    if (claimPublicKey(allocator, malformed_cpk, 1000, .server)) |_| {
        return error.MalformedKeyAccepted;
    } else |_| {}
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    const key = try Scheme.KeyPair.generateDeterministic(.{3} ** 48);
    const token = try serverToken(allocator, key, 1000);
    defer allocator.free(token);

    _ = try claimPublicKey(allocator, token, 1000, .server);
}

test "every identity allocation failure releases partial state" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationScenario,
        .{},
    );
}
