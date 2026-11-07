const std = @import("std");
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Aes = std.crypto.core.aes.Aes256;

pub const maximum_payload = 65535;
pub const maximum_response_data = (maximum_payload - 24) / 2;
pub const maximum_datagram = 32 + 65536;
/// Vanilla declares at most this much message data, though it still sends all of it.
pub const maximum_declared_message_data = 1140;
/// Reliable packets and acknowledgements, added in 26.70, carry this in the header's version field.
pub const reliable_version = 1;

const header_size = 20;
const message_header_size = 32;
const reliable_header_size = header_size + 24;

pub const Message = struct {
    recipient_id: u64,
    data: []const u8,
};

pub const Acknowledgement = struct {
    recipient_id: u64,
    nonce: u64,
    sequence: u64,
};

/// A message the recipient acknowledges. The sender keeps one nonzero nonce and raises the sequence per message.
pub const Reliable = struct {
    recipient_id: u64,
    nonce: u64,
    sequence: u64,
    data: []const u8,
};

pub const Packet = union(enum(u16)) {
    request = 0,
    response: []const u8 = 1,
    message: Message = 2,
    reliable: Reliable = 3,
    acknowledgement: Acknowledgement = 4,
};

pub const Decoded = struct {
    sender_id: u64,
    packet: Packet,
};

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
            .request => header_size,
            .response => |data| blk: {
                if (data.len > maximum_response_data) return error.MessageTooLarge;
                break :blk 24 + data.len * 2;
            },
            .message => |message| blk: {
                if (message.data.len > maximum_payload - message_header_size) return error.MessageTooLarge;
                break :blk message_header_size + message.data.len;
            },
            .reliable => |reliable| blk: {
                if (reliable.data.len > maximum_payload - reliable_header_size - message_header_size)
                    return error.MessageTooLarge;
                break :blk reliable_header_size + message_header_size + reliable.data.len;
            },
            .acknowledgement => reliable_header_size,
        };

        const padded = (size / 16 + 1) * 16;
        if (scratch.len < padded or output.len < padded + 32) return error.NoSpaceLeft;

        const version: u64 = switch (packet) {
            .reliable, .acknowledgement => reliable_version,
            else => 0,
        };
        writeHeader(scratch, size, @backingInt(packet), sender_id, version);

        switch (packet) {
            .request => {},
            .response => |data| {
                std.mem.writeInt(u32, scratch[20..24], @intCast(data.len * 2), .little);
                const hex = "0123456789abcdef";
                for (data, 0..) |byte, i| {
                    scratch[24 + i * 2] = hex[byte >> 4];
                    scratch[25 + i * 2] = hex[byte & 15];
                }
            },
            .message => |message| _ = writeMessage(scratch[0..size], 0, sender_id, message),
            .reliable => |reliable| {
                writeAddressing(scratch, reliable.recipient_id, reliable.nonce, reliable.sequence);
                const nested = writeMessage(scratch[reliable_header_size..size], reliable_version, sender_id, .{
                    .recipient_id = reliable.recipient_id,
                    .data = reliable.data,
                });
                // The outer length only covers as much of the wrapped message as that declares.
                std.mem.writeInt(u16, scratch[0..2], @intCast(reliable_header_size + nested), .little);
            },
            .acknowledgement => |ack| writeAddressing(scratch, ack.recipient_id, ack.nonce, ack.sequence),
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

        var authenticated = false;
        defer if (!authenticated) std.crypto.secureZero(u8, scratch[0..padded]);

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

        const decoded = try decodePayload(scratch[0..size]);
        authenticated = true;
        return decoded;
    }
};

fn writeHeader(out: []u8, size: usize, id: u16, sender_id: u64, version: u64) void {
    std.mem.writeInt(u16, out[0..2], @intCast(size), .little);
    std.mem.writeInt(u16, out[2..4], id, .little);
    std.mem.writeInt(u64, out[4..12], sender_id, .little);
    std.mem.writeInt(u64, out[12..20], version, .little);
}

fn writeAddressing(out: []u8, recipient_id: u64, nonce: u64, sequence: u64) void {
    std.mem.writeInt(u64, out[20..28], recipient_id, .little);
    std.mem.writeInt(u64, out[28..36], nonce, .little);
    std.mem.writeInt(u64, out[36..44], sequence, .little);
}

/// Like vanilla, long data is declared as only its first 1140 bytes, and all of it follows.
/// Returns the declared size.
fn writeMessage(out: []u8, version: u64, sender_id: u64, message: Message) usize {
    const declared = @min(message.data.len, maximum_declared_message_data);
    writeHeader(out, message_header_size + declared, @backingInt(Packet.message), sender_id, version);
    std.mem.writeInt(u64, out[20..28], message.recipient_id, .little);
    std.mem.writeInt(u32, out[28..32], @intCast(declared), .little);
    @memcpy(out[message_header_size..][0..message.data.len], message.data);
    return message_header_size + declared;
}

const Header = struct { id: u16, sender_id: u64, version: u64 };

fn readHeader(payload: []const u8) !Header {
    if (payload.len < header_size) return error.MalformedPacket;
    // Vanilla caps the declared size of long messages but sends the rest, so only a short payload is malformed.
    if (std.mem.readInt(u16, payload[0..2], .little) > payload.len) return error.MalformedPacket;
    // Like the reference, requests, responses and messages ignore the version, only reliable packets need it.
    return .{
        .id = std.mem.readInt(u16, payload[2..4], .little),
        .sender_id = std.mem.readInt(u64, payload[4..12], .little),
        .version = std.mem.readInt(u64, payload[12..20], .little),
    };
}

fn readMessage(payload: []u8) !Message {
    if (payload.len < message_header_size) return error.MalformedPacket;
    // Like vanilla, the data runs to the end of the payload whatever length it declares.
    return .{
        .recipient_id = std.mem.readInt(u64, payload[20..28], .little),
        .data = payload[message_header_size..],
    };
}

pub fn decodePayload(payload: []u8) !Decoded {
    if (payload.len > maximum_payload) return error.MalformedPacket;
    const header = try readHeader(payload);

    const packet: Packet = switch (header.id) {
        0 => .request,

        // Like messages, vanilla reads response data to the end and ignores its nested length.
        1 => blk: {
            if (payload.len < 24 or (payload.len - 24) % 2 != 0) return error.MalformedPacket;

            const data = std.fmt.hexToBytes(
                payload[24..][0 .. (payload.len - 24) / 2],
                payload[24..],
            ) catch return error.MalformedPacket;

            break :blk .{ .response = data };
        },

        2 => .{ .message = try readMessage(payload) },

        3, 4 => blk: {
            if (header.version != reliable_version or payload.len < reliable_header_size)
                return error.MalformedPacket;
            const recipient_id = std.mem.readInt(u64, payload[20..28], .little);
            const nonce = std.mem.readInt(u64, payload[28..36], .little);
            const sequence = std.mem.readInt(u64, payload[36..44], .little);
            if (header.sender_id == 0 or recipient_id == 0 or nonce == 0 or sequence == 0)
                return error.MalformedPacket;

            if (header.id == 4) break :blk .{ .acknowledgement = .{
                .recipient_id = recipient_id,
                .nonce = nonce,
                .sequence = sequence,
            } };

            // The wrapped message carries a full header of its own, addressed like the outer packet.
            const nested = payload[reliable_header_size..];
            const inner = readHeader(nested) catch return error.MalformedPacket;
            if (inner.id != 2 or inner.version != reliable_version or inner.sender_id != header.sender_id)
                return error.MalformedPacket;
            const message = try readMessage(nested);
            if (message.recipient_id != recipient_id) return error.MalformedPacket;

            break :blk .{ .reliable = .{
                .recipient_id = recipient_id,
                .nonce = nonce,
                .sequence = sequence,
                .data = message.data,
            } };
        },

        else => return error.MalformedPacket,
    };

    return .{
        .sender_id = header.sender_id,
        .packet = packet,
    };
}

test "all packet kinds roundtrip and reject tampering" {
    const Tag = std.meta.Tag(Packet);
    try std.testing.expectEqual(@as(u16, 0), @backingInt(Tag.request));
    try std.testing.expectEqual(@as(u16, 1), @backingInt(Tag.response));
    try std.testing.expectEqual(@as(u16, 2), @backingInt(Tag.message));
    try std.testing.expectEqual(@as(u16, 3), @backingInt(Tag.reliable));
    try std.testing.expectEqual(@as(u16, 4), @backingInt(Tag.acknowledgement));

    const codec = Codec.init();

    var scratch: [256]u8 = undefined;
    var wire: [256]u8 = undefined;

    const packets = [_]Packet{
        .request,
        .{ .response = &.{ 0, 1, 2, 0xfe, 0xff } },
        .{ .message = .{ .recipient_id = 9, .data = "CONNECTREQUEST 7 v=0\r\n" } },
        .{ .reliable = .{ .recipient_id = 9, .nonce = 5, .sequence = 3, .data = "CANDIDATEADD 7 a\r\n" } },
        .{ .acknowledgement = .{ .recipient_id = 9, .nonce = 5, .sequence = 3 } },
    };

    for (packets) |packet| {
        const encoded = try codec.encode(packet, 0x1020304050607080, &scratch, &wire);
        const decoded = try codec.decode(encoded, &scratch);

        try std.testing.expectEqual(@as(u64, 0x1020304050607080), decoded.sender_id);
        try std.testing.expectEqual(std.meta.activeTag(packet), std.meta.activeTag(decoded.packet));

        switch (packet) {
            .request => {},
            .response => |data| try std.testing.expectEqualSlices(u8, data, decoded.packet.response),
            .message => |message| {
                try std.testing.expectEqual(message.recipient_id, decoded.packet.message.recipient_id);
                try std.testing.expectEqualStrings(message.data, decoded.packet.message.data);
            },
            .reliable => |reliable| {
                const got = decoded.packet.reliable;
                try std.testing.expectEqual(reliable.recipient_id, got.recipient_id);
                try std.testing.expectEqual(reliable.nonce, got.nonce);
                try std.testing.expectEqual(reliable.sequence, got.sequence);
                try std.testing.expectEqualStrings(reliable.data, got.data);
            },
            .acknowledgement => |ack| try std.testing.expectEqual(ack, decoded.packet.acknowledgement),
        }

        wire[0] ^= 1;

        try std.testing.expectError(error.AuthenticationFailed, codec.decode(encoded, &scratch));
        for (scratch[0 .. encoded.len - 32]) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
}

fn plaintext(codec: *const Codec, packet: Packet, scratch: []u8, wire: []u8) ![]u8 {
    const encoded = try codec.encode(packet, 0x1020304050607080, scratch, wire);
    _ = try codec.decode(encoded, scratch);
    const padded = encoded.len - 32;
    return scratch[0 .. padded - scratch[padded - 1]];
}

test "reliable packets and acknowledgements match the reference layout" {
    const codec = Codec.init();
    var scratch: [256]u8 = undefined;
    var wire: [256]u8 = undefined;
    var expected: [128]u8 = undefined;

    // From Axolotl's PacketTest, which follows vanilla 26.70.
    const reliable = try plaintext(&codec, .{ .reliable = .{
        .recipient_id = 0xAABBCCDD,
        .nonce = 0x55,
        .sequence = 7,
        .data = "Ping",
    } }, &scratch, &wire);
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&expected, "5000" ++ "0300" ++ "8070605040302010" ++ "0100000000000000" ++
        "ddccbbaa00000000" ++ "5500000000000000" ++ "0700000000000000" ++
        "2400" ++ "0200" ++ "8070605040302010" ++ "0100000000000000" ++
        "ddccbbaa00000000" ++ "04000000" ++ "50696e67"), reliable);

    const ack = try plaintext(&codec, .{ .acknowledgement = .{ .recipient_id = 2, .nonce = 3, .sequence = 4 } }, &scratch, &wire);
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&expected, "2c00" ++ "0400" ++ "8070605040302010" ++ "0100000000000000" ++
        "0200000000000000" ++ "0300000000000000" ++ "0400000000000000"), ack);
}

test "long messages declare vanilla's capped length and keep all their data" {
    const codec = Codec.init();
    var scratch: [4096]u8 = undefined;
    var wire: [4096]u8 = undefined;
    var data: [maximum_declared_message_data + 100]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));

    const message = try plaintext(&codec, .{ .message = .{ .recipient_id = 2, .data = &data } }, &scratch, &wire);
    try std.testing.expectEqual(@as(u16, 32 + 1140), std.mem.readInt(u16, message[0..2], .little));
    try std.testing.expectEqual(@as(u32, 1140), std.mem.readInt(u32, message[28..32], .little));
    try std.testing.expectEqualStrings(&data, (try decodePayload(message)).packet.message.data);

    const reliable = try plaintext(&codec, .{ .reliable = .{ .recipient_id = 2, .nonce = 1, .sequence = 1, .data = &data } }, &scratch, &wire);
    try std.testing.expectEqual(@as(u16, 44 + 32 + 1140), std.mem.readInt(u16, reliable[0..2], .little));
    try std.testing.expectEqual(@as(u16, 32 + 1140), std.mem.readInt(u16, reliable[44..46], .little));
    try std.testing.expectEqualStrings(&data, (try decodePayload(reliable)).packet.reliable.data);

    // Short messages still declare their exact length.
    const short = try plaintext(&codec, .{ .message = .{ .recipient_id = 2, .data = "Ping" } }, &scratch, &wire);
    try std.testing.expectEqual(@as(u16, @intCast(short.len)), std.mem.readInt(u16, short[0..2], .little));
}

fn reliablePayload(buffer: []u8) []u8 {
    const payload = buffer[0 .. 44 + 32 + 4];
    @memset(payload, 0);
    writeHeader(payload, payload.len, 3, 7, 1);
    writeAddressing(payload, 9, 5, 3);
    _ = writeMessage(payload[44..], 1, 7, .{ .recipient_id = 9, .data = "Ping" });
    return payload;
}

test "invalid reliable packets and acknowledgements are rejected" {
    var buffer: [128]u8 = undefined;
    _ = try decodePayload(reliablePayload(&buffer));

    const Mutation = struct { offset: usize, value: u64, size: enum { u16, u32, u64 } };
    const cases = [_]Mutation{
        .{ .offset = 12, .value = 0, .size = .u64 }, // version 0 reliable
        .{ .offset = 4, .value = 0, .size = .u64 }, // zero sender
        .{ .offset = 20, .value = 0, .size = .u64 }, // zero recipient
        .{ .offset = 28, .value = 0, .size = .u64 }, // zero nonce
        .{ .offset = 36, .value = 0, .size = .u64 }, // zero sequence
        .{ .offset = 44 + 2, .value = 1, .size = .u16 }, // wrapped response
        .{ .offset = 44 + 2, .value = 3, .size = .u16 }, // wrapped reliable
        .{ .offset = 44 + 4, .value = 99, .size = .u64 }, // wrapped sender differs
        .{ .offset = 44 + 12, .value = 0, .size = .u64 }, // wrapped version 0
        .{ .offset = 44 + 12, .value = 2, .size = .u64 }, // wrapped version 2
        .{ .offset = 44 + 20, .value = 10, .size = .u64 }, // wrapped recipient differs
        .{ .offset = 44, .value = 37, .size = .u16 }, // wrapped length past the end
        .{ .offset = 0, .value = 81, .size = .u16 }, // outer length past the end
    };
    for (cases) |case| {
        const payload = reliablePayload(&buffer);
        switch (case.size) {
            .u16 => std.mem.writeInt(u16, payload[case.offset..][0..2], @intCast(case.value), .little),
            .u32 => std.mem.writeInt(u32, payload[case.offset..][0..4], @intCast(case.value), .little),
            .u64 => std.mem.writeInt(u64, payload[case.offset..][0..8], case.value, .little),
        }
        if (decodePayload(payload)) |_| return error.InvalidReliableAccepted else |_| {}
    }

    // A wrapped message too short for its header, and an acknowledgement short of its addressing.
    const payload = reliablePayload(&buffer);
    std.mem.writeInt(u16, payload[0..2], 44 + 31, .little);
    try std.testing.expectError(error.MalformedPacket, decodePayload(payload[0 .. 44 + 31]));
    std.mem.writeInt(u16, payload[0..2], 43, .little);
    std.mem.writeInt(u16, payload[2..4], 4, .little);
    try std.testing.expectError(error.MalformedPacket, decodePayload(payload[0..43]));
}

test "legacy packets decode whatever version they carry" {
    var payload: [32 + 4]u8 = @splat(0);
    for ([_]u64{ 0, 1, 2, std.math.maxInt(u64) }) |version| {
        _ = writeMessage(&payload, version, 7, .{ .recipient_id = 9, .data = "Ping" });
        try std.testing.expectEqualStrings("Ping", (try decodePayload(&payload)).packet.message.data);
    }

    var request: [header_size]u8 = undefined;
    writeHeader(&request, header_size, 0, 7, 2);
    try std.testing.expectEqual(Packet.request, (try decodePayload(&request)).packet);
}

test "declared message length keeps vanilla trailing signal bytes" {
    var payload: [41]u8 = @splat(0);
    std.mem.writeInt(u16, payload[0..2], payload.len, .little);
    std.mem.writeInt(u16, payload[2..4], 2, .little);
    std.mem.writeInt(u64, payload[4..12], 7, .little);
    std.mem.writeInt(u64, payload[20..28], 9, .little);
    std.mem.writeInt(u32, payload[28..32], 4, .little);
    @memcpy(payload[32..], "PingEXTRA");
    const decoded = try decodePayload(&payload);
    try std.testing.expectEqualStrings("PingEXTRA", decoded.packet.message.data);
}

test "a truncated declared length still yields the whole vanilla signal" {
    const signal =
        "CONNECTREQUEST 3671553456937775104 v=0\r\n" ++
        "a=candidate:1 1 udp 2130706431 192.168.0.2 52000 typ host generation 0\r\n";

    var payload: [32 + signal.len]u8 = @splat(0);
    std.mem.writeInt(u16, payload[0..2], payload.len, .little);
    std.mem.writeInt(u16, payload[2..4], 2, .little);
    std.mem.writeInt(u64, payload[4..12], 0x1020304050607080, .little);
    std.mem.writeInt(u64, payload[20..28], 9, .little);
    std.mem.writeInt(u32, payload[28..32], 38, .little);
    @memcpy(payload[32..], signal);

    const decoded = try decodePayload(&payload);
    try std.testing.expectEqualStrings(signal, decoded.packet.message.data);
    try std.testing.expectEqual(@as(u64, 9), decoded.packet.message.recipient_id);

    // Vanilla declares at most 1140 bytes of message data in the outer size too.
    std.mem.writeInt(u16, payload[0..2], 32 + 38, .little);
    try std.testing.expectEqualStrings(signal, (try decodePayload(&payload)).packet.message.data);

    std.mem.writeInt(u16, payload[0..2], payload.len + 1, .little);
    try std.testing.expectError(error.MalformedPacket, decodePayload(&payload));
}

test "responses read their data to the end of the payload" {
    var payload: [24 + 6]u8 = @splat(0);
    std.mem.writeInt(u16, payload[0..2], payload.len, .little);
    std.mem.writeInt(u16, payload[2..4], 1, .little);
    std.mem.writeInt(u32, payload[20..24], 2, .little);
    @memcpy(payload[24..], "0aff10");
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0xff, 0x10 }, (try decodePayload(&payload)).packet.response);

    var odd = payload[0 .. payload.len - 1].*;
    std.mem.writeInt(u16, odd[0..2], odd.len, .little);
    try std.testing.expectError(error.MalformedPacket, decodePayload(&odd));
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

        // Reliable headers with random bodies reach the nested decoder.
        if (length >= 20) {
            std.mem.writeInt(u16, input[0..2], @intCast(@min(length, std.mem.readInt(u16, input[0..2], .little))), .little);
            std.mem.writeInt(u16, input[2..4], 3, .little);
            std.mem.writeInt(u64, input[12..20], 1, .little);
            _ = decodePayload(input[0..length]) catch {};
        }
    }
}
