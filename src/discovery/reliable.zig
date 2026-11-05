const std = @import("std");

/// How many recent sequences each sender and nonce remembers.
pub const window_size = 256;
/// Like vanilla's peer addresses, a window is forgotten a minute after its last packet.
pub const window_lifetime_ms = 60_000;
/// Anyone on the LAN can forge packets with the well-known key, so windows live in a fixed table, and a flood
/// of new senders evicts the least recently active one rather than locking new peers out.
pub const maximum_windows = 64;

pub const Outcome = enum { deliver, duplicate, stale };

/// Tracks which reliable LAN messages were delivered, so each is delivered once within its window.
pub const Windows = struct {
    slots: [maximum_windows]Window = @splat(.{}),
    evictions: u64 = 0,

    const Window = struct {
        /// Zero marks a free slot, since a reliable sender is never zero.
        sender_id: u64 = 0,
        nonce: u64 = 0,
        highest: u64 = 0,
        /// Bit i records that `highest - i` arrived.
        received: u256 = 0,
        active: std.Io.Timestamp = .zero,
    };

    pub fn receive(self: *Windows, sender_id: u64, nonce: u64, sequence: u64, now: std.Io.Timestamp) Outcome {
        std.debug.assert(sender_id != 0 and sequence != 0);
        const window = self.find(sender_id, nonce) orelse self.claim(sender_id, nonce);
        window.active = now;

        if (sequence > window.highest) {
            const shift = sequence - window.highest;
            window.received = if (shift >= window_size) 1 else (window.received << @intCast(shift)) | 1;
            window.highest = sequence;
            return .deliver;
        }

        const age = window.highest - sequence;
        if (age >= window_size) return .stale;
        const bit = @as(u256, 1) << @intCast(age);
        if (window.received & bit != 0) return .duplicate;
        window.received |= bit;
        return .deliver;
    }

    pub fn expire(self: *Windows, now: std.Io.Timestamp) void {
        for (&self.slots) |*slot| {
            if (slot.sender_id != 0 and slot.active.durationTo(now).toMilliseconds() >= window_lifetime_ms)
                slot.* = .{};
        }
    }

    fn find(self: *Windows, sender_id: u64, nonce: u64) ?*Window {
        for (&self.slots) |*slot| {
            if (slot.sender_id == sender_id and slot.nonce == nonce) return slot;
        }
        return null;
    }

    fn claim(self: *Windows, sender_id: u64, nonce: u64) *Window {
        var oldest = &self.slots[0];
        for (&self.slots) |*slot| {
            if (slot.sender_id == 0) {
                oldest = slot;
                break;
            }
            if (slot.active.nanoseconds < oldest.active.nanoseconds) oldest = slot;
        } else self.evictions +|= 1;
        oldest.* = .{ .sender_id = sender_id, .nonce = nonce };
        return oldest;
    }
};

fn at(ms: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
}

test "reliable sequences are delivered once in any order" {
    var windows: Windows = .{};
    const now = at(1);

    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, 3, now));
    try std.testing.expectEqual(Outcome.duplicate, windows.receive(7, 5, 3, now));
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, 1, now));
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, 2, now));
    try std.testing.expectEqual(Outcome.duplicate, windows.receive(7, 5, 1, now));
    try std.testing.expectEqual(Outcome.duplicate, windows.receive(7, 5, 2, now));

    // Other nonces and senders keep their own windows.
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 6, 3, now));
    try std.testing.expectEqual(Outcome.deliver, windows.receive(8, 5, 3, now));
}

test "sequences older than the window are stale and the window slides" {
    var windows: Windows = .{};
    const now = at(1);

    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, 1, now));
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, window_size, now));
    try std.testing.expectEqual(Outcome.duplicate, windows.receive(7, 5, 1, now));
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, window_size + 1, now));
    try std.testing.expectEqual(Outcome.stale, windows.receive(7, 5, 1, now));
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, 2, now));
    try std.testing.expectEqual(Outcome.duplicate, windows.receive(7, 5, window_size, now));

    // A jump past the whole window forgets everything before it.
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, std.math.maxInt(u64), now));
    try std.testing.expectEqual(Outcome.stale, windows.receive(7, 5, window_size + 1, now));
    try std.testing.expectEqual(Outcome.duplicate, windows.receive(7, 5, std.math.maxInt(u64), now));
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, std.math.maxInt(u64) - window_size + 1, now));
}

test "windows expire after a minute without packets" {
    var windows: Windows = .{};
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, 1, at(1)));
    windows.expire(at(window_lifetime_ms));
    try std.testing.expectEqual(Outcome.duplicate, windows.receive(7, 5, 1, at(window_lifetime_ms)));
    windows.expire(at(2 * window_lifetime_ms));
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, 1, at(2 * window_lifetime_ms)));
}

test "a flood of forged senders stays bounded and evicts the least recently active" {
    var windows: Windows = .{};
    for (1..maximum_windows) |i| _ = windows.receive(1000 + i, 1, 1, at(@intCast(i)));
    try std.testing.expectEqual(Outcome.deliver, windows.receive(7, 5, 1, at(1000)));
    try std.testing.expectEqual(@as(u64, 0), windows.evictions);

    for (0..10_000) |i| _ = windows.receive(1_000_000 + i, 1, 1, at(@intCast(i % (maximum_windows - 2))));
    try std.testing.expectEqual(@as(u64, 10_000), windows.evictions);
    try std.testing.expectEqual(Outcome.duplicate, windows.receive(7, 5, 1, at(1001)));
}
