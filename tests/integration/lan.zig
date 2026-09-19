const std = @import("std");
const nethernet = @import("nethernet");

const ConnectionOptions = nethernet.ConnectionOptions;
const Discovery = nethernet.Discovery;
const Listener = nethernet.LanListener;

test "LAN discovery signaling negotiates WebRTC with trickle ICE" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");

    const server_discovery = try Discovery.listen(
        allocator,
        io,
        address,
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

    try server_discovery.setServerData(.{ .server_name = "LAN" });
    try client_discovery.request(server_discovery.socket.address);
    _ = try server_discovery.poll(1000);
    _ = try client_discovery.poll(1000);

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
