const std = @import("std");
const nethernet = @import("nethernet");

/// Echoes one client's messages until it sends "ack". `--lan` hosts on LAN discovery as network 7 instead.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const connection = if (args.len > 1 and std.mem.eql(u8, args[1], "--lan"))
        try acceptLan(init.gpa, init.io)
    else
        try acceptEndpoint(init.gpa, init.io);
    defer connection.destroy();

    while (true) {
        const message = try connection.receive();
        if (std.mem.eql(u8, message.data, "ack")) break;
        try connection.send(message.data, message.reliability);
    }
}

fn acceptEndpoint(gpa: std.mem.Allocator, io: std.Io) !*nethernet.Connection {
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:18750");
    const listener = try nethernet.EndpointListener.listen(gpa, io, address, .{
        .connection = .{ .allow_anonymous = true },
    });
    defer listener.destroy();
    std.debug.print("NetherNet server on http://127.0.0.1:18750\n", .{});
    return listener.accept();
}

fn acceptLan(gpa: std.mem.Allocator, io: std.Io) !*nethernet.Connection {
    const discovery = try nethernet.Discovery.listen(gpa, io, try .parseLiteral("0.0.0.0:7551"), .{ .network_id = 7 });
    defer discovery.destroy();
    try discovery.setServerData(.{ .server_name = "NetherNet", .level_name = "Echo", .max_player_count = 1 });
    const listener = try nethernet.LanListener.listen(gpa, discovery, .{ .connection = .{ .allow_anonymous = true } });
    defer listener.destroy();
    std.debug.print("NetherNet LAN server on UDP 7551, network 7\n", .{});
    return listener.accept();
}
