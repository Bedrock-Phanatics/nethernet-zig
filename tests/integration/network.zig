const std = @import("std");
const nethernet = @import("nethernet");
const Connection = nethernet.Connection;

fn timeoutAfter(start: std.Io.Timestamp, milliseconds: u32) std.Io.Timeout {
    return .{ .deadline = .{
        .raw = start.addDuration(.fromMilliseconds(milliseconds)),
        .clock = .awake,
    } };
}

fn earliest(a: std.Io.Timeout, b: std.Io.Timeout) std.Io.Timeout {
    if (a == .none) return b;
    if (b == .none) return a;
    return if (a.deadline.raw.nanoseconds < b.deadline.raw.nanoseconds) a else b;
}

const Proxy = struct {
    const DelayedPacket = struct {
        data: [2048]u8 = undefined,
        len: usize = 0,
        destination: std.Io.net.IpAddress = undefined,
        due_ms: i64 = 0,
    };

    io: std.Io,
    socket: std.Io.net.Socket,
    mutex: std.Io.Mutex = .init,
    endpoints: [2]?std.Io.net.IpAddress = .{ null, null },
    group: std.Io.Group = .init,
    dropped: std.atomic.Value(u32) = .init(0),
    duplicated: std.atomic.Value(u32) = .init(0),
    overflowed: std.atomic.Value(u32) = .init(0),
    failure: std.atomic.Value(bool) = .init(false),

    fn run(self: *Proxy) std.Io.Cancelable!void {
        self.loop() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => self.failure.store(true, .release),
        };
    }

    fn loop(self: *Proxy) !void {
        var delayed: [64]DelayedPacket = @splat(.{});
        var random = std.Random.DefaultPrng.init(0x123fed);
        var buffer: [2048]u8 = undefined;

        while (true) {
            try self.flushDue(&delayed);

            const Result = union(enum) {
                packet: std.Io.net.Socket.ReceiveError!std.Io.net.IncomingMessage,
                timeout: std.Io.Cancelable!void,
            };
            var results: [2]Result = undefined;
            var select = std.Io.Select(Result).init(self.io, &results);
            defer select.cancelDiscard();

            try select.concurrent(
                .packet,
                std.Io.net.Socket.receive,
                .{ &self.socket, self.io, &buffer },
            );

            const deadline = nextDeadline(&delayed);
            if (deadline != .none) {
                try select.concurrent(
                    .timeout,
                    std.Io.Timeout.sleep,
                    .{ deadline, self.io },
                );
            }

            const incoming = switch (try select.await()) {
                .packet => |result| try result,
                .timeout => |result| {
                    try result;
                    continue;
                },
            };
            select.cancelDiscard();

            if (incoming.flags.trunc) return error.ProxyPacketTooLarge;
            const destination = self.destinationFor(incoming.from) orelse continue;

            if (random.random().uintLessThan(u32, 100) < 5) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                continue;
            }

            const copies: usize = if (random.random().uintLessThan(u32, 100) < 5) 2 else 1;
            if (copies == 2) _ = self.duplicated.fetchAdd(1, .monotonic);

            for (0..copies) |_| {
                const delay_ms = 2 + random.random().uintLessThan(u32, 8);
                try self.queuePacket(&delayed, incoming.data, destination, delay_ms);
            }
        }
    }

    fn flushDue(self: *Proxy, delayed: []DelayedPacket) !void {
        const now_ms = std.Io.Clock.awake.now(self.io).toMilliseconds();
        for (delayed) |*packet| {
            if (packet.len == 0 or packet.due_ms > now_ms) continue;
            try self.socket.send(
                self.io,
                &packet.destination,
                packet.data[0..packet.len],
            );
            packet.len = 0;
        }
    }

    fn nextDeadline(delayed: []DelayedPacket) std.Io.Timeout {
        var deadline: std.Io.Timeout = .none;
        for (delayed) |packet| {
            if (packet.len == 0) continue;
            deadline = earliest(deadline, .{ .deadline = .{
                .raw = .{
                    .nanoseconds = @as(i96, packet.due_ms) * std.time.ns_per_ms,
                },
                .clock = .awake,
            } });
        }
        return deadline;
    }

    fn destinationFor(self: *Proxy, source: std.Io.net.IpAddress) ?std.Io.net.IpAddress {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.endpoints[0]) |client| {
            if (source.getPort() == client.getPort()) return self.endpoints[1];
        }
        if (self.endpoints[1]) |server| {
            if (source.getPort() == server.getPort()) return self.endpoints[0];
        }
        return null;
    }

    fn queuePacket(
        self: *Proxy,
        delayed: []DelayedPacket,
        data: []const u8,
        destination: std.Io.net.IpAddress,
        delay_ms: u32,
    ) !void {
        for (delayed) |*packet| {
            if (packet.len != 0) continue;
            @memcpy(packet.data[0..data.len], data);
            packet.len = data.len;
            packet.destination = destination;
            packet.due_ms = std.Io.Clock.awake.now(self.io).toMilliseconds() + @as(i64, delay_ms);
            return;
        }

        _ = self.overflowed.fetchAdd(1, .monotonic);
        return error.ProxyQueueFull;
    }

    fn rewriteCandidate(
        self: *Proxy,
        allocator: std.mem.Allocator,
        endpoint_index: usize,
        sdp: []const u8,
    ) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");
        var candidate_added = false;
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "a=candidate:")) {
                try output.appendSlice(allocator, line);
                try output.appendSlice(allocator, "\r\n");
                continue;
            }
            if (candidate_added) continue;

            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            var parts: [6][]const u8 = undefined;
            for (&parts) |*part| {
                part.* = fields.next() orelse return error.InvalidCandidate;
            }

            const port = try std.fmt.parseInt(u16, parts[5], 10);
            _ = std.Io.net.IpAddress.parseIp4(parts[4], port) catch continue;
            const endpoint = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

            self.mutex.lockUncancelable(self.io);
            self.endpoints[endpoint_index] = endpoint;
            self.mutex.unlock(self.io);

            const replacement = try std.fmt.allocPrint(
                allocator,
                "a=candidate:proxy 1 UDP 2130706431 127.0.0.1 {d} typ host\r\n",
                .{self.socket.address.getPort()},
            );
            defer allocator.free(replacement);

            try output.appendSlice(allocator, replacement);
            candidate_added = true;
        }

        if (!candidate_added) return error.NoIpv4Candidate;
        return output.toOwnedSlice(allocator);
    }
};

test "real WebRTC survives loopback UDP loss duplication jitter and reordering" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var proxy: Proxy = .{
        .io = io,
        .socket = try address.bind(io, .{ .mode = .dgram, .protocol = .udp }),
    };
    defer proxy.socket.close(io);

    try proxy.group.concurrent(io, Proxy.run, .{&proxy});
    defer proxy.group.cancel(io);

    const ConnectionOptions = nethernet.ConnectionOptions;
    const client_options: ConnectionOptions = .{
        .native = .{ .disable_trickle = true },
        .negotiation_timeout_ms = 30_000,
        .connection_timeout_ms = 30_000,
    };
    const client = try Connection.create(
        allocator,
        io,
        .client,
        7,
        "server",
        client_options,
    );
    defer client.destroy();

    var server_options = client_options;
    server_options.allow_anonymous = true;
    const server = try Connection.create(
        allocator,
        io,
        .server,
        7,
        "client",
        server_options,
    );
    defer server.destroy();

    try client.start();
    const started = std.Io.Clock.awake.now(io);
    while (!client.ready() or !server.ready()) {
        for (
            [_]*Connection{ client, server },
            [_]*Connection{ server, client },
            0..,
        ) |source, destination, endpoint_index| {
            const event = try source.pollNegotiation() orelse continue;
            switch (event) {
                .signal => |signal| {
                    const rewritten = try proxy.rewriteCandidate(
                        allocator,
                        endpoint_index,
                        signal.data,
                    );
                    defer allocator.free(rewritten);

                    var routed = signal;
                    routed.data = rewritten;
                    routed.network_id = if (endpoint_index == 0) "client" else "server";
                    try destination.applySignal(routed);
                },
                .message => return error.UnexpectedMessage,
            }
        }

        const timed_out = started.durationTo(
            std.Io.Clock.awake.now(io),
        ).toMilliseconds() > 30_000;
        if (timed_out or proxy.failure.load(.acquire)) return error.ProxyFailed;

        const has_pending =
            client.peer.hasPending(true) or server.peer.hasPending(true);
        if ((!client.ready() or !server.ready()) and !has_pending) {
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }

    const data = try allocator.alloc(u8, 262_156);
    defer allocator.free(data);
    for (data, 0..) |*byte, index| byte.* = @truncate(index);

    for ([_]usize{ 32, 128, 8192, 262_156 }) |size| {
        try client.send(data[0..size], .reliable);
        const sent = std.Io.Clock.awake.now(io);

        while (true) {
            server.prepareWait();
            if (try server.poll()) |event| switch (event) {
                .message => |message| {
                    try std.testing.expectEqualSlices(
                        u8,
                        data[0..size],
                        message.data,
                    );
                    break;
                },
                .signal => return error.UnexpectedSignal,
            };

            const timed_out = sent.durationTo(
                std.Io.Clock.awake.now(io),
            ).toMilliseconds() > 30_000;
            if (timed_out or proxy.failure.load(.acquire)) return error.ProxyFailed;
            if (!server.peer.hasPending(false)) {
                try server.peer.wakeup.wait(io, timeoutAfter(sent, 30_000));
            }
        }
    }

    try std.testing.expect(proxy.dropped.load(.acquire) > 0);
    try std.testing.expect(proxy.duplicated.load(.acquire) > 0);
    try std.testing.expectEqual(@as(u32, 0), proxy.overflowed.load(.acquire));

    const drain_started = std.Io.Clock.awake.now(io);
    while (drain_started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 200) {
        server.prepareWait();
        try std.testing.expect((try server.poll()) == null);
        if (!server.peer.hasPending(false)) {
            try server.peer.wakeup.wait(io, timeoutAfter(drain_started, 200));
        }
    }
}
