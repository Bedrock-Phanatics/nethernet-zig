const std = @import("std");
const discovery = @import("nethernet_core").discovery_codec;

test "trusted issuer verifies independent RS256 tokens and rejects invalid claims" {
    const issuer = @import("nethernet_core").identity_issuer;
    const allocator = std.testing.allocator;
    const fixture = try std.json.parseFromSlice(struct {
        jwks: []const u8,
        vectors: []const struct { name: []const u8, token: []const u8 },
    }, allocator, @embedFile("fixtures/issuer.json"), .{});
    defer fixture.deinit();
    const keys = try issuer.Keys.init(allocator, fixture.value.jwks, "https://issuer.test/", "test-audience");
    defer keys.deinit();
    const secret = try @import("nethernet_core").identity.Scheme.SecretKey.fromBytes(@as([47]u8, @splat(0)) ++ [_]u8{1});
    const expected = try @import("nethernet_core").identity.Scheme.KeyPair.fromSecretKey(secret);
    for (fixture.value.vectors) |vector| {
        const failure: ?anyerror = if (std.mem.eql(u8, vector.name, "issuer")) error.UntrustedIssuer else if (std.mem.eql(u8, vector.name, "audience")) error.InvalidAudience else if (std.mem.eql(u8, vector.name, "expired")) error.ExpiredIdentity else if (std.mem.eql(u8, vector.name, "future")) error.InvalidIdentity else null;
        if (failure) |err| {
            try std.testing.expectError(err, keys.verify(allocator, vector.token, 1000));
        } else {
            const key = try keys.verify(allocator, vector.token, 1000);
            try std.testing.expectEqualSlices(u8, &expected.public_key.toUncompressedSec1(), &key.toUncompressedSec1());
        }
        const tampered = try allocator.dupe(u8, vector.token);
        defer allocator.free(tampered);
        tampered[tampered.len - 8] = if (tampered[tampered.len - 8] == 'A') 'B' else 'A';
        if (keys.verify(allocator, tampered, 1000)) |_| return error.ForgedIssuerAccepted else |_| {}
    }
}

fn issuerAllocationScenario(allocator: std.mem.Allocator) !void {
    const fixture = try std.json.parseFromSlice(struct {
        jwks: []const u8,
        vectors: []const struct { name: []const u8, token: []const u8 },
    }, allocator, @embedFile("fixtures/issuer.json"), .{});
    defer fixture.deinit();
    const keys = try @import("nethernet_core").identity_issuer.Keys.init(allocator, fixture.value.jwks, "https://issuer.test/", "test-audience");
    defer keys.deinit();
    _ = try keys.verify(allocator, fixture.value.vectors[0].token, 1000);
}

test "issuer verification releases partial allocations" {
    // Zig 0.17's std.json allocates a different number of times across identical release-mode runs,
    // which breaks this check's determinism, so it runs in Debug where every failure point is reached.
    if (@import("builtin").mode != .debug) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, issuerAllocationScenario, .{});
}

test "identity verifies an independently signed multi-fingerprint assertion" {
    const auth = @import("nethernet_core").sdp_identity;
    const allocator = std.testing.allocator;
    const fixture = try std.json.parseFromSlice(
        struct { sdp: []const u8, payload: []const u8, public_key: []const u8 },
        allocator,
        @embedFile("fixtures/identity.json"),
        .{},
    );
    defer fixture.deinit();

    const payload = try auth.fingerprintPayload(allocator, fixture.value.sdp);
    defer allocator.free(payload);
    try std.testing.expectEqualStrings(fixture.value.payload, payload);

    const key = (try auth.verify(allocator, fixture.value.sdp, 1000, .server, null)) orelse
        return error.MissingIdentity;
    var expected: [97]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        try std.fmt.hexToBytes(&expected, fixture.value.public_key),
        &key.toUncompressedSec1(),
    );
    // Server identities skip the time checks, like vanilla.
    _ = try auth.verify(allocator, fixture.value.sdp, 2061, .server, null);
}

test "discovery packets match encrypted wire fixtures" {
    const Vector = struct { kind: []const u8, payload: []const u8, wire: []const u8 };
    const vectors = try std.json.parseFromSlice(
        []Vector,
        std.testing.allocator,
        @embedFile("fixtures/discovery.json"),
        .{},
    );
    defer vectors.deinit();

    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u8, discovery.maximum_datagram);
    defer allocator.free(scratch);

    const output = try allocator.alloc(u8, discovery.maximum_datagram);
    defer allocator.free(output);

    const wire = try allocator.alloc(u8, discovery.maximum_datagram);
    defer allocator.free(wire);

    const payload = try allocator.alloc(u8, discovery.maximum_payload);
    defer allocator.free(payload);

    const codec = discovery.Codec.init();
    for (vectors.value) |vector| {
        const expected = try std.fmt.hexToBytes(wire, vector.wire);
        const packet: discovery.Packet = if (std.mem.eql(u8, vector.kind, "request"))
            .request
        else if (std.mem.eql(u8, vector.kind, "response"))
            .{ .response = try std.fmt.hexToBytes(payload, vector.payload) }
        else
            .{ .message = .{ .recipient_id = 9, .data = vector.payload } };
        try std.testing.expectEqualSlices(u8, expected, try codec.encode(packet, 0x1020304050607080, scratch, output));
        const decoded = try codec.decode(expected, scratch);
        switch (packet) {
            .request => try std.testing.expect(decoded.packet == .request),
            .response => |bytes| try std.testing.expectEqualSlices(u8, bytes, decoded.packet.response),
            .message => |message| {
                try std.testing.expectEqual(message.recipient_id, decoded.packet.message.recipient_id);
                try std.testing.expectEqualStrings(message.data, decoded.packet.message.data);
            },
            .reliable, .acknowledgement => unreachable,
        }
    }
}

test "reliable LAN packets match Axolotl's encrypted wire" {
    const codec = discovery.Codec.init();
    var scratch: [256]u8 = undefined;
    var output: [256]u8 = undefined;
    var expected: [256]u8 = undefined;

    const reliable: discovery.Packet = .{ .reliable = .{ .recipient_id = 2, .nonce = 3, .sequence = 4, .data = "CONNECTREQUEST 1 offer" } };
    const ack: discovery.Packet = .{ .acknowledgement = .{ .recipient_id = 2, .nonce = 3, .sequence = 4 } };
    const vectors = [_]struct { discovery.Packet, []const u8 }{
        .{ reliable, "bcedcc6781bdeed7b8ebb9f013716629ccc954af937a6659281668f1c2ed1e00d245c864a0c7db9ff371e42937f4a17fa3b7005c625b970542e005cb853659a2076c1a59104bdae246047c0702c9fb38689270cff56084df27d4f91cd688d08f7e101c2770a9140dcceacf94a0ec0923f45ba872336fc2f926bcb3484ffadbbcb0d1e11a416f0ec3b88616c05db0164c" },
        .{ ack, "edc1d4c378e651e8dbcb452ea9f8d6848ce87ef82e0f0f9db9f23d7e0ffa6bee7fea78c3d9fd9e3d13b95a310491c5e9a3b7005c625b970542e005cb853659a2716dbef34537ffae1151c5df9d751645" },
    };
    for (vectors) |vector| {
        const wire = try std.fmt.hexToBytes(&expected, vector[1]);
        try std.testing.expectEqualSlices(u8, wire, try codec.encode(vector[0], 0x1020304050607080, &scratch, &output));
        const decoded = try codec.decode(wire, &scratch);
        try std.testing.expectEqual(@as(u64, 0x1020304050607080), decoded.sender_id);
        switch (vector[0]) {
            .reliable => |packet| {
                try std.testing.expectEqualStrings(packet.data, decoded.packet.reliable.data);
                try std.testing.expectEqual(packet.sequence, decoded.packet.reliable.sequence);
            },
            .acknowledgement => |packet| try std.testing.expectEqual(packet, decoded.packet.acknowledgement),
            else => unreachable,
        }
    }
}
