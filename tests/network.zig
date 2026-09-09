const std = @import("std");
const wake = @import("../src/wakeup.zig");
const Connection = @import("../src/connection.zig").Connection;

// Adds packet loss and duplication below SCTP.
const Proxy = struct {
    io: std.Io,
    socket: std.Io.net.Socket,
    mutex: std.Io.Mutex = .init,
    endpoints: [2]?std.Io.net.IpAddress = .{ null, null },
    group: std.Io.Group = .init,
    dropped: std.atomic.Value(u32) = .init(0),
    duplicated: std.atomic.Value(u32) = .init(0),
    failure: std.atomic.Value(bool) = .init(false),
    overflowed: std.atomic.Value(u32) = .init(0),
    fn run(self: *Proxy) std.Io.Cancelable!void {
        self.loop() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => self.failure.store(true, .release),
        };
    }

    fn loop(self: *Proxy) !void {
        const Delayed = struct { data: [2048]u8 = undefined, len: usize = 0, dest: std.Io.net.IpAddress = undefined, due: i64 = 0 };
        var delayed: [64]Delayed = @splat(.{});
        var random = std.Random.DefaultPrng.init(0x123fed);
        var buffer: [2048]u8 = undefined;

        while (true) {
            const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
            for (&delayed) |*packet| if (packet.len != 0 and packet.due <= now) {
                try self.socket.send(self.io, &packet.dest, packet.data[0..packet.len]);
                packet.len = 0;
            };
            const Result = union(enum) { packet: std.Io.net.Socket.ReceiveError!std.Io.net.IncomingMessage, timeout: std.Io.Cancelable!void };
            var results: [2]Result = undefined;
            var select = std.Io.Select(Result).init(self.io, &results);
            defer select.cancelDiscard();

            try select.concurrent(.packet, std.Io.net.Socket.receive, .{ &self.socket, self.io, &buffer });
            var deadline: std.Io.Timeout = .none;
            for (&delayed) |*packet| if (packet.len != 0) {
                deadline = wake.earliest(deadline, .{ .deadline = .{
                    .raw = .{ .nanoseconds = @as(i96, packet.due) * std.time.ns_per_ms },
                    .clock = .awake,
                } });
            };
            if (deadline != .none) try select.concurrent(.timeout, std.Io.Timeout.sleep, .{ deadline, self.io });
            const incoming = switch (try select.await()) {
                .packet => |result| try result,
                .timeout => |result| {
                    try result;
                    continue;
                },
            };
            select.cancelDiscard();
            if (incoming.flags.trunc) return error.ProxyPacketTooLarge;
            self.mutex.lockUncancelable(self.io);
            const endpoints = self.endpoints;
            self.mutex.unlock(self.io);
            const dest = if (endpoints[0] != null and incoming.from.getPort() == endpoints[0].?.getPort()) endpoints[1] else if (endpoints[1] != null and incoming.from.getPort() == endpoints[1].?.getPort()) endpoints[0] else null;
            const target = dest orelse continue;
            if (random.random().uintLessThan(u32, 100) < 5) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                continue;
            }
            const copies: usize = if (random.random().uintLessThan(u32, 100) < 5) 2 else 1;
            if (copies == 2) _ = self.duplicated.fetchAdd(1, .monotonic);
            for (0..copies) |_| {
                var queued = false;
                for (&delayed) |*packet| {
                    if (packet.len != 0) continue;
                    @memcpy(packet.data[0..incoming.data.len], incoming.data);
                    packet.len = incoming.data.len;
                    packet.dest = target;
                    packet.due = std.Io.Clock.awake.now(self.io).toMilliseconds() + 2 + random.random().uintLessThan(u32, 8);
                    queued = true;
                    break;
                }
                if (!queued) {
                    _ = self.overflowed.fetchAdd(1, .monotonic);
                    return error.ProxyQueueFull;
                }
            }
        }
    }

    fn rewrite(self: *Proxy, a: std.mem.Allocator, index: usize, sdp: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(a);

        var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");
        var added = false;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "a=candidate:")) {
                if (added) continue;
                var fields = std.mem.tokenizeScalar(u8, line, ' ');
                var parts: [6][]const u8 = undefined;
                for (&parts) |*part| part.* = fields.next() orelse return error.InvalidCandidate;
                const port = try std.fmt.parseInt(u16, parts[5], 10);
                _ = std.Io.net.IpAddress.parseIp4(parts[4], port) catch continue;
                // Send wildcard-bound sockets through loopback for the test.
                const endpoint = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
                self.mutex.lockUncancelable(self.io);
                self.endpoints[index] = endpoint;
                self.mutex.unlock(self.io);
                const replacement = try std.fmt.allocPrint(a, "a=candidate:proxy 1 UDP 2130706431 127.0.0.1 {d} typ host\r\n", .{self.socket.address.getPort()});
                defer a.free(replacement);

                try output.appendSlice(a, replacement);
                added = true;
            } else {
                try output.appendSlice(a, line);
                try output.appendSlice(a, "\r\n");
            }
        }
        if (!added) return error.NoIpv4Candidate;
        return output.toOwnedSlice(a);
    }
};

test "real WebRTC survives loopback UDP loss duplication jitter and reordering" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var proxy = Proxy{ .io = io, .socket = try address.bind(io, .{ .mode = .dgram, .protocol = .udp }) };
    defer proxy.socket.close(io);

    try proxy.group.concurrent(io, Proxy.run, .{&proxy});
    defer proxy.group.cancel(io);

    const client = try Connection.create(a, io, .client, 7, "server", .{ .native = .{ .disable_trickle = true }, .negotiation_timeout_ms = 30000, .connection_timeout_ms = 30000 });
    defer client.destroy();

    const server = try Connection.create(a, io, .server, 7, "client", .{ .native = .{ .disable_trickle = true }, .allow_anonymous = true, .negotiation_timeout_ms = 30000, .connection_timeout_ms = 30000 });
    defer server.destroy();

    var wakeup: wake.Wakeup = .{};
    client.peer.subscribe(&wakeup);
    server.peer.subscribe(&wakeup);
    defer client.peer.subscribe(null);
    defer server.peer.subscribe(null);
    try client.start();
    const started = std.Io.Clock.awake.now(io);
    while (!client.ready() or !server.ready()) {
        wakeup.prepare();
        for ([_]*Connection{ client, server }, [_]*Connection{ server, client }, 0..) |source, dest, index| {
            if (try source.pollNegotiation()) |event| switch (event) {
                .signal => |signal| {
                    const rewritten = try proxy.rewrite(a, index, signal.data);
                    defer a.free(rewritten);

                    var routed = signal;
                    routed.data = rewritten;
                    routed.network_id = if (index == 0) "client" else "server";
                    try dest.applySignal(routed);
                },
                else => return error.UnexpectedMessage,
            };
        }
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 30000 or proxy.failure.load(.acquire)) return error.ProxyFailed;
        if ((!client.ready() or !server.ready()) and !client.peer.hasPending(true) and !server.peer.hasPending(true))
            try wakeup.wait(io, wake.deadline(started, 30000));
    }
    const data = try a.alloc(u8, 262156);
    defer a.free(data);

    for (data, 0..) |*byte, index| byte.* = @truncate(index);
    for ([_]usize{ 32, 128, 8192, 262156 }) |size| {
        try client.send(data[0..size], .reliable);
        const send_time = std.Io.Clock.awake.now(io);
        while (true) {
            server.prepareWait();
            if (try server.poll()) |event| switch (event) {
                .message => |message| {
                    try std.testing.expectEqualSlices(u8, data[0..size], message.data);
                    break;
                },
                else => return error.UnexpectedSignal,
            };
            if (send_time.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 30000 or proxy.failure.load(.acquire)) return error.ProxyFailed;
            if (!server.peer.hasPending(false))
                try server.peer.wakeup.wait(io, wake.deadline(send_time, 30000));
        }
    }
    try std.testing.expect(proxy.dropped.load(.acquire) > 0);
    try std.testing.expect(proxy.duplicated.load(.acquire) > 0);
    try std.testing.expectEqual(@as(u32, 0), proxy.overflowed.load(.acquire));
    const end = std.Io.Clock.awake.now(io);
    while (end.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 200) {
        server.prepareWait();
        try std.testing.expect((try server.poll()) == null);
        if (!server.peer.hasPending(false)) try server.peer.wakeup.wait(io, wake.deadline(end, 200));
    }
}
