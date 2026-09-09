const std = @import("std");

pub const maximum_segment_payload: usize = 262143;
pub const maximum_segments: usize = 255;
pub const maximum_reliable_message_size: usize = maximum_segment_payload * maximum_segments;
pub const default_maximum_message_size = 16 * 1024 * 1024;

pub const Reliability = enum {
    reliable,
    unreliable,
};

pub fn validateFragmentSize(size: usize) !void {
    if (size < 2) return error.MalformedFragment;
    if (size - 1 > maximum_segment_payload) return error.MessageTooLarge;
}

/// Returns a borrowed payload only when the frame is a complete message.
pub fn singleFragmentPayload(fragment: []const u8, reliability: Reliability) !?[]const u8 {
    try validateFragmentSize(fragment.len);
    if (fragment[0] != 0) {
        if (reliability == .unreliable) return error.MalformedFragment;
        return null;
    }
    return fragment[1..];
}

pub fn validateMessageSize(size: usize, reliability: Reliability, limit: usize) !void {
    if (size > limit or
        size > maximum_reliable_message_size or
        (reliability == .unreliable and size > maximum_segment_payload))
    {
        return error.MessageTooLarge;
    }
}

/// The message stays borrowed while the caller reuses the output buffer.
pub const Encoder = struct {
    data: []const u8,
    offset: usize = 0,

    pub fn init(
        data: []const u8,
        reliability: Reliability,
        limit: usize,
    ) !Encoder {
        try validateMessageSize(data.len, reliability, limit);
        return .{ .data = data };
    }

    pub fn next(
        self: *Encoder,
        output: []u8,
    ) error{NoSpaceLeft}!?[]const u8 {
        const remaining = self.data.len - self.offset;
        if (remaining == 0) return null;

        const payload_len: usize = @min(remaining, maximum_segment_payload);
        if (output.len < payload_len + 1) return error.NoSpaceLeft;

        output[0] = @intCast((remaining - 1) / maximum_segment_payload);

        @memcpy(
            output[1..][0..payload_len],
            self.data[self.offset..][0..payload_len],
        );

        self.offset += payload_len;
        return output[0 .. payload_len + 1];
    }
};

/// Reassembles WebRTC messages in storage provided by the caller.
/// Results remain valid until the next push or reset.
pub const Reassembler = struct {
    storage: []u8,
    reliability: Reliability,
    used: usize = 0,
    remaining: u8 = 0,
    failed: bool = false,

    pub fn init(storage: []u8, reliability: Reliability) Reassembler {
        return .{
            .storage = storage,
            .reliability = reliability,
        };
    }

    pub fn reset(self: *Reassembler) void {
        self.used = 0;
        self.remaining = 0;
        self.failed = false;
    }

    pub fn push(self: *Reassembler, fragment: []const u8) !?[]const u8 {
        if (self.failed) return error.ConnectionClosed;
        errdefer self.failed = true;

        try validateFragmentSize(fragment.len);

        const remaining = fragment[0];

        if (self.reliability == .unreliable and remaining != 0) {
            return error.MalformedFragment;
        }

        if (self.reliability == .reliable and self.used == 0 and
            remaining >= maximum_segments)
        {
            return error.MalformedFragment;
        }

        if (self.remaining > 0 and self.remaining - 1 != remaining) {
            return error.FragmentOutOfSequence;
        }

        const payload = fragment[1..];

        if (payload.len > self.storage.len - self.used) {
            return error.MessageTooLarge;
        }

        @memcpy(self.storage[self.used..][0..payload.len], payload);

        self.used += payload.len;
        self.remaining = remaining;

        if (remaining != 0) return null;

        const message = self.storage[0..self.used];
        self.used = 0;

        return message;
    }
};

test "inbound fragment payload boundaries match the encoder" {
    try validateFragmentSize(maximum_segment_payload + 1);
    try std.testing.expectError(error.MessageTooLarge, validateFragmentSize(maximum_segment_payload + 2));
    try std.testing.expectError(error.MalformedFragment, validateFragmentSize(1));
}

test "empty sends no frames; output exhaustion leaves iterator unchanged" {
    var empty = try Encoder.init("", .reliable, 10);
    var tiny: [1]u8 = undefined;

    try std.testing.expectEqual(
        @as(?[]const u8, null),
        try empty.next(&tiny),
    );

    var encoder = try Encoder.init("a", .reliable, 1);

    try std.testing.expectError(
        error.NoSpaceLeft,
        encoder.next(&tiny),
    );
    try std.testing.expectEqual(@as(usize, 0), encoder.offset);
}

test "fragment boundaries and reassembly" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(
        u8,
        maximum_segment_payload * 2 + 1,
    );
    defer allocator.free(data);

    for (data, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }

    const storage = try allocator.alloc(u8, data.len);
    defer allocator.free(storage);

    const frame = try allocator.alloc(u8, maximum_segment_payload + 1);
    defer allocator.free(frame);

    const sizes = [_]usize{
        1,
        32,
        maximum_segment_payload - 1,
        maximum_segment_payload,
        maximum_segment_payload + 1,
        data.len,
    };

    for (sizes) |size| {
        var encoder = try Encoder.init(
            data[0..size],
            .reliable,
            data.len,
        );
        var reassembler = Reassembler.init(storage, .reliable);
        var messages: usize = 0;

        while (try encoder.next(frame)) |fragment| {
            if (try reassembler.push(fragment)) |message| {
                messages += 1;

                try std.testing.expectEqualSlices(
                    u8,
                    data[0..size],
                    message,
                );
            }
        }

        try std.testing.expectEqual(@as(usize, 1), messages);
    }

    try std.testing.expectError(
        error.MessageTooLarge,
        Encoder.init(data, .unreliable, data.len),
    );
}

test "malformed, reordered, duplicate, oversized and unreliable fragments fail closed" {
    var storage: [8]u8 = undefined;
    var reassembler = Reassembler.init(&storage, .reliable);

    try std.testing.expectError(
        error.MalformedFragment,
        reassembler.push(&.{0}),
    );
    try std.testing.expectError(
        error.ConnectionClosed,
        reassembler.push(&.{ 0, 1 }),
    );

    reassembler.reset();

    try std.testing.expectEqual(
        @as(?[]const u8, null),
        try reassembler.push(&.{ 2, 1 }),
    );
    try std.testing.expectError(
        error.FragmentOutOfSequence,
        reassembler.push(&.{ 2, 1 }),
    );

    reassembler.reset();
    _ = try reassembler.push(&.{ 2, 1 });

    try std.testing.expectError(
        error.FragmentOutOfSequence,
        reassembler.push(&.{ 0, 1 }),
    );

    reassembler.reset();

    try std.testing.expectError(
        error.MessageTooLarge,
        reassembler.push(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }),
    );

    reassembler = Reassembler.init(&storage, .unreliable);

    try std.testing.expectError(
        error.MalformedFragment,
        reassembler.push(&.{ 1, 2 }),
    );
}

test "reassembler rejects a 256-fragment countdown" {
    var storage: [256]u8 = undefined;
    var reassembler = Reassembler.init(&storage, .reliable);
    try std.testing.expectError(error.MalformedFragment, reassembler.push(&.{ 255, 1 }));
    try std.testing.expectError(error.ConnectionClosed, reassembler.push(&.{ 254, 1 }));

    reassembler.reset();
    var remaining: usize = maximum_segments - 1;
    while (true) {
        const result = try reassembler.push(&.{ @intCast(remaining), 1 });
        if (remaining == 0) {
            try std.testing.expectEqual(@as(usize, maximum_segments), result.?.len);
            break;
        }
        try std.testing.expect(result == null);
        remaining -= 1;
    }
}

test "reliable message-size boundaries match 255 segment representation" {
    try validateMessageSize(maximum_reliable_message_size, .reliable, maximum_reliable_message_size);
    try std.testing.expectError(
        error.MessageTooLarge,
        validateMessageSize(maximum_reliable_message_size + 1, .reliable, maximum_reliable_message_size + 1),
    );

    const exact_segments = (maximum_reliable_message_size + maximum_segment_payload - 1) / maximum_segment_payload;
    const overflow_segments = (maximum_reliable_message_size + 1 + maximum_segment_payload - 1) / maximum_segment_payload;
    try std.testing.expectEqual(@as(usize, maximum_segments), exact_segments);
    try std.testing.expectEqual(@as(usize, maximum_segments + 1), overflow_segments);
}
