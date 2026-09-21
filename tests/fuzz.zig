const std = @import("std");
const build_options = @import("build_options");
const core = @import("nethernet_core");
const discovery = core.discovery_codec;
const framing = core.framing;
const Signal = core.Signal;
const ServerData = core.ServerData;
const identity = core.identity;
const sdp_identity = core.sdp_identity;
const identity_file = core.identity_file;

pub fn exercise(input: []u8) void {
    var scratch: [4096]u8 = undefined;
    const codec = discovery.Codec.init();
    _ = codec.decode(input, &scratch) catch {};
    _ = Signal.parse(input) catch {};
    _ = ServerData.decode(input) catch {};
    var decoder = framing.Reassembler.init(&scratch, .reliable);
    var offset: usize = 0;
    while (offset < input.len) {
        const len: usize = @min(@as(usize, input[offset]) + 1, input.len - offset);
        _ = decoder.push(input[offset..][0..len]) catch {};
        offset += len;
    }
    _ = discovery.decodePayload(input) catch {};

    const allocator = std.testing.allocator;
    if (identity.decode64(allocator, input)) |decoded| {
        allocator.free(decoded);
    } else |_| {}

    if (identity.parse(allocator, input)) |parsed| {
        parsed.deinit();
    } else |_| {}

    if (sdp_identity.fingerprintPayload(allocator, input)) |payload| {
        allocator.free(payload);
    } else |_| {}

    _ = identity_file.decode(input) catch {};

    for ([_]identity.IdentityKind{ .server, .client }) |kind| {
        _ = identity.claimPublicKey(allocator, input, 1000, kind) catch {};
        if (sdp_identity.verify(allocator, input, 1000, kind, null)) |_| {} else |_| {}
    }

    // Any signal that parses must re-encode to exactly its source.
    if (Signal.parse(input)) |signal| {
        var buffer: [8192]u8 = undefined;
        if (signal.encode(&buffer)) |encoded| {
            std.debug.assert(std.mem.eql(u8, encoded, input));
        } else |_| {}
    } else |_| {}
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4096]u8 = undefined;
    const len = smith.sliceWithHash(&bytes, 0x74129);
    exercise(bytes[0..len]);
}

test "fuzz protocol parsers and fragment state transitions" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{ "", "CONNECTREQUEST 7 v=0\r\n", &.{ 1, 2, 0, 3 } } });
}

test "deterministic malformed input campaign" {
    var random = std.Random.DefaultPrng.init(0xBEdBEd);
    var bytes: [4096]u8 = undefined;
    for (0..build_options.fuzz_iterations) |i| {
        const len = i % (bytes.len + 1);
        random.random().bytes(bytes[0..len]);
        exercise(bytes[0..len]);
    }
}

// Random bytes almost never form valid DER, so the decoder is also driven
// with mutations of a real key to reach its deeper paths.
test "identity decoder survives mutations of a valid key" {
    var encoded: [identity_file.encoded_size]u8 = undefined;
    _ = identity_file.encode(
        try identity_file.KeyPair.generateDeterministic(.{9} ** 48),
        &encoded,
    );

    // Tags, and the short, long and reserved length forms.
    const hostile_bytes = [_]u8{ 0x00, 0x01, 0x02, 0x04, 0x06, 0x30, 0x31, 0x7f, 0x80, 0x81, 0x84, 0x88, 0xfe, 0xff };

    for (0..encoded.len) |offset| {
        for (hostile_bytes) |value| {
            var damaged = encoded;
            damaged[offset] = value;
            _ = identity_file.decode(&damaged) catch {};
            _ = identity_file.decode(damaged[0 .. offset + 1]) catch {};
        }
    }

    var extended: [identity_file.encoded_size * 2]u8 = undefined;
    @memset(&extended, 0xff);
    for (0..encoded.len + 1) |len| {
        @memcpy(extended[0..len], encoded[0..len]);
        for (0..8) |extra| {
            _ = identity_file.decode(extended[0 .. len + extra]) catch {};
        }
    }

    const hostile = [_][]const u8{
        &.{ 0x30, 0x80 },
        &.{ 0x30, 0x81 },
        &.{ 0x30, 0x81, 0xff },
        &.{ 0x30, 0x84, 0xff, 0xff, 0xff, 0xff },
        &.{ 0x30, 0x88, 0, 0, 0, 0, 0, 0, 0, 0 },
        &.{ 0x30, 0xff },
        &.{ 0x30, 0xfe, 0xff },
        &.{0x30},
        &.{ 0x30, 0x02, 0x02, 0x81 },
        &.{ 0x30, 0x06, 0x02, 0x01, 0x00, 0x30, 0x81, 0xff },
    };
    for (hostile) |case| _ = identity_file.decode(case) catch {};

    // Bounded: each accepted key costs a P-384 scalar multiplication.
    var random = std.Random.DefaultPrng.init(0xA11CE);
    var buffer: [identity_file.encoded_size]u8 = undefined;
    for (0..@min(build_options.fuzz_iterations, 2000)) |i| {
        buffer = encoded;
        const keep = i % encoded.len;
        random.random().bytes(buffer[keep..]);
        _ = identity_file.decode(&buffer) catch {};
        _ = identity_file.decode(buffer[0 .. keep + 1]) catch {};
    }
}

// Random input never reaches the identity verifier, so it is also driven with
// mutations of a genuinely signed SDP.
test "SDP identity verifier survives mutations of a signed assertion" {
    const allocator = std.testing.allocator;

    const key = try identity.Scheme.KeyPair.generateDeterministic(.{3} ** 48);
    const token = try identity.serverToken(allocator, key, 1000);
    defer allocator.free(token);

    const source =
        "v=0\r\n" ++
        "a=fingerprint:sha-256 00:11:22:33\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n";

    const signed = try sdp_identity.add(allocator, source, .{
        .key = key,
        .token = token,
    });
    defer allocator.free(signed);

    if ((try sdp_identity.verify(allocator, signed, 1000, .server, null)) == null) {
        return error.ValidAssertionRejected;
    }

    const damaged = try allocator.alloc(u8, signed.len);
    defer allocator.free(damaged);

    const hostile_bytes = [_]u8{ 0, 0x22, 0x5c, 0x7b, 0x7d, '.', '=', ':', 0x0d, 0x0a, 'A', 0xff };

    for (0..signed.len) |offset| {
        for (hostile_bytes) |value| {
            @memcpy(damaged, signed);
            damaged[offset] = value;
            if (sdp_identity.verify(allocator, damaged, 1000, .server, null)) |_| {} else |_| {}
        }
    }

    // The assertion signs only the canonical fingerprint JSON, so touching
    // other lines may still verify. Touching a fingerprint never may.
    const line = std.mem.indexOf(u8, signed, "a=fingerprint:").?;
    const line_end = std.mem.indexOfScalarPos(u8, signed, line, '\r').?;

    for (line..line_end) |offset| {
        for (hostile_bytes) |value| {
            if (signed[offset] == value) continue;

            @memcpy(damaged, signed);
            damaged[offset] = value;

            if (sdp_identity.verify(allocator, damaged, 1000, .server, null)) |result| {
                if (result != null) return error.TamperedFingerprintAccepted;
            } else |_| {}
        }
    }

    // Duplicated, truncated and relocated assertions.
    for (0..signed.len) |len| {
        if (sdp_identity.verify(allocator, signed[0..len], 1000, .server, null)) |_| {} else |_| {}
    }

    const doubled = try std.fmt.allocPrint(allocator, "{s}{s}", .{ signed, signed });
    defer allocator.free(doubled);
    if (sdp_identity.verify(allocator, doubled, 1000, .server, null)) |_| {
        return error.DuplicateAssertionAccepted;
    } else |_| {}

    // Clock boundaries around the token's validity window.
    for ([_]i64{ std.math.minInt(i64), -1, 0, 999, 1000, 1001, std.math.maxInt(i64) }) |now| {
        if (sdp_identity.verify(allocator, signed, now, .server, null)) |_| {} else |_| {}
        if (sdp_identity.verify(allocator, signed, now, .client, null)) |_| {} else |_| {}
    }
}
