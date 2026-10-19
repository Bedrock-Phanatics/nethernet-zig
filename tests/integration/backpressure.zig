const std = @import("std");
const nethernet = @import("nethernet");
const Connection = nethernet.Connection;
const receiveDeadline = @import("concurrency.zig").receiveDeadline;

const message_size = 1200;
const message_count = 3000;

fn connect(io: std.Io, client: *Connection, server: *Connection) !void {
    try client.start();
    const started = std.Io.Clock.awake.now(io);
    while (!client.ready() or !server.ready()) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 15_000) return error.Timeout;
        for ([_]*Connection{ client, server }, [_]*Connection{ server, client }, [_][]const u8{ "client", "server" }) |source, destination, name| {
            if (try source.pollNegotiation()) |event| switch (event) {
                .signal => |signal| {
                    var routed = signal;
                    routed.network_id = name;
                    try destination.applySignal(routed);
                },
                .message => return error.UnexpectedMessage,
            };
        }
        if (!client.peer.hasPending(true) and !server.peer.hasPending(true))
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}

fn createPair(io: std.Io, id: u64) ![2]*Connection {
    const allocator = std.testing.allocator;
    const client = try Connection.create(allocator, io, .client, id, "server", .{
        .native = .{ .disable_trickle = true, .maximum_buffered_send = 256 * 1024 },
    });
    errdefer client.destroy();
    const server = try Connection.create(allocator, io, .server, id, "client", .{
        .native = .{ .disable_trickle = true, .queue_entries = 64, .queue_bytes = 512 * 1024 },
        .allow_anonymous = true,
    });
    errdefer server.destroy();
    try connect(io, client, server);
    return .{ client, server };
}

const Sender = struct {
    connection: *Connection,
    backpressured: u64 = 0,

    fn run(self: *Sender) !void {
        var payload: [message_size]u8 = undefined;
        for (0..message_count) |sequence| {
            std.mem.writeInt(u32, payload[0..4], @intCast(sequence), .little);
            @memset(payload[4..], @truncate(sequence));
            while (true) {
                self.connection.send(&payload, .reliable) catch |err| switch (err) {
                    error.Backpressure => {
                        self.backpressured += 1;
                        try std.Io.sleep(self.connection.io, .fromMilliseconds(1), .awake);
                        continue;
                    },
                    else => return err,
                };
                break;
            }
        }
    }
};

fn receiveInOrder(server: *Connection, count: usize, pause_every: usize) !void {
    for (0..count) |sequence| {
        const message = try receiveDeadline(server, std.Io.Clock.awake.now(server.io));
        try std.testing.expectEqual(@as(usize, message_size), message.data.len);
        try std.testing.expectEqual(@as(u32, @intCast(sequence)), std.mem.readInt(u32, message.data[0..4], .little));
        for (message.data[4..]) |byte| try std.testing.expectEqual(@as(u8, @truncate(sequence)), byte);
        if (pause_every != 0 and sequence % pause_every == 0)
            try std.Io.sleep(server.io, .fromMilliseconds(1), .awake);
    }
}

test "a stalled reliable receiver throttles the sender and recovers without loss" {
    const io = std.testing.io;
    const pair = try createPair(io, 41);
    defer pair[0].destroy();
    defer pair[1].destroy();
    const client, const server = pair;

    var sender: Sender = .{ .connection = client };
    var sending = try io.concurrent(Sender.run, .{&sender});
    var sent = false;
    defer if (!sent) sending.cancel(io) catch {};

    try std.Io.sleep(io, .fromMilliseconds(2000), .awake);
    try std.testing.expectEqual(nethernet.State.connected, server.state());
    const stalled = server.callbackStats();
    try std.testing.expect(stalled.receive_pauses > 0);
    try std.testing.expect(stalled.queue_high_water_entries <= 64);
    try std.testing.expect(stalled.queue_high_water_bytes <= 512 * 1024);
    try std.testing.expect(sender.backpressured > 0);

    try receiveInOrder(server, message_count, 0);
    try sending.await(io);
    sent = true;
    try std.testing.expectEqual(nethernet.State.connected, client.state());

    try client.send("after", .reliable);
    try std.testing.expectEqualStrings("after", (try receiveDeadline(server, std.Io.Clock.awake.now(io))).data);
}

test "a slow reliable receiver keeps every message in order" {
    const io = std.testing.io;
    const pair = try createPair(io, 42);
    defer pair[0].destroy();
    defer pair[1].destroy();
    const client, const server = pair;

    var sender: Sender = .{ .connection = client };
    var sending = try io.concurrent(Sender.run, .{&sender});
    var sent = false;
    defer if (!sent) sending.cancel(io) catch {};
    try receiveInOrder(server, message_count, 25);
    try sending.await(io);
    sent = true;
}

test "closing a paused receiver neither hangs nor leaks" {
    const io = std.testing.io;
    for (0..3) |round| {
        const pair = try createPair(io, 43 + round);
        defer pair[0].destroy();
        const client, const server = pair;

        var sender: Sender = .{ .connection = client };
        var sending = try io.concurrent(Sender.run, .{&sender});
        defer _ = sending.cancel(io) catch {};

        const started = std.Io.Clock.awake.now(io);
        while (server.callbackStats().receive_pauses == 0) {
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 10_000) return error.Timeout;
            try std.Io.sleep(io, .fromMilliseconds(5), .awake);
        }
        if (round == 0) server.closeGracefully() catch {};
        server.destroy();
    }
}
