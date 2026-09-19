const std = @import("std");
const nethernet = @import("nethernet");
const Connection = nethernet.Connection;
const framing = nethernet.framing;
const Peer = nethernet.Peer;

test "native peers negotiate and exchange both channel types" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const a = try Peer.create(allocator, io, .{ .disable_trickle = true });
    defer a.destroy();

    const b = try Peer.create(allocator, io, .{ .disable_trickle = true });
    defer b.destroy();

    const buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buffer);

    try a.offer();

    const started = std.Io.Clock.awake.now(io);
    while (!a.ready() or !b.ready()) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 15_000) {
            return error.Timeout;
        }

        for ([_]*Peer{ a, b }, [_]*Peer{ b, a }) |source, destination| {
            if (try source.poll(buffer)) |event| switch (event) {
                .offer, .answer => |sdp| {
                    const terminated = try allocator.dupeZ(u8, sdp);
                    defer allocator.free(terminated);

                    try destination.remoteDescription(
                        terminated,
                        if (event == .offer) .offer else .answer,
                    );
                },
                else => return error.UnexpectedEvent,
            };
        }

        if ((!a.ready() or !b.ready()) and
            !a.hasPending(false) and
            !b.hasPending(false))
        {
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }

    for ([_]framing.Reliability{ .reliable, .unreliable }) |reliability| {
        try a.send("hello", reliability, buffer);

        var received = false;
        while (!received) {
            b.wakeup.prepare();
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 20_000) {
                return error.Timeout;
            }

            if (try b.poll(buffer)) |event| switch (event) {
                .reliable_fragment, .unreliable_fragment => |fragment| {
                    try std.testing.expectEqualSlices(
                        u8,
                        &.{ 0, 'h', 'e', 'l', 'l', 'o' },
                        fragment,
                    );
                    try std.testing.expectEqual(
                        reliability == .reliable,
                        event == .reliable_fragment,
                    );
                    received = true;
                },
                else => return error.UnexpectedEvent,
            };

            if (!received and !b.hasPending(false)) {
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
        }
    }

    const diagnostics = a.diagnostics();
    try std.testing.expect(
        diagnostics.ice_state == .connected or diagnostics.ice_state == .completed,
    );
    try std.testing.expectEqual(.complete, diagnostics.gathering_state);
    try std.testing.expectEqual(.open, diagnostics.reliable.state);
    try std.testing.expectEqual(.open, diagnostics.unreliable.state);
    try std.testing.expect(diagnostics.reliable.buffered_outgoing_bytes != null);
    try std.testing.expect(diagnostics.unreliable.buffered_outgoing_bytes != null);

    var local_ice: [128]u8 = undefined;
    var remote_ice: [128]u8 = undefined;
    const ice_addresses = (try a.selectedIceAddresses(&local_ice, &remote_ice)).?;
    try std.testing.expect(ice_addresses.local.len != 0);
    try std.testing.expect(ice_addresses.remote.len != 0);

    a.close();
    a.close();
}

test "connections verify identities, reassemble large messages, and reconnect" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const payload = try allocator.alloc(u8, framing.maximum_segment_payload + 13);
    defer allocator.free(payload);

    for (payload, 0..) |*byte, index| byte.* = @truncate(index);

    for (0..2) |_| {
        const client = try Connection.create(
            allocator,
            io,
            .client,
            7,
            "server",
            .{ .native = .{ .disable_trickle = true } },
        );
        defer client.destroy();

        const server = try Connection.create(
            allocator,
            io,
            .server,
            7,
            "client",
            .{
                .native = .{ .disable_trickle = true },
                .allow_anonymous = true,
            },
        );
        defer server.destroy();

        try client.start();

        const started = std.Io.Clock.awake.now(io);
        while (!client.ready() or !server.ready()) {
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 20_000) {
                return error.Timeout;
            }

            for (
                [_]*Connection{ client, server },
                [_]*Connection{ server, client },
                [_][]const u8{ "client", "server" },
            ) |source, destination, name| {
                if (try source.poll()) |event| switch (event) {
                    .signal => |signal| {
                        var routed = signal;
                        routed.network_id = name;
                        try destination.applySignal(routed);
                    },
                    else => return error.UnexpectedEvent,
                };
            }

            if ((!client.ready() or !server.ready()) and
                !client.peer.hasPending(true) and
                !server.peer.hasPending(true))
            {
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
        }

        try std.testing.expect(client.public_key != null);
        try std.testing.expect(client.remoteIceCandidateCount() > 0);

        try client.send(payload, .reliable);
        const message = try server.receive();
        try std.testing.expectEqualSlices(u8, payload, message.data);
        try std.testing.expectEqual(@as(u64, payload.len), server.received_bytes);

        var draining_receive = try io.concurrent(Connection.receive, .{server});
        var receive_taken = false;
        defer if (!receive_taken) {
            _ = draining_receive.cancel(io) catch {};
        };

        try client.send(payload, .reliable);
        const drained = try draining_receive.await(io);
        receive_taken = true;
        try std.testing.expectEqualSlices(u8, payload, drained.data);
        try std.testing.expectEqual(@as(u64, payload.len * 2), server.received_bytes);

        // An application acknowledgement proves delivery beyond the SCTP send buffer.
        const receipt = "large-message-received";
        try server.send(receipt, .reliable);
        const acknowledged = try client.receive();
        try std.testing.expectEqualSlices(u8, receipt, acknowledged.data);

        try client.closeGracefully();
        try std.testing.expectError(error.InvalidState, client.send("late", .reliable));
        client.close();
        client.close();
    }
}
