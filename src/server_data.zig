const std = @import("std");

const Error = error{
    MalformedPacket,
    NoSpaceLeft,
    MessageTooLarge,
};

const Reader = struct {
    data: []const u8,
    offset: usize = 0,

    fn take(self: *Reader, len: usize) Error![]const u8 {
        if (len > self.data.len - self.offset) {
            return error.MalformedPacket;
        }

        const result = self.data[self.offset..][0..len];
        self.offset += len;
        return result;
    }

    fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }
    fn boolean(self: *Reader) Error!bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.MalformedPacket,
        };
    }

    fn uint(self: *Reader) Error!u32 {
        var value: u32 = 0;

        for (0..5) |i| {
            const b = try self.byte();

            if (i == 4 and b > 15) {
                return error.MalformedPacket;
            }

            value |= @as(u32, b & 127) << @as(u5, @intCast(i * 7));

            if (b < 128) return value;
        }

        return error.MalformedPacket;
    }

    fn int(self: *Reader) Error!i32 {
        const value = try self.uint();
        return @as(i32, @intCast(value >> 1)) ^
            -@as(i32, @intCast(value & 1));
    }

    fn string(self: *Reader) Error![]const u8 {
        return self.take(try self.uint());
    }

    fn fixed(self: *Reader) Error!i32 {
        return std.mem.readInt(
            i32,
            (try self.take(4))[0..4],
            .little,
        );
    }
};

const Writer = struct {
    data: []u8,
    offset: usize = 0,

    fn put(self: *Writer, data: []const u8) Error!void {
        if (data.len > self.data.len - self.offset) {
            return error.NoSpaceLeft;
        }

        @memcpy(self.data[self.offset..][0..data.len], data);
        self.offset += data.len;
    }

    fn byte(self: *Writer, value: u8) Error!void {
        try self.put(&.{value});
    }

    fn uint(self: *Writer, value: u32) Error!void {
        var remaining = value;

        while (remaining >= 128) : (remaining >>= 7) {
            try self.byte(@as(u8, @truncate(remaining)) | 128);
        }

        try self.byte(@intCast(remaining));
    }

    fn int(self: *Writer, value: i32) Error!void {
        try self.uint(@bitCast((value << 1) ^ (value >> 31)));
    }

    fn string(self: *Writer, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(u32)) {
            return error.MessageTooLarge;
        }

        try self.uint(@intCast(value.len));
        try self.put(value);
    }

    fn fixed(self: *Writer, value: i32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, value, .little);
        try self.put(&bytes);
    }
};

/// Decoded strings use the input buffer. Signed values preserve unknown variants.
pub const ServerData = struct {
    server_name: []const u8 = "",
    level_name: []const u8 = "",
    game_type: i32 = 0,
    player_count: i32 = 0,
    max_player_count: i32 = 0,
    editor_world: bool = false,
    hardcore: bool = false,
    accepts_online_auth: bool = false,
    accepts_self_signed_auth: bool = false,
    nonce: []const u8 = "",
    transport_layer: i32 = 2,
    connection_type: i32 = 4,

    pub fn encode(self: ServerData, output: []u8) Error![]const u8 {
        var writer = Writer{ .data = output };

        try writer.byte(6);
        try writer.string(self.server_name);
        try writer.string(self.level_name);
        try writer.int(self.game_type);
        try writer.fixed(self.player_count);
        try writer.fixed(self.max_player_count);

        inline for (.{
            self.editor_world,
            self.hardcore,
            self.accepts_online_auth,
            self.accepts_self_signed_auth,
        }) |value| {
            try writer.byte(@intFromBool(value));
        }

        try writer.string(self.nonce);
        try writer.int(self.transport_layer);
        try writer.int(self.connection_type);

        return output[0..writer.offset];
    }

    pub fn decode(input: []const u8) Error!ServerData {
        var reader = Reader{ .data = input };

        if (try reader.byte() != 6) {
            return error.MalformedPacket;
        }

        const result: ServerData = .{
            .server_name = try reader.string(),
            .level_name = try reader.string(),
            .game_type = try reader.int(),
            .player_count = try reader.fixed(),
            .max_player_count = try reader.fixed(),
            .editor_world = try reader.boolean(),
            .hardcore = try reader.boolean(),
            .accepts_online_auth = try reader.boolean(),
            .accepts_self_signed_auth = try reader.boolean(),
            .nonce = try reader.string(),
            .transport_layer = try reader.int(),
            .connection_type = try reader.int(),
        };

        if (reader.offset != input.len) {
            return error.MalformedPacket;
        }

        return result;
    }

    /// String fields remain tied to the RakNet pong input.
    pub fn fromPong(pong: []const u8) Error!ServerData {
        var fields = std.mem.splitScalar(u8, pong, ';');
        var parts: [9][]const u8 = undefined;

        for (&parts) |*part| {
            part.* = fields.next() orelse return error.MalformedPacket;
        }

        const game_type = std.mem.trim(u8, parts[8], " \r\n\t");

        return .{
            .server_name = parts[1],
            .level_name = parts[7],
            .player_count = std.fmt.parseInt(
                i32,
                std.mem.trim(u8, parts[4], " \t"),
                10,
            ) catch return error.MalformedPacket,
            .max_player_count = std.fmt.parseInt(
                i32,
                std.mem.trim(u8, parts[5], " \t"),
                10,
            ) catch return error.MalformedPacket,
            .game_type = if (std.ascii.eqlIgnoreCase(game_type, "CREATIVE"))
                1
            else if (std.ascii.eqlIgnoreCase(game_type, "ADVENTURE"))
                2
            else
                0,
            .accepts_online_auth = true,
            .accepts_self_signed_auth = true,
        };
    }
};

test "version six advertisement matches wire fixture" {
    const expected = [_]u8{
        6,
        6,
        's',
        'e',
        'r',
        'v',
        'e',
        'r',
        5,
        'w',
        'o',
        'r',
        'l',
        'd',
        4,
        1,
        0,
        0,
        0,
        8,
        0,
        0,
        0,
        0,
        1,
        1,
        1,
        5,
        'n',
        'o',
        'n',
        'c',
        'e',
        4,
        8,
    };

    const value = ServerData{
        .server_name = "server",
        .level_name = "world",
        .game_type = 2,
        .player_count = 1,
        .max_player_count = 8,
        .hardcore = true,
        .accepts_online_auth = true,
        .accepts_self_signed_auth = true,
        .nonce = "nonce",
    };

    var buffer: [128]u8 = undefined;

    try std.testing.expectEqualSlices(
        u8,
        &expected,
        try value.encode(&buffer),
    );

    const decoded = try ServerData.decode(&expected);

    try std.testing.expectEqualStrings(
        value.server_name,
        decoded.server_name,
    );

    for (0..expected.len) |length| {
        try std.testing.expectError(
            error.MalformedPacket,
            ServerData.decode(expected[0..length]),
        );
    }

    try std.testing.expectError(
        error.MalformedPacket,
        ServerData.decode(&.{ 6, 255, 255, 255, 255, 127 }),
    );
}

test "advertisements reject noncanonical booleans and malformed pong counts" {
    var encoded: [64]u8 = undefined;
    const wire = try (ServerData{}).encode(&encoded);
    var malformed: [64]u8 = undefined;
    @memcpy(malformed[0..wire.len], wire);
    malformed[14] = 2;
    try std.testing.expectError(error.MalformedPacket, ServerData.decode(malformed[0..wire.len]));

    for ([_][]const u8{
        "MCPE;server;1;2;;4;5;world;CREATIVE",
        "MCPE;server;1;2;bad;4;5;world;CREATIVE",
        "MCPE;server;1;2;3;999999999999;5;world;CREATIVE",
    }) |pong| try std.testing.expectError(error.MalformedPacket, ServerData.fromPong(pong));
}

test "signed varint boundaries and pong conversion" {
    var buffer: [128]u8 = undefined;

    for ([_]i32{
        std.math.minInt(i32),
        -1,
        0,
        1,
        std.math.maxInt(i32),
    }) |value| {
        const data = ServerData{
            .game_type = value,
            .connection_type = value,
        };

        const decoded = try ServerData.decode(
            try data.encode(&buffer),
        );

        try std.testing.expectEqual(value, decoded.game_type);
        try std.testing.expectEqual(value, decoded.connection_type);
    }

    const pong = try ServerData.fromPong(
        "MCPE;server;1;2;3;4;5;world; Creative ",
    );

    try std.testing.expectEqual(@as(i32, 1), pong.game_type);
    try std.testing.expectEqual(@as(i32, 3), pong.player_count);
}
