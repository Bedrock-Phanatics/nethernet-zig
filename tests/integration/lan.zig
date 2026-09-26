const std = @import("std");
const nethernet = @import("nethernet");

const ConnectionOptions = nethernet.ConnectionOptions;
const Discovery = nethernet.Discovery;
const Listener = nethernet.LanListener;

test "LAN hosts share UDP 7551 and rebind after close" {
    const before = try processHandleCount();
    {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        defer threaded.deinit();
        try sharedBindCycles(threaded.io());
    }
    if (before) |count| try std.testing.expect((try processHandleCount()).? <= count);
}

fn processHandleCount() !?u32 {
    if (@import("builtin").os.tag != .windows) return null;
    const windows = std.os.windows;
    const kernel32 = struct {
        extern "kernel32" fn GetProcessHandleCount(windows.HANDLE, *u32) callconv(.winapi) windows.BOOL;
    };
    var count: u32 = undefined;
    if (kernel32.GetProcessHandleCount(windows.GetCurrentProcess(), &count) == .FALSE)
        return error.HandleCountFailed;
    return count;
}

fn sharedBindCycles(io: std.Io) !void {
    const address = try std.Io.net.IpAddress.parseLiteral("0.0.0.0:7551");
    const destination = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:7551");
    const client = try Discovery.listen(std.testing.allocator, io, .{ .ip4 = .loopback(0) }, .{ .network_id = 1 });
    defer client.destroy();
    for (0..16) |_| {
        const first = try Discovery.listen(std.testing.allocator, io, address, .{ .network_id = 2 });
        defer first.destroy();
        const second = try Discovery.listen(std.testing.allocator, io, address, .{ .network_id = 3 });
        defer second.destroy();
        try std.testing.expectEqual(@as(u16, 7551), first.socket.address.getPort());
        try std.testing.expectEqual(@as(u16, 7551), second.socket.address.getPort());
        try client.request(destination);
        _ = try first.poll(100);
        _ = try second.poll(100);
        // Shared sockets need not both receive the request.
        try std.testing.expect(first.servers.contains(1) or second.servers.contains(1));
        first.close();
        first.close();
        second.close();
    }
}

test "LAN shared bind cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sharedBindAllocationFailure, .{});
}

fn sharedBindAllocationFailure(allocator: std.mem.Allocator) !void {
    const discovery = try Discovery.listen(allocator, std.testing.io, .{ .ip4 = .loopback(7551) }, .{});
    defer discovery.destroy();
    try discovery.setServerData(.{ .server_name = "allocation failure" });
}

test "LAN discovery signaling negotiates WebRTC with trickle ICE" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("0.0.0.0:0");

    const server_discovery = try Discovery.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("0.0.0.0:7551"),
        .{ .network_id = 22 },
    );
    defer server_discovery.destroy();

    const client_discovery = try Discovery.listen(
        allocator,
        io,
        address,
        .{ .network_id = 11 },
    );
    defer client_discovery.destroy();

    try std.testing.expectError(error.AddressInUse, Discovery.listen(
        allocator,
        io,
        client_discovery.socket.address,
        .{},
    ));

    const advertised: nethernet.ServerData = .{
        .server_name = "LAN",
        .protocol = 2216,
        .version = "1.26.60-beta.28",
        .level_name = "Test world",
        .game_type = 1,
        .player_count = 1,
        .max_player_count = 8,
        .accepts_online_auth = true,
        .accepts_self_signed_auth = true,
    };
    try server_discovery.setServerData(advertised);
    try std.testing.expect(client_discovery.socket.address.getPort() != 7551);
    const broadcast = client_discovery.options.broadcast_endpoint.?;
    try std.testing.expectEqual(try std.Io.net.IpAddress.parseLiteral("255.255.255.255:7551"), broadcast);
    try client_discovery.request(broadcast);
    _ = try server_discovery.poll(1000);
    _ = try client_discovery.poll(1000);

    const known_server = client_discovery.servers.get(22) orelse return error.ServerNotDiscovered;
    const known_client = server_discovery.servers.get(11) orelse return error.ClientNotDiscovered;
    try std.testing.expectEqual(client_discovery.socket.address.getPort(), known_client.endpoint.getPort());
    try std.testing.expectEqual(@as(u16, 7551), known_server.endpoint.getPort());
    try std.testing.expect(!std.mem.eql(u8, &known_client.endpoint.ip4.bytes, &.{ 0, 0, 0, 0 }));
    const response = known_server.response orelse return error.MissingAdvertisement;
    try std.testing.expectEqual(@as(u8, 7), response[0]);
    const decoded = try nethernet.ServerData.decode(response);
    try std.testing.expectEqualDeep(advertised, decoded);

    const options: nethernet.LanListenerOptions = .{
        .connection = .{ .allow_anonymous = true },
    };
    const listener = try Listener.listen(allocator, server_discovery, options);
    defer listener.destroy();

    const restored_listener = try Listener.listen(allocator, client_discovery, options);
    defer restored_listener.destroy();

    var dialing = try io.concurrent(
        nethernet.dialLan,
        .{ allocator, client_discovery, @as(u64, 22), ConnectionOptions{} },
    );
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
    const transfer_started = std.Io.Clock.awake.now(io);
    try client.send("LAN application payload", .reliable);
    const received = try @import("concurrency.zig").receiveDeadline(server, transfer_started);
    try std.testing.expectEqualStrings("LAN application payload", received.data);
    try server.send(received.data, .reliable);
    const echoed = try @import("concurrency.zig").receiveDeadline(client, transfer_started);
    try std.testing.expectEqualStrings("LAN application payload", echoed.data);

    try std.testing.expect(client_discovery.isSubscribed(&restored_listener.wakeup));

    // The restored subscription must wake the second accept promptly.
    const accept_started = std.Io.Clock.awake.now(io);
    var reverse_dialing = try io.concurrent(
        nethernet.dialLan,
        .{ allocator, server_discovery, @as(u64, 11), ConnectionOptions{} },
    );
    var reverse_taken = false;
    defer if (!reverse_taken) {
        if (reverse_dialing.cancel(io)) |value| value.destroy() else |_| {}
    };

    const reverse_server = try restored_listener.accept();
    defer reverse_server.destroy();
    try std.testing.expect(
        accept_started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 1900,
    );

    const reverse_client = try reverse_dialing.await(io);
    reverse_taken = true;
    defer reverse_client.destroy();
}

test "LAN host bounds malformed traffic and server count" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:7551");
    const server = try Discovery.listen(std.testing.allocator, io, address, .{ .network_id = 22, .maximum_servers = 1 });
    defer server.destroy();
    const client = try Discovery.listen(std.testing.allocator, io, .{ .ip4 = .loopback(0) }, .{ .network_id = 11 });
    defer client.destroy();

    const malformed = [_]u8{0} ** 65507;
    for ([_]usize{ 0, 1, 31, malformed.len }) |length| {
        try client.socket.send(io, &address, malformed[0..length]);
        _ = try server.poll(1000);
    }
    try std.testing.expectEqual(@as(u64, 4), server.malformed_datagrams);
    try std.testing.expectEqual(@as(u32, 0), server.servers.count());

    try client.request(address);
    _ = try server.poll(1000);
    client.id = 12;
    try client.request(address);
    _ = try server.poll(1000);
    try std.testing.expectEqual(@as(u32, 1), server.servers.count());
    try std.testing.expectEqual(@as(u64, 1), server.dropped_servers);
}

test "LAN accept cancels and close detaches the wakeup" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const discovery = try Discovery.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{},
    );
    defer discovery.destroy();

    const listener = try Listener.listen(allocator, discovery, .{});
    defer listener.destroy();

    var pending = try io.concurrent(Listener.accept, .{listener});
    try std.testing.expectError(error.Canceled, pending.cancel(io));

    listener.close();
    try std.testing.expect(discovery.subscriber == null);
    try std.testing.expectError(error.ConnectionClosed, listener.accept());
}
