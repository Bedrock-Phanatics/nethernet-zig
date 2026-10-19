const std = @import("std");
const nethernet = @import("nethernet");
const Connection = nethernet.Connection;
const receiveDeadline = @import("concurrency.zig").receiveDeadline;

// Gives every client the same source address towards the server, like a NAT reusing a mapping.
const Relay = struct {
    io: std.Io,
    socket: std.Io.net.Socket,
    mutex: std.Io.Mutex = .init,
    client: ?std.Io.net.IpAddress = null,
    server: ?std.Io.net.IpAddress = null,
    blocked: std.atomic.Value(bool) = .init(false),
    stopped: std.atomic.Value(bool) = .init(false),
    group: std.Io.Group = .init,

    // A wake datagram ends the loop, since canceling a blocked Windows receive is not reliable.
    fn stop(self: *Relay) void {
        self.stopped.store(true, .release);
        const own = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.socket.address.getPort()) catch unreachable;
        self.socket.send(self.io, &own, "x") catch {};
        self.group.await(self.io) catch {};
    }

    fn run(self: *Relay) std.Io.Cancelable!void {
        var buffer: [2048]u8 = undefined;
        while (true) {
            const incoming = self.socket.receive(self.io, &buffer) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            if (self.stopped.load(.acquire)) return;
            if (self.blocked.load(.acquire)) continue;
            self.mutex.lockUncancelable(self.io);
            const client = self.client;
            const server = self.server;
            self.mutex.unlock(self.io);
            const destination = if (client != null and incoming.from.getPort() == client.?.getPort())
                server
            else if (server != null and incoming.from.getPort() == server.?.getPort())
                client
            else
                null;
            if (destination) |address| self.socket.send(self.io, &address, incoming.data) catch {};
        }
    }

    fn rewrite(self: *Relay, allocator: std.mem.Allocator, from_server: bool, sdp: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var replaced = false;
        var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "a=candidate:")) {
                try output.print(allocator, "{s}\r\n", .{line});
                continue;
            }
            if (replaced) continue;
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            var parts: [6][]const u8 = undefined;
            for (&parts) |*part| part.* = fields.next() orelse return error.InvalidCandidate;
            if (!std.mem.eql(u8, parts[4], "127.0.0.1")) continue;
            const endpoint = try std.Io.net.IpAddress.parseIp4("127.0.0.1", try std.fmt.parseInt(u16, parts[5], 10));
            self.mutex.lockUncancelable(self.io);
            if (from_server) self.server = endpoint else self.client = endpoint;
            self.mutex.unlock(self.io);
            try output.print(allocator, "a=candidate:relay 1 UDP 2130706431 127.0.0.1 {d} typ host\r\n", .{self.socket.address.getPort()});
            replaced = true;
        }
        if (!replaced) return error.NoLoopbackCandidate;
        return output.toOwnedSlice(allocator);
    }

    fn connect(self: *Relay, client: *Connection, server: *Connection) !void {
        const allocator = std.testing.allocator;
        try client.start();
        const started = std.Io.Clock.awake.now(self.io);
        while (!client.ready() or !server.ready()) {
            if (started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() > 10_000) return error.Timeout;
            for ([_]*Connection{ client, server }, [_]*Connection{ server, client }, [_]bool{ false, true }) |source, destination, from_server| {
                const event = try source.pollNegotiation() orelse continue;
                switch (event) {
                    .signal => |signal| {
                        const rewritten = try self.rewrite(allocator, from_server, signal.data);
                        defer allocator.free(rewritten);
                        var routed = signal;
                        routed.data = rewritten;
                        routed.network_id = if (from_server) "server" else "client";
                        try destination.applySignal(routed);
                    },
                    .message => return error.UnexpectedMessage,
                }
            }
            if (!client.peer.hasPending(true) and !server.peer.hasPending(true))
                try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
        }
    }
};

fn freePort(io: std.Io) !u16 {
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    const probe = try address.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer probe.close(io);
    return probe.address.getPort();
}

fn createServer(io: std.Io, id: u64, port: u16) !*Connection {
    return Connection.create(std.testing.allocator, io, .server, id, "client", .{
        .native = .{
            .disable_trickle = true,
            .bind_address = "127.0.0.1",
            .port_range_begin = port,
            .port_range_end = port,
            .enable_ice_udp_mux = true,
        },
        .allow_anonymous = true,
    });
}

fn createClient(io: std.Io, id: u64) !*Connection {
    return Connection.create(std.testing.allocator, io, .client, id, "server", .{
        .native = .{ .disable_trickle = true, .bind_address = "127.0.0.1" },
    });
}

test "a client that vanished silently does not capture its address from a new mux session" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var relay: Relay = .{ .io = io, .socket = try address.bind(io, .{ .mode = .dgram, .protocol = .udp }) };
    defer relay.socket.close(io);
    try relay.group.concurrent(io, Relay.run, .{&relay});
    defer relay.stop();
    const server_port = try freePort(io);

    const old_server = try createServer(io, 1, server_port);
    defer old_server.destroy();
    {
        const old_client = try createClient(io, 1);
        defer old_client.destroy();
        try relay.connect(old_client, old_server);
        try old_client.send("old", .reliable);
        try std.testing.expectEqualStrings("old", (try receiveDeadline(old_server, std.Io.Clock.awake.now(io))).data);
        relay.blocked.store(true, .release);
    }
    relay.blocked.store(false, .release);
    // The old session must still own the address when the new client arrives.
    try std.testing.expectEqual(nethernet.State.connected, old_server.state());

    for (2..5) |id| {
        const server = try createServer(io, id, server_port);
        defer server.destroy();
        const client = try createClient(io, id);
        defer client.destroy();
        try relay.connect(client, server);

        try client.send("new", .reliable);
        try std.testing.expectEqualStrings("new", (try receiveDeadline(server, std.Io.Clock.awake.now(io))).data);
        try server.send("back", .reliable);
        try std.testing.expectEqualStrings("back", (try receiveDeadline(client, std.Io.Clock.awake.now(io))).data);
    }
}
