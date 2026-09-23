const std = @import("std");
const nethernet = @import("nethernet");
const Connection = nethernet.Connection;

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

fn concurrentConnectionPair(io: std.Io, index: usize) !void {
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
    const started = std.Io.Clock.awake.now(io);

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

    var payload: [128]u8 = undefined;
    for (0..64) |sequence| {
        std.mem.writeInt(u64, payload[0..8], @intCast(sequence), .little);
        for (payload[8..], 8..) |*byte, offset|
            byte.* = @truncate(index + sequence + offset);

        try client.send(&payload, .reliable);
        const received = try server.receive();
        try std.testing.expectEqualSlices(u8, &payload, received.data);

        try server.send(received.data, .reliable);
        const echoed = try client.receive();
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
            const message = try server.receive();
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
    failure: ?anyerror = null,

    fn run(self: *ConcurrentConnectionTask) std.Io.Cancelable!void {
        concurrentConnectionPair(self.io, self.index) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => self.failure = err,
        };
    }
};

test "multiple native connection pairs exchange traffic concurrently" {
    const io = std.testing.io;
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var tasks: [8]ConcurrentConnectionTask = undefined;
    for (&tasks, 0..) |*task, index| {
        task.* = .{ .io = io, .index = index };
        try group.concurrent(io, ConcurrentConnectionTask.run, .{task});
    }

    try group.await(io);

    for (tasks) |task| {
        if (task.failure) |failure| return failure;
    }
}
