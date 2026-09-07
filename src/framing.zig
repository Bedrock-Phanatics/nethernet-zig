const std = @import("std");

pub const maximum_segment_payload = 262143;
pub const maximum_segments = 255;
pub const default_maximum_message_size = 16 * 1024 * 1024;
pub const Reliability = enum { reliable, unreliable };

/// Borrows the message until exhausted. Caller owns and reuses the output buffer.
/// Finish sending one iterator before starting another on the same channel.
pub const Encoder = struct {
    data: []const u8,
    offset: usize = 0,

    pub fn init(data: []const u8, reliability: Reliability, limit: usize) !Encoder {
        if (data.len > limit or data.len > maximum_segment_payload * maximum_segments or
            (reliability == .unreliable and data.len > maximum_segment_payload)) return error.MessageTooLarge;
        return .{ .data = data };
    }

    pub fn next(self: *Encoder, output: []u8) error{NoSpaceLeft}!?[]const u8 {
        const left = self.data.len - self.offset;
        if (left == 0) return null; // NOOP: Empty messages emit no frames.
        const count: usize = @min(left, maximum_segment_payload);
        if (output.len < count + 1) return error.NoSpaceLeft;
        output[0] = @intCast((left - 1) / maximum_segment_payload);
        @memcpy(output[1..][0..count], self.data[self.offset..][0..count]);
        self.offset += count;
        return output[0 .. count + 1];
    }
};

/// Single-owner, caller-provided reassembly storage; no heap allocation or locks.
/// Returned messages borrow storage until the next push/reset. Copy or consume
/// before the next push. Feed complete binary WebRTC messages, never raw UDP.
pub const Reassembler = struct {
    storage: []u8,
    reliability: Reliability,
    used: usize = 0,
    remaining: u8 = 0,
    failed: bool = false,

    pub fn init(storage: []u8, reliability: Reliability) Reassembler {
        return .{ .storage = storage, .reliability = reliability };
    }

    pub fn reset(self: *Reassembler) void {
        self.used = 0;
        self.remaining = 0;
        self.failed = false;
    }

    pub fn push(self: *Reassembler, fragment: []const u8) !?[]const u8 {
        if (self.failed) return error.ConnectionClosed;
        errdefer self.failed = true;
        if (fragment.len < 2) return error.MalformedFragment;
        const remaining = fragment[0];
        if (self.reliability == .unreliable and remaining != 0) return error.MalformedFragment;
        if (self.remaining > 0 and self.remaining - 1 != remaining) return error.FragmentOutOfSequence;
        const payload = fragment[1..];
        if (payload.len > self.storage.len - self.used) return error.MessageTooLarge;
        @memcpy(self.storage[self.used..][0..payload.len], payload);
        self.used += payload.len;
        self.remaining = remaining;
        if (remaining != 0) return null;
        const result = self.storage[0..self.used];
        self.used = 0;
        return result;
    }
};

test "empty sends no frames; output exhaustion leaves iterator unchanged" {
    var empty = try Encoder.init("", .reliable, 10);
    var tiny: [1]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), try empty.next(&tiny));
    var encoder = try Encoder.init("a", .reliable, 1);
    try std.testing.expectError(error.NoSpaceLeft, encoder.next(&tiny));
    try std.testing.expectEqual(@as(usize, 0), encoder.offset);
}

test "fragment boundaries and reassembly" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, maximum_segment_payload * 2 + 1);
    defer allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i);
    const storage = try allocator.alloc(u8, data.len);
    defer allocator.free(storage);
    const frame = try allocator.alloc(u8, maximum_segment_payload + 1);
    defer allocator.free(frame);
    for ([_]usize{ 1, 32, maximum_segment_payload - 1, maximum_segment_payload, maximum_segment_payload + 1, data.len }) |size| {
        var encoder = try Encoder.init(data[0..size], .reliable, data.len);
        var decoder = Reassembler.init(storage, .reliable);
        var messages: usize = 0;
        while (try encoder.next(frame)) |part| {
            if (try decoder.push(part)) |message| {
                messages += 1;
                try std.testing.expectEqualSlices(u8, data[0..size], message);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), messages);
    }
    try std.testing.expectError(error.MessageTooLarge, Encoder.init(data, .unreliable, data.len));
}

test "malformed, reordered, duplicate, oversized and unreliable fragments fail closed" {
    var storage: [8]u8 = undefined;
    var decoder = Reassembler.init(&storage, .reliable);
    try std.testing.expectError(error.MalformedFragment, decoder.push(&.{0}));
    try std.testing.expectError(error.ConnectionClosed, decoder.push(&.{ 0, 1 }));
    decoder.reset();
    try std.testing.expectEqual(@as(?[]const u8, null), try decoder.push(&.{ 2, 1 }));
    try std.testing.expectError(error.FragmentOutOfSequence, decoder.push(&.{ 2, 1 }));
    decoder.reset();
    _ = try decoder.push(&.{ 2, 1 });
    try std.testing.expectError(error.FragmentOutOfSequence, decoder.push(&.{ 0, 1 }));
    decoder.reset();
    try std.testing.expectError(error.MessageTooLarge, decoder.push(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }));
    decoder = Reassembler.init(&storage, .unreliable);
    try std.testing.expectError(error.MalformedFragment, decoder.push(&.{ 1, 2 }));
}
