const std = @import("std");
pub const Scheme = std.crypto.sign.ecdsa.EcdsaP384Sha384;
const base64_url = std.base64.url_safe_no_pad;

const public_key_prefix = [_]u8{
    0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86,
    0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b,
    0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
};

pub const maximum_size = 1024 * 1024;
pub const maximum_json_nesting = 64;
pub const clock_skew_seconds: i64 = 60;

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

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (data) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }

        switch (byte) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > maximum_json_nesting) return error.IdentityTooDeep;
            },
            ']', '}' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }

    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{ .max_value_len = maximum_size },
    );
}

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

    const sec1 = key.public_key.toUncompressedSec1();

    var x_buffer: [base64_url.Encoder.calcSize(48)]u8 = undefined;
    var y_buffer: [base64_url.Encoder.calcSize(48)]u8 = undefined;

    const claims = try std.json.Stringify.valueAlloc(
        allocator,
        .{
            .exp = try std.math.add(i64, now, 60),
            .iat = now,
            .cpk = .{
                .kty = "EC",
                .crv = "P-384",
                .x = base64_url.Encoder.encode(&x_buffer, sec1[1..49]),
                .y = base64_url.Encoder.encode(&y_buffer, sec1[49..97]),
            },
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

            if (@as(i128, expiration) < @as(i128, now) - clock_skew_seconds) {
                return error.ExpiredIdentity;
            }

            for ([_][]const u8{ "nbf", "iat" }) |name| {
                if (claims.value.object.get(name)) |value| {
                    if (@as(i128, try integer(value)) >
                        @as(i128, now) + clock_skew_seconds)
                    {
                        return error.InvalidIdentity;
                    }
                }
            }
        },

        .server => {
            for ([_][]const u8{ "exp", "nbf", "iat" }) |name| {
                if (claims.value.object.get(name)) |value| _ = try integer(value);
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

test "server identity, temporal claims, detached signatures, and tampering" {
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

    _ = try claimPublicKey(allocator, token, 500, .server);
    _ = try claimPublicKey(allocator, token, 1120, .server);
    _ = try claimPublicKey(allocator, token, 1121, .server);

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

test "identity JSON nesting is bounded and quoted brackets are ignored" {
    const allocator = std.testing.allocator;

    const maximum = [_]u8{'['} ** 64 ++ [_]u8{'0'} ++ [_]u8{']'} ** 64;
    const accepted = try parse(allocator, &maximum);
    defer accepted.deinit();

    const nested = [_]u8{'['} ** 65 ++ [_]u8{'0'} ++ [_]u8{']'} ** 65;
    try std.testing.expectError(error.IdentityTooDeep, parse(allocator, &nested));

    const quoted = try parse(allocator, "{\"value\":\"[[[{{{\"}");
    defer quoted.deinit();

    const escaped_quote = try parse(allocator, "{\"value\":\"\\\"[[{{\"}");
    defer escaped_quote.deinit();
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

    const server_claims = try std.fmt.allocPrint(
        allocator,
        "{{\"exp\":2000,\"nbf\":2000,\"iat\":1000,\"cpk\":\"{s}\"}}",
        .{encoded_key},
    );
    defer allocator.free(server_claims);

    const self_signed = try testToken(allocator, key, "ES384", server_claims);
    defer allocator.free(self_signed);

    _ = try claimPublicKey(allocator, self_signed, 1060, .server);
    _ = try claimPublicKey(allocator, self_signed, 2060, .server);
    _ = try claimPublicKey(allocator, self_signed, 2061, .server);

    const other_key = try Scheme.KeyPair.generateDeterministic(.{5} ** 48);
    const wrongly_signed = try testToken(
        allocator,
        other_key,
        "ES384",
        server_claims,
    );
    defer allocator.free(wrongly_signed);

    if (claimPublicKey(allocator, wrongly_signed, 1000, .server)) |_| {
        return error.InvalidSignatureAccepted;
    } else |_| {}

    const wrong_algorithm = try testToken(
        allocator,
        key,
        "RS256",
        server_claims,
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
        "{\"exp\":2000,\"iat\":1000}",
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
        "{\"exp\":2000,\"iat\":1000,\"cpk\":\"not-a-key\"}",
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

test "generated server tokens carry a P-384 JWK cpk bound to the private key" {
    const allocator = std.testing.allocator;
    const key = try Scheme.KeyPair.generateDeterministic(.{10} ** 48);

    const token = try serverToken(allocator, key, 1000);
    defer allocator.free(token);

    const parts = try split(token);

    const decoded_header = try decode64(allocator, parts[0]);
    defer allocator.free(decoded_header);
    const header = try parse(allocator, decoded_header);
    defer header.deinit();

    try std.testing.expectEqualStrings("ES384", try string(try field(header.value, "alg")));
    var der_buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        testPublicKey(key, &der_buffer),
        try string(try field(header.value, "x5u")),
    );

    const decoded_claims = try decode64(allocator, parts[1]);
    defer allocator.free(decoded_claims);
    const claims = try parse(allocator, decoded_claims);
    defer claims.deinit();

    const cpk = try field(claims.value, "cpk");
    try std.testing.expect(cpk == .object);
    try std.testing.expectEqualStrings("EC", try string(try field(cpk, "kty")));
    try std.testing.expectEqualStrings("P-384", try string(try field(cpk, "crv")));

    const sec1 = key.public_key.toUncompressedSec1();
    for ([_][2][]const u8{
        .{ "x", sec1[1..49] },
        .{ "y", sec1[49..97] },
    }) |expected| {
        const encoded = try string(try field(cpk, expected[0]));
        try std.testing.expectEqual(@as(usize, 64), encoded.len);
        const bytes = try decode64(allocator, encoded);
        defer allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, expected[1], bytes);
    }

    const public_key = try claimPublicKey(allocator, token, 1000, .server);
    try std.testing.expectEqualSlices(
        u8,
        &key.public_key.toUncompressedSec1(),
        &public_key.toUncompressedSec1(),
    );
}

test "cpk claims reject wrong key types, curves and malformed coordinates" {
    const allocator = std.testing.allocator;
    const key = try Scheme.KeyPair.generateDeterministic(.{11} ** 48);
    const sec1 = key.public_key.toUncompressedSec1();

    var x_buffer: [base64_url.Encoder.calcSize(48)]u8 = undefined;
    var y_buffer: [base64_url.Encoder.calcSize(48)]u8 = undefined;
    const y = base64_url.Encoder.encode(&y_buffer, sec1[49..97]);

    const Case = struct { cpk: []const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .cpk = "{\"kty\":\"RSA\",\"crv\":\"P-384\",\"x\":\"\",\"y\":\"\"}", .expected = error.UnsupportedKey },
        .{ .cpk = "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"\",\"y\":\"\"}", .expected = error.UnsupportedKey },
        .{ .cpk = "{\"crv\":\"P-384\",\"x\":\"\",\"y\":\"\"}", .expected = error.InvalidIdentity },
        .{ .cpk = "{\"kty\":\"EC\",\"crv\":\"P-384\",\"y\":\"\"}", .expected = error.InvalidIdentity },
        .{ .cpk = "{\"kty\":\"EC\",\"crv\":\"P-384\",\"x\":\"AA\",\"y\":\"AA\"}", .expected = error.InvalidIdentity },
        .{ .cpk = "{\"kty\":\"EC\",\"crv\":\"P-384\",\"x\":\"!!\",\"y\":\"!!\"}", .expected = error.InvalidCharacter },
        .{ .cpk = "0", .expected = error.InvalidIdentity },
    };

    for (cases) |case| {
        const claims = try std.fmt.allocPrint(
            allocator,
            "{{\"exp\":1060,\"iat\":1000,\"cpk\":{s}}}",
            .{case.cpk},
        );
        defer allocator.free(claims);

        const token = try testToken(allocator, key, "ES384", claims);
        defer allocator.free(token);

        try std.testing.expectError(
            case.expected,
            claimPublicKey(allocator, token, 1000, .server),
        );
    }

    var flipped = sec1;
    flipped[1] ^= 1;
    const bad_x = base64_url.Encoder.encode(&x_buffer, flipped[1..49]);
    const invalid = try std.fmt.allocPrint(
        allocator,
        "{{\"exp\":1060,\"iat\":1000,\"cpk\":{{\"kty\":\"EC\",\"crv\":\"P-384\",\"x\":\"{s}\",\"y\":\"{s}\"}}}}",
        .{ bad_x, y },
    );
    defer allocator.free(invalid);
    const invalid_token = try testToken(allocator, key, "ES384", invalid);
    defer allocator.free(invalid_token);
    if (claimPublicKey(allocator, invalid_token, 1000, .server)) |_| {
        return error.OffCurveKeyAccepted;
    } else |_| {}
}

test "base64 DER cpk claims from older peers still parse" {
    const allocator = std.testing.allocator;
    const key = try Scheme.KeyPair.generateDeterministic(.{12} ** 48);

    var der_buffer: [160]u8 = undefined;
    const claims = try std.fmt.allocPrint(
        allocator,
        "{{\"exp\":1060,\"iat\":1000,\"cpk\":\"{s}\"}}",
        .{testPublicKey(key, &der_buffer)},
    );
    defer allocator.free(claims);

    const token = try testToken(allocator, key, "ES384", claims);
    defer allocator.free(token);

    const public_key = try claimPublicKey(allocator, token, 1000, .server);
    try std.testing.expectEqualSlices(
        u8,
        &key.public_key.toUncompressedSec1(),
        &public_key.toUncompressedSec1(),
    );
}

test "server token temporal claims are optional but must be well formed" {
    const allocator = std.testing.allocator;
    const key = try Scheme.KeyPair.generateDeterministic(.{14} ** 48);

    var der_buffer: [160]u8 = undefined;
    const encoded_key = testPublicKey(key, &der_buffer);

    const Case = struct { temporal: []const u8, expected: ?anyerror };
    const cases = [_]Case{
        .{ .temporal = "", .expected = null },
        .{ .temporal = "\"iat\":1,", .expected = null },
        .{ .temporal = "\"iat\":4000000000,", .expected = null },
        .{ .temporal = "\"exp\":2000,", .expected = null },
        .{ .temporal = "\"exp\":900,", .expected = null },
        .{ .temporal = "\"iat\":\"soon\",", .expected = error.InvalidIdentity },
        .{ .temporal = "\"exp\":null,", .expected = error.InvalidIdentity },
        .{ .temporal = "\"nbf\":[],", .expected = error.InvalidIdentity },
    };

    for (cases) |case| {
        const claims = try std.fmt.allocPrint(
            allocator,
            "{{{s}\"cpk\":\"{s}\"}}",
            .{ case.temporal, encoded_key },
        );
        defer allocator.free(claims);

        const token = try testToken(allocator, key, "ES384", claims);
        defer allocator.free(token);

        if (case.expected) |expected| {
            try std.testing.expectError(
                expected,
                claimPublicKey(allocator, token, 1000, .server),
            );
        } else {
            _ = try claimPublicKey(allocator, token, 1000, .server);
        }
    }

    const claims = try std.fmt.allocPrint(
        allocator,
        "{{\"cpk\":\"{s}\"}}",
        .{encoded_key},
    );
    defer allocator.free(claims);

    const foreign = try Scheme.KeyPair.generateDeterministic(.{15} ** 48);
    const forged = try testToken(allocator, foreign, "ES384", claims);
    defer allocator.free(forged);

    if (claimPublicKey(allocator, forged, 1000, .server)) |_| {
        return error.ForeignSignatureAccepted;
    } else |_| {}

    try std.testing.expectError(
        error.InvalidIdentity,
        claimPublicKey(allocator, forged, 1000, .client),
    );
}
