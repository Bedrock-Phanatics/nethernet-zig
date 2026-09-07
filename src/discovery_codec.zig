const std = @import("std");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Aes = std.crypto.core.aes.Aes256;

pub const maximum_payload = 65535;
pub const maximum_datagram = 32 + 65536;

pub const Packet = union(enum(u16)) {
    request = 0,
    response: []const u8 = 1,
    message: struct {
        recipient_id: u64,
        data: []const u8,
    } = 2,
};

pub const Decoded = struct {
    sender_id: u64,
    packet: Packet,
};

/// The caller provides separate buffers that the codec can reuse.
pub const Codec = struct {
    key: [32]u8,
    enc: std.crypto.core.aes.AesEncryptCtx(Aes),
    dec: std.crypto.core.aes.AesDecryptCtx(Aes),

    pub fn init() Codec {
        var key: [32]u8 = undefined;

        std.crypto.hash.sha2.Sha256.hash(
            &.{ 0xef, 0xbe, 0xad, 0xde, 0, 0, 0, 0 },
            &key,
            .{},
        );

        return .{
            .key = key,
            .enc = Aes.initEnc(key),
            .dec = Aes.initDec(key),
        };
    }

    pub fn encode(
        self: *const Codec,
        packet: Packet,
        sender_id: u64,
        scratch: []u8,
        output: []u8,
    ) ![]const u8 {
        const size: usize = switch (packet) {
            .request => 20,

            .response => |data| blk: {
                if (data.len > (maximum_payload - 24) / 2) {
                    return error.MessageTooLarge;
                }

                break :blk 24 + data.len * 2;
            },

            .message => |message| blk: {
                if (message.data.len > maximum_payload - 32) {
                    return error.MessageTooLarge;
                }

                break :blk 32 + message.data.len;
            },
        };

        const padded = (size / 16 + 1) * 16;

        if (scratch.len < padded or output.len < padded + 32) {
            return error.NoSpaceLeft;
        }

        std.mem.writeInt(u16, scratch[0..2], @intCast(size), .little);
        std.mem.writeInt(u16, scratch[2..4], @intFromEnum(packet), .little);
        std.mem.writeInt(u64, scratch[4..12], sender_id, .little);
        @memset(scratch[12..20], 0);

        switch (packet) {
            .request => {},

            .response => |data| {
                std.mem.writeInt(
                    u32,
                    scratch[20..24],
                    @intCast(data.len * 2),
                    .little,
                );

                const hex = "0123456789abcdef";

                for (data, 0..) |byte, i| {
                    scratch[24 + i * 2] = hex[byte >> 4];
                    scratch[25 + i * 2] = hex[byte & 15];
                }
            },

            .message => |message| {
                std.mem.writeInt(
                    u64,
                    scratch[20..28],
                    message.recipient_id,
                    .little,
                );
                std.mem.writeInt(
                    u32,
                    scratch[28..32],
                    @intCast(message.data.len),
                    .little,
                );

                @memcpy(scratch[32..size], message.data);
            },
        }

        Hmac.create(output[0..32], scratch[0..size], &self.key);
        @memset(scratch[size..padded], @intCast(padded - size));

        var offset: usize = 0;
        while (offset < padded) : (offset += 16) {
            self.enc.encrypt(
                output[32 + offset ..][0..16],
                scratch[offset..][0..16],
            );
        }

        return output[0 .. padded + 32];
    }

    /// The result uses the scratch buffer. Failed authentication never exposes plaintext.
    pub fn decode(
        self: *const Codec,
        datagram: []const u8,
        scratch: []u8,
    ) !Decoded {
        if (datagram.len < 48 or
            datagram.len > maximum_datagram or
            (datagram.len - 32) % 16 != 0)
        {
            return error.MalformedPacket;
        }

        const padded = datagram.len - 32;
        if (scratch.len < padded) return error.NoSpaceLeft;

        var offset: usize = 0;
        while (offset < padded) : (offset += 16) {
            self.dec.decrypt(
                scratch[offset..][0..16],
                datagram[32 + offset ..][0..16],
            );
        }

        const pad: usize = scratch[padded - 1];
        if (pad == 0 or pad > 16) {
            return error.AuthenticationFailed;
        }

        var mismatch: u8 = 0;
        for (scratch[padded - pad .. padded]) |byte| {
            mismatch |= byte ^ @as(u8, @intCast(pad));
        }

        if (mismatch != 0) {
            return error.AuthenticationFailed;
        }

        const size = padded - pad;

        var expected: [32]u8 = undefined;
        Hmac.create(&expected, scratch[0..size], &self.key);

        if (!std.crypto.timing_safe.eql(
            [32]u8,
            expected,
            datagram[0..32].*,
        )) {
            return error.AuthenticationFailed;
        }

        return decodePayload(scratch[0..size]);
    }
};

/// Decodes authenticated payloads in the provided buffer.
pub fn decodePayload(payload: []u8) !Decoded {
    if (payload.len < 20 or payload.len > maximum_payload) {
        return error.MalformedPacket;
    }

    const declared_size = std.mem.readInt(u16, payload[0..2], .little);
    if (declared_size != payload.len and declared_size != payload.len - 2) {
        return error.MalformedPacket;
    }

    const packet_id = std.mem.readInt(u16, payload[2..4], .little);
    const sender_id = std.mem.readInt(u64, payload[4..12], .little);

    const packet: Packet = switch (packet_id) {
        0 => blk: {
            if (payload.len != 20) return error.MalformedPacket;
            break :blk .request;
        },

        1 => blk: {
            if (payload.len < 24) return error.MalformedPacket;

            const length = std.mem.readInt(u32, payload[20..24], .little);
            if (length != payload.len - 24 or length % 2 != 0) {
                return error.MalformedPacket;
            }

            const data = std.fmt.hexToBytes(
                payload[24..][0 .. length / 2],
                payload[24..],
            ) catch return error.MalformedPacket;

            break :blk .{ .response = data };
        },

        2 => blk: {
            if (payload.len < 32) return error.MalformedPacket;

            const length = std.mem.readInt(u32, payload[28..32], .little);
            if (length > payload.len - 32) {
                return error.MalformedPacket;
            }

            // Bedrock accepts trailing bytes after the declared string.
            break :blk .{
                .message = .{
                    .recipient_id = std.mem.readInt(
                        u64,
                        payload[20..28],
                        .little,
                    ),
                    .data = payload[32..],
                },
            };
        },

        else => return error.MalformedPacket,
    };

    return .{
        .sender_id = sender_id,
        .packet = packet,
    };
}

test "all packet kinds roundtrip and reject tampering" {
    const codec = Codec.init();

    var scratch: [256]u8 = undefined;
    var wire: [256]u8 = undefined;

    const packets = [_]Packet{
        .request,
        .{ .response = &.{ 0, 1, 2, 0xfe, 0xff } },
        .{
            .message = .{
                .recipient_id = 9,
                .data = "CONNECTREQUEST 7 v=0\r\n",
            },
        },
    };

    for (packets) |packet| {
        const encoded = try codec.encode(
            packet,
            0x1020304050607080,
            &scratch,
            &wire,
        );
        const decoded = try codec.decode(encoded, &scratch);

        try std.testing.expectEqual(
            @as(u64, 0x1020304050607080),
            decoded.sender_id,
        );
        try std.testing.expectEqual(
            std.meta.activeTag(packet),
            std.meta.activeTag(decoded.packet),
        );

        switch (packet) {
            .request => {},

            .response => |data| {
                try std.testing.expectEqualSlices(
                    u8,
                    data,
                    decoded.packet.response,
                );
            },

            .message => |message| {
                try std.testing.expectEqual(
                    message.recipient_id,
                    decoded.packet.message.recipient_id,
                );
                try std.testing.expectEqualStrings(
                    message.data,
                    decoded.packet.message.data,
                );
            },
        }

        wire[0] ^= 1;

        try std.testing.expectError(
            error.AuthenticationFailed,
            codec.decode(encoded, &scratch),
        );
    }
}

test "arbitrary datagrams and plaintext fail safely without allocations" {
    const codec = Codec.init();

    var random = std.Random.DefaultPrng.init(1234);
    var input: [512]u8 = undefined;
    var scratch: [512]u8 = undefined;

    for (0..4096) |i| {
        const length = i % input.len;
        random.random().bytes(input[0..length]);

        _ = codec.decode(input[0..length], &scratch) catch {};
        _ = decodePayload(input[0..length]) catch {};
    }
}
