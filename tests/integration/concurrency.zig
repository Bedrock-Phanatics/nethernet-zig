const std = @import("std");
const nethernet = @import("nethernet");
const Connection = nethernet.Connection;
const build_options = @import("build_options");

const ConcurrentSendTask = struct {
    connection: *Connection,
    sender: u8,
    failure: ?anyerror = null,

    fn run(self: *ConcurrentSendTask) std.Io.Cancelable!void {
        var payload: [4096]u8 = undefined;
        @memset(&payload, self.sender);
        for (0..16) |sequence| {
            payload[1] = @intCast(sequence);
            self.connection.send(&payload, .reliable) catch |err| {
                self.failure = err;
                return;
            };
        }
    }
};

fn concurrentConnectionPair(io: std.Io, index: usize, setup_ms: *i64) !void {
    const started = std.Io.Clock.awake.now(io);
    const allocator = std.testing.allocator;
    const id: u64 = @intCast(index + 1000);

    const options: nethernet.ConnectionOptions = .{
        .native = .{ .disable_trickle = true },
        .allow_anonymous = true,
        .negotiation_timeout_ms = 15000,
        .connection_timeout_ms = 15000,
    };

    const client = try Connection.create(
        allocator,
        io,
        .client,
        id,
        "server",
        options,
    );
    defer client.destroy();

    const server = try Connection.create(
        allocator,
        io,
        .server,
        id,
        "client",
        options,
    );
    defer server.destroy();

    try client.start();

    while (!client.ready() or !server.ready()) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >
            15000)
        {
            return error.Timeout;
        }

        for (
            [_]*Connection{ client, server },
            [_]*Connection{ server, client },
            [_][]const u8{ "client", "server" },
        ) |source, destination, name| {
            if (try source.pollNegotiation()) |event| switch (event) {
                .signal => |signal| {
                    var routed = signal;
                    routed.network_id = name;
                    try destination.applySignal(routed);
                },
                .message => return error.UnexpectedMessage,
            };
        }

        if (!client.ready() or !server.ready())
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }

    setup_ms.* = @intCast(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds());
    const traffic_started = std.Io.Clock.awake.now(io);
    var payload: [128]u8 = undefined;
    for (0..64) |sequence| {
        std.mem.writeInt(u64, payload[0..8], @intCast(sequence), .little);
        for (payload[8..], 8..) |*byte, offset|
            byte.* = @truncate(index + sequence + offset);

        try client.send(&payload, .reliable);
        const received = try receiveDeadline(server, traffic_started);
        try std.testing.expectEqualSlices(u8, &payload, received.data);

        try server.send(received.data, .reliable);
        const echoed = try receiveDeadline(client, traffic_started);
        try std.testing.expectEqualSlices(u8, &payload, echoed.data);
    }

    if (index == 0) {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        var tasks: [4]ConcurrentSendTask = undefined;
        for (&tasks, 0..) |*task, sender| {
            task.* = .{ .connection = client, .sender = @intCast(sender) };
            try group.concurrent(io, ConcurrentSendTask.run, .{task});
        }
        try group.await(io);
        for (tasks) |task| if (task.failure) |failure| return failure;

        var seen: [4][16]bool = std.mem.zeroes([4][16]bool);
        for (0..tasks.len * 16) |_| {
            const message = try receiveDeadline(server, traffic_started);
            try std.testing.expectEqual(@as(usize, 4096), message.data.len);
            const sender: usize = message.data[0];
            const sequence: usize = message.data[1];
            try std.testing.expect(sender < tasks.len and sequence < 16);
            try std.testing.expect(!seen[sender][sequence]);
            seen[sender][sequence] = true;
            for (message.data[2..]) |byte| try std.testing.expectEqual(@as(u8, @intCast(sender)), byte);
        }
        for (seen) |sequences| for (sequences) |received| try std.testing.expect(received);
    }
}

const ConcurrentConnectionTask = struct {
    io: std.Io,
    index: usize,
    gate: *std.Io.Event,
    setup_ms: i64 = 0,
    failure: ?anyerror = null,

    fn run(self: *ConcurrentConnectionTask) std.Io.Cancelable!void {
        try self.gate.wait(self.io);
        concurrentConnectionPair(self.io, self.index, &self.setup_ms) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => self.failure = err,
        };
    }
};

test "multiple native connection pairs exchange traffic concurrently" {
    const io = std.testing.io;
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var gate: std.Io.Event = .unset;
    var tasks: [build_options.handshake_pairs]ConcurrentConnectionTask = undefined;
    for (&tasks, 0..) |*task, index| {
        task.* = .{ .io = io, .index = index, .gate = &gate };
        try group.concurrent(io, ConcurrentConnectionTask.run, .{task});
    }

    gate.set(io);
    try group.await(io);

    for (tasks) |task| {
        if (task.failure) |failure| return failure;
    }
    var latencies: [tasks.len]i64 = undefined;
    for (tasks, &latencies) |task, *latency| latency.* = task.setup_ms;
    std.mem.sort(i64, &latencies, {}, std.sort.asc(i64));
    std.debug.print("handshake pairs={d} setup_ms p50={d} p95={d} p99={d}\n", .{
        tasks.len,
        latencies[(tasks.len - 1) * 50 / 100],
        latencies[(tasks.len - 1) * 95 / 100],
        latencies[(tasks.len - 1) * 99 / 100],
    });
}

pub fn receiveDeadline(connection: *Connection, started: std.Io.Timestamp) !nethernet.Message {
    while (true) {
        if (started.durationTo(std.Io.Clock.awake.now(connection.io)).toMilliseconds() >= 15000)
            return error.Timeout;
        connection.prepareWait();
        if (try connection.poll()) |event| switch (event) {
            .message => |message| return message,
            .signal => return error.UnexpectedSignal,
        };
        if (!connection.peer.hasPending(false)) {
            try connection.peer.wakeup.wait(connection.io, .{ .deadline = .{
                .raw = started.addDuration(.fromMilliseconds(15000)),
                .clock = .awake,
            } });
        }
    }
}

test "concurrent traffic deadline rejects a silent peer" {
    const connection = try Connection.create(std.testing.allocator, std.testing.io, .client, 1, "peer", .{ .allow_anonymous = true });
    defer connection.destroy();
    try std.testing.expectError(error.Timeout, receiveDeadline(
        connection,
        std.Io.Clock.awake.now(std.testing.io).addDuration(.fromMilliseconds(-15000)),
    ));
}
