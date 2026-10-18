const std = @import("std");

/// Any number of threads may wait. A wait returns once a signal lands after its prepare.
pub const Wakeup = struct {
    sequence: std.atomic.Value(u32) = .init(0),
    waiters: std.atomic.Value(u32) = .init(0),

    pub const Token = u32;

    pub fn prepare(self: *const Wakeup) Token {
        return self.sequence.load(.seq_cst);
    }

    pub fn signaled(self: *const Wakeup, token: Token) bool {
        return self.sequence.load(.acquire) != token;
    }

    pub fn signal(self: *Wakeup, io: std.Io) void {
        _ = self.sequence.fetchAdd(1, .seq_cst);
        if (self.waiters.load(.seq_cst) != 0) io.futexWake(u32, &self.sequence.raw, std.math.maxInt(u32));
    }

    pub fn wait(self: *Wakeup, io: std.Io, token: Token, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        try io.checkCancel();
        _ = self.waiters.fetchAdd(1, .seq_cst);
        defer _ = self.waiters.fetchSub(1, .seq_cst);
        try io.futexWaitTimeout(u32, &self.sequence.raw, token, timeout);
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
    const token = wakeup.prepare();
    for (0..1000) |_| wakeup.signal(std.testing.io);
    try wakeup.wait(std.testing.io, token, .none);
    try std.testing.expect(!wakeup.signaled(wakeup.prepare()));
}

test "wakeups still work after cancellation or timeout" {
    const io = std.testing.io;
    var wakeup: Wakeup = .{};
    var task = try io.concurrent(Wakeup.wait, .{ &wakeup, io, wakeup.prepare(), std.Io.Timeout.none });
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expectEqual(@as(u32, 0), wakeup.waiters.load(.acquire));
    const token = wakeup.prepare();
    try wakeup.wait(io, token, deadline(std.Io.Clock.awake.now(io), 0));
    wakeup.signal(io);
    try wakeup.wait(io, token, .none);
}

test "concurrent waiters each observe a signal" {
    const io = std.testing.io;
    var wakeup: Wakeup = .{};
    const token = wakeup.prepare();
    var first = try io.concurrent(Wakeup.wait, .{ &wakeup, io, token, std.Io.Timeout.none });
    defer first.cancel(io) catch {};
    var second = try io.concurrent(Wakeup.wait, .{ &wakeup, io, token, std.Io.Timeout.none });
    defer second.cancel(io) catch {};
    while (wakeup.waiters.load(.acquire) != 2) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    _ = wakeup.prepare();
    wakeup.signal(io);
    try first.await(io);
    try second.await(io);
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
    const limit = deadline(std.Io.Clock.awake.now(io), 120_000);
    for (1..1001) |i| {
        while (true) {
            const token = harness.wakeup.prepare();
            if (harness.value.load(.acquire) == i) break;
            if (std.Io.Clock.awake.now(io).nanoseconds >= limit.deadline.raw.nanoseconds)
                return error.Timeout;
            try harness.wakeup.wait(io, token, limit);
        }
        harness.acknowledged.set(io);
    }
    try producer.await(io);
}

test "a waiter can time out after another thread prepares" {
    const io = std.testing.io;
    var wakeup: Wakeup = .{};
    var waiting = try io.concurrent(Wakeup.wait, .{ &wakeup, io, wakeup.prepare(), deadline(std.Io.Clock.awake.now(io), 50) });
    defer waiting.cancel(io) catch {};
    while (wakeup.waiters.load(.acquire) != 1) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    _ = wakeup.prepare();
    try waiting.await(io);
}
