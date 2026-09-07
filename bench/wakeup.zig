const std = @import("std");
const wake = @import("wakeup");
const Queue = @import("queue").Queue;
const samples = 500;

// Compare against the old polling loop.
const Mode = enum { polling_1ms, event_driven };
const Harness = struct {
    mutex: std.Io.Mutex = .init,
    wakeup: wake.Wakeup = .{},
    acknowledged: std.Io.Event = .unset,
    queue: Queue,
    sent: std.Io.Timestamp = .{ .nanoseconds = 0 },

    fn produce(self: *Harness, io: std.Io) !void {
        for (0..samples) |i| {
            self.acknowledged.reset();
            // Vary packet timing so it does not line up with polling.
            try std.Io.sleep(io, .fromNanoseconds(100_000 + (i * 7919) % 1_700_000), .awake);
            self.mutex.lockUncancelable(io);
            self.sent = std.Io.Clock.awake.now(io);
            try self.queue.push(0, "packet");
            self.wakeup.signal(io);
            self.mutex.unlock(io);
            try self.acknowledged.wait(io);
        }
    }
};

fn run(io: std.Io, mode: Mode) !void {
    var bytes: [64]u8 = undefined;
    var entries: [8]Queue.Entry = undefined;
    var output: [64]u8 = undefined;
    var harness = Harness{ .queue = try Queue.init(&bytes, &entries) };
    var latency: [samples]i64 = undefined;
    var producer = try io.concurrent(Harness.produce, .{ &harness, io });
    defer producer.cancel(io) catch {};
    for (&latency) |*sample| {
        while (true) {
            harness.wakeup.prepare();
            harness.mutex.lockUncancelable(io);
            const packet = try harness.queue.pop(&output);
            const sent = harness.sent;
            harness.mutex.unlock(io);
            if (packet != null) {
                sample.* = @intCast(sent.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
                harness.acknowledged.set(io);
                break;
            }
            switch (mode) {
                .polling_1ms => try std.Io.sleep(io, .fromMilliseconds(1), .awake),
                .event_driven => try harness.wakeup.wait(io, .none),
            }
        }
    }
    try producer.await(io);
    std.mem.sort(i64, &latency, {}, std.sort.asc(i64));
    const start = std.Io.Clock.awake.now(io);
    const cpu = std.Io.Clock.cpu_process.now(io);
    const limit = wake.deadline(start, 1000);
    var idle_waits: usize = 0;
    while (std.Io.Clock.awake.now(io).nanoseconds < limit.deadline.raw.nanoseconds) {
        harness.wakeup.prepare();
        switch (mode) {
            .polling_1ms => try std.Io.sleep(io, .fromMilliseconds(1), .awake),
            .event_driven => try harness.wakeup.wait(io, limit),
        }
        idle_waits += 1;
    }
    const cpu_ns = cpu.durationTo(std.Io.Clock.cpu_process.now(io)).toNanoseconds();
    std.debug.print("{s},{d},{d},{d},{d},{d}\n", .{
        @tagName(mode),              latency[samples / 2], latency[samples * 95 / 100],
        latency[samples * 99 / 100], idle_waits,           cpu_ns,
    });
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("mode,p50_ns,p95_ns,p99_ns,idle_waits_1s,idle_process_cpu_ns\n", .{});
    try run(init.io, .polling_1ms);
    try run(init.io, .event_driven);
}
