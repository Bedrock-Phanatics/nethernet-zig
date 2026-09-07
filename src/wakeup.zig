const std = @import("std");

/// One waiter, many senders. Prepare, check for work, then wait.
/// Signal after publishing work. Never prepare during a wait.
/// Keep wakeups alive until all senders and waiters finish.
pub const Wakeup = struct {
    event: std.Io.Event = .unset,

    pub fn prepare(self: *Wakeup) void {
        self.event.reset();
    }

    pub fn signal(self: *Wakeup, io: std.Io) void {
        self.event.set(io);
    }

    /// Recheck state and deadlines after waking.
    pub fn wait(self: *Wakeup, io: std.Io, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        try io.checkCancel();
        self.event.waitTimeout(io, timeout) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
};

pub fn deadline(start: std.Io.Timestamp, milliseconds: u32) std.Io.Timeout {
    return .{ .deadline = .{
        .raw = start.addDuration(.fromMilliseconds(milliseconds)),
        .clock = .awake,
    } };
}

pub fn earliest(a: std.Io.Timeout, b: std.Io.Timeout) std.Io.Timeout {
    if (a == .none) return b;
    if (b == .none) return a;
    return if (a.deadline.raw.nanoseconds < b.deadline.raw.nanoseconds) a else b;
}

test "signals before waiting are remembered" {
    var wakeup: Wakeup = .{};
    wakeup.prepare();
    for (0..1000) |_| wakeup.signal(std.testing.io);
    try wakeup.wait(std.testing.io, .none);
    wakeup.prepare();
    try std.testing.expect(!wakeup.event.isSet());
}

test "wakeups still work after cancellation or timeout" {
    const io = std.testing.io;
    var wakeup: Wakeup = .{};
    var task = try io.concurrent(Wakeup.wait, .{ &wakeup, io, std.Io.Timeout.none });
    try std.testing.expectError(error.Canceled, task.cancel(io));
    wakeup.prepare();
    try wakeup.wait(io, deadline(std.Io.Clock.awake.now(io), 0));
    wakeup.signal(io);
    try wakeup.wait(io, .none);
}

test "concurrent signals are not lost" {
    const Harness = struct {
        wakeup: Wakeup = .{},
        acknowledged: std.Io.Event = .unset,
        value: std.atomic.Value(u32) = .init(0),
        fn produce(self: *@This(), io: std.Io) !void {
            for (1..1001) |i| {
                self.acknowledged.reset();
                self.value.store(@intCast(i), .release);
                self.wakeup.signal(io);
                try self.acknowledged.wait(io);
            }
        }
    };
    const io = std.testing.io;
    var harness: Harness = .{};
    var producer = try io.concurrent(Harness.produce, .{ &harness, io });
    defer producer.cancel(io) catch {};
    const limit = deadline(std.Io.Clock.awake.now(io), 5000);
    for (1..1001) |i| {
        while (true) {
            harness.wakeup.prepare();
            if (harness.value.load(.acquire) == i) break;
            if (std.Io.Clock.awake.now(io).nanoseconds >= limit.deadline.raw.nanoseconds)
                return error.Timeout;
            try harness.wakeup.wait(io, limit);
        }
        harness.acknowledged.set(io);
    }
    try producer.await(io);
}
