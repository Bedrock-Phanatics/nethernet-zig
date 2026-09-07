const std = @import("std");
const Peer = @import("../src/peer.zig").Peer;
const wake = @import("../src/wakeup.zig");
const framing = @import("../src/framing.zig");

test "native peers negotiate and exchange both channel types" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const a = try Peer.create(allocator, io, .{ .disable_trickle = true });
    defer a.destroy();

    const b = try Peer.create(allocator, io, .{ .disable_trickle = true });
    defer b.destroy();

    const buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buffer);

    var wakeup: wake.Wakeup = .{};
    a.subscribe(&wakeup);
    b.subscribe(&wakeup);
    defer a.subscribe(null);
    defer b.subscribe(null);
    try a.offer();
    const start = std.Io.Clock.awake.now(io);
    while (!a.ready() or !b.ready()) {
        wakeup.prepare();
        if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 15000) return error.Timeout;
        for ([_]*Peer{ a, b }, [_]*Peer{ b, a }) |source, dest| {
            if (try source.poll(buffer)) |event| switch (event) {
                .offer, .answer => |sdp| {
                    const terminated = try allocator.dupeZ(u8, sdp);
                    defer allocator.free(terminated);

                    try dest.remoteDescription(terminated, if (event == .offer) .offer else .answer);
                },
                else => return error.UnexpectedEvent,
            };
        }
        if ((!a.ready() or !b.ready()) and !a.hasPending(false) and !b.hasPending(false))
            try wakeup.wait(io, wake.deadline(start, 15000));
    }
    for ([_]framing.Reliability{ .reliable, .unreliable }) |reliability| {
        try a.send("hello", reliability, buffer);
        var got = false;
        while (!got) {
            b.wakeup.prepare();
            if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 20000) return error.Timeout;
            if (try b.poll(buffer)) |event| switch (event) {
                .reliable_fragment, .unreliable_fragment => |fragment| {
                    try std.testing.expectEqualSlices(u8, &.{ 0, 'h', 'e', 'l', 'l', 'o' }, fragment);
                    try std.testing.expectEqual(reliability == .reliable, event == .reliable_fragment);
                    got = true;
                },
                else => return error.UnexpectedEvent,
            };
            if (!got and !b.hasPending(false)) try b.wakeup.wait(io, wake.deadline(start, 20000));
        }
    }
    a.close();
    a.close();
}

test "connections verify identities, reassemble large messages, and reconnect" {
    const Connection = @import("../src/connection.zig").Connection;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const payload = try a.alloc(u8, framing.maximum_segment_payload + 13);
    defer a.free(payload);

    for (payload, 0..) |*byte, i| byte.* = @truncate(i);
    for (0..2) |_| {
        const client = try Connection.create(a, io, .client, 7, "server", .{ .native = .{ .disable_trickle = true } });
        defer client.destroy();

        const server = try Connection.create(a, io, .server, 7, "client", .{ .native = .{ .disable_trickle = true }, .allow_anonymous = true });
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
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 20000) return error.Timeout;
            for ([_]*Connection{ client, server }, [_]*Connection{ server, client }, [_][]const u8{ "client", "server" }) |source, dest, name| {
                if (try source.poll()) |event| switch (event) {
                    .signal => |signal| {
                        var routed = signal;
                        routed.network_id = name;
                        try dest.applySignal(routed);
                    },
                    else => return error.UnexpectedEvent,
                };
            }
            if ((!client.ready() or !server.ready()) and !client.peer.hasPending(true) and !server.peer.hasPending(true))
                try wakeup.wait(io, wake.deadline(started, 20000));
        }
        try std.testing.expect(client.public_key != null);
        try client.send(payload, .reliable);
        const message = try server.receive();
        try std.testing.expectEqualSlices(u8, payload, message.data);
        try std.testing.expectEqual(@as(u64, payload.len), server.received_bytes);
    }
}

test {
    _ = @import("../src/endpoint.zig");
}

test "HTTP endpoint listener and dialer transfer ownership and shut down" {
    const Listener = @import("../src/endpoint_listener.zig").Listener;
    const endpoint = @import("../src/endpoint.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(a, io, try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"), .{ .connection = .{ .allow_anonymous = true }, .maximum_negotiations = 2 });
    defer listener.destroy();

    const origin = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{listener.server.socket.address.getPort()});
    defer a.free(origin);

    const client = try endpoint.dial(a, io, origin, 12, .{});
    defer client.destroy();

    const server = try listener.accept();
    defer server.destroy();

    listener.close();
    listener.close();
    try client.send("survives listener close", .reliable);
    const message = try server.receive();
    try std.testing.expectEqualStrings("survives listener close", message.data);
}

test "LAN discovery signaling negotiates WebRTC with trickle ICE" {
    const Discovery = @import("../src/discovery.zig").Discovery;
    const lan = @import("../src/lan.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    const server_discovery = try Discovery.listen(a, io, address, .{ .network_id = 22 });
    defer server_discovery.destroy();

    const client_discovery = try Discovery.listen(a, io, address, .{ .network_id = 11 });
    defer client_discovery.destroy();

    try server_discovery.setServerData(.{ .server_name = "LAN" });
    try client_discovery.request(server_discovery.socket.address);
    _ = try server_discovery.poll(1000);
    _ = try client_discovery.poll(1000);
    const listener = try lan.Listener.listen(a, server_discovery, .{ .connection = .{ .allow_anonymous = true } });
    defer listener.destroy();

    var dialing = try io.concurrent(lan.dial, .{ a, client_discovery, @as(u64, 22), @import("../src/connection.zig").Options{} });
    var taken = false;
    defer if (!taken) {
        if (dialing.cancel(io)) |value| value.destroy() else |_| {}
    };
    const server = try listener.accept();
    defer server.destroy();

    const client = try dialing.await(io);
    taken = true;
    defer client.destroy();

    try std.testing.expect(client.public_key != null);
}

test {
    _ = @import("network.zig");
}

test "HTTP rejects invalid routes, network IDs, empty SDP and oversized bodies" {
    const Listener = @import("../src/endpoint_listener.zig").Listener;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(a, io, try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"), .{ .maximum_negotiations = 2 });
    defer listener.destroy();

    const cases = [_]struct { request: []const u8, status: []const u8 }{
        .{ .request = "GET /bad HTTP/1.1\r\nHost: localhost\r\n\r\n", .status = "404" },
        .{ .request = "POST /v1/join/nope HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n", .status = "400" },
        .{ .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n", .status = "400" },
        .{ .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048577\r\n\r\n", .status = "413" },
        .{ .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nnope", .status = "400" },
    };
    for (cases) |case| {
        const stream = try listener.server.socket.address.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(case.request);
        try writer.interface.flush();
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        const prefix = try reader.interface.take(12);
        try std.testing.expectEqualStrings(case.status, prefix[9..12]);
    }
}

test "LAN accept cancels and close detaches the wakeup" {
    const Discovery = @import("../src/discovery.zig").Discovery;
    const Listener = @import("../src/lan.zig").Listener;
    const io = std.testing.io;
    const discovery = try Discovery.listen(std.testing.allocator, io, try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"), .{});
    defer discovery.destroy();
    const listener = try Listener.listen(std.testing.allocator, discovery, .{});
    defer listener.destroy();
    var pending = try io.concurrent(Listener.accept, .{listener});
    try std.testing.expectError(error.Canceled, pending.cancel(io));
    listener.close();
    try std.testing.expect(discovery.subscriber == null);
    try std.testing.expectError(error.ConnectionClosed, listener.accept());
}
