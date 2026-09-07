const std = @import("std");
const discovery = @import("../src/discovery_codec.zig");

test "discovery packets match encrypted wire fixtures" {
    const Vector = struct { kind: []const u8, payload: []const u8, wire: []const u8 };
    const vectors = try std.json.parseFromSlice([]Vector, std.testing.allocator, @embedFile("fixtures/discovery.json"), .{});
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
        const packet: discovery.Packet = if (std.mem.eql(u8, vector.kind, "request")) .request else if (std.mem.eql(u8, vector.kind, "response"))
            .{ .response = try std.fmt.hexToBytes(payload, vector.payload) }
        else
            .{ .message = .{ .recipient_id = 9, .data = vector.payload } };
        try std.testing.expectEqualSlices(u8, expected, try codec.encode(packet, 0x1020304050607080, scratch, output));
        const decoded = try codec.decode(expected, scratch);
        switch (packet) {
            .request => try std.testing.expect(decoded.packet == .request),
            .response => |bytes| try std.testing.expectEqualSlices(u8, bytes, decoded.packet.response),
            .message => |message| try std.testing.expectEqualStrings(message.data, decoded.packet.message.data),
        }
    }
}
