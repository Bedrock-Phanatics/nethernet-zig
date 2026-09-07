const std = @import("std");
const codec = @import("discovery_codec.zig");
const Signal = @import("signal.zig").Signal;
const ServerData = @import("server_data.zig").ServerData;
pub const default_port = 7551;
pub const Options = struct {
    network_id: u64 = 0,
    maximum_servers: u32 = 1024,
    broadcast_endpoint: ?std.Io.net.IpAddress = null,
};
pub const Known = struct {
    endpoint: std.Io.net.IpAddress,
    last_seen: std.Io.Timestamp,
    response: ?[]u8 = null,
};

/// Single application owner. poll drives discovery, expiration and signaling;
/// no hidden thread is created. Map responses borrow owned cache memory until
/// refreshed/expired/destroyed. Signals borrow scratch until the next poll/send.
pub const Discovery = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    socket: std.Io.net.Socket,
    id: u64,
    options: Options,
    servers: std.AutoHashMapUnmanaged(u64, Known) = .empty,
    codec: codec.Codec,
    buffers: []u8,
    advertisement: ?[]u8 = null,
    last_tick: std.Io.Timestamp,
    network_name: [20]u8 = undefined,
    closed: bool = false,
    malformed_datagrams: u64 = 0,
    dropped_servers: u64 = 0,

    pub fn listen(a: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress, options: Options) !*Discovery {
        if (options.maximum_servers == 0) return error.InvalidConfiguration;
        const self = try a.create(Discovery);
        errdefer a.destroy(self);
        const buffers = try a.alloc(u8, codec.maximum_datagram * 3);
        errdefer a.free(buffers);
        const socket = try address.bind(io, .{ .mode = .dgram, .protocol = .udp, .allow_broadcast = true });
        errdefer socket.close(io);
        var actual = options;
        if (actual.broadcast_endpoint == null and socket.address.getPort() != default_port) actual.broadcast_endpoint = try std.Io.net.IpAddress.parseLiteral("255.255.255.255:7551");
        var random: [8]u8 = undefined;
        io.random(&random);
        self.* = .{ .allocator = a, .io = io, .socket = socket, .id = if (options.network_id == 0) std.mem.readInt(u64, &random, .little) else options.network_id, .options = actual, .buffers = buffers, .codec = codec.Codec.init(), .last_tick = std.Io.Clock.awake.now(io) };
        try self.servers.ensureTotalCapacity(a, options.maximum_servers);
        return self;
    }
    pub fn close(self: *Discovery) void {
        if (self.closed) return;
        self.closed = true;
        self.socket.close(self.io);
    }
    pub fn destroy(self: *Discovery) void {
        self.close();
        var it = self.servers.valueIterator();
        while (it.next()) |known| if (known.response) |data| self.allocator.free(data);
        self.servers.deinit(self.allocator);
        if (self.advertisement) |data| self.allocator.free(data);
        self.allocator.free(self.buffers);
        self.allocator.destroy(self);
    }
    pub fn setServerData(self: *Discovery, data: ServerData) !void {
        const encoded = try data.encode(self.plain());
        const owned = try self.allocator.dupe(u8, encoded);
        if (self.advertisement) |old| self.allocator.free(old);
        self.advertisement = owned;
    }
    pub fn setPongData(self: *Discovery, pong: []const u8) !void {
        try self.setServerData(try ServerData.fromPong(pong));
    }
    pub fn request(self: *Discovery, address: std.Io.net.IpAddress) !void {
        try self.write(.request, address);
    }
    pub fn send(self: *Discovery, signal: Signal) !void {
        const recipient = std.fmt.parseInt(u64, signal.network_id, 10) catch return error.InvalidNetworkId;
        const known = self.servers.get(recipient) orelse return error.UnknownNetworkId;
        const data = try signal.encode(self.input());
        try self.write(.{ .message = .{ .recipient_id = recipient, .data = data } }, known.endpoint);
    }
    pub fn tick(self: *Discovery) !void {
        if (self.closed) return error.ConnectionClosed;
        const now = std.Io.Clock.awake.now(self.io);
        if (self.last_tick.durationTo(now).toMilliseconds() < 2000) return;
        self.last_tick = now;
        // Removal does not invalidate the hash map's storage or iterator.
        var it = self.servers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_seen.durationTo(now).toMilliseconds() > 15000) {
                if (entry.value_ptr.response) |data| self.allocator.free(data);
                _ = self.servers.remove(entry.key_ptr.*);
            }
        }
        if (self.options.broadcast_endpoint) |address| try self.request(address);
    }
    pub fn poll(self: *Discovery, timeout_ms: u32) !?Signal {
        try self.tick();
        const message = self.receive(timeout_ms) catch |err| switch (err) {
            error.Timeout => return null,
            else => return err,
        };
        if (message.flags.trunc) {
            self.malformed_datagrams +|= 1;
            return null;
        }
        const decoded = self.codec.decode(message.data, self.plain()) catch {
            self.malformed_datagrams +|= 1;
            return null;
        };
        if (decoded.sender_id == self.id) return null;
        if (!self.servers.contains(decoded.sender_id) and self.servers.count() >= self.options.maximum_servers) {
            self.dropped_servers +|= 1;
            return null;
        }
        const entry = self.servers.getOrPutAssumeCapacity(decoded.sender_id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .endpoint = message.from, .last_seen = std.Io.Clock.awake.now(self.io) };
        entry.value_ptr.endpoint = message.from;
        entry.value_ptr.last_seen = std.Io.Clock.awake.now(self.io);
        switch (decoded.packet) {
            .request => if (self.advertisement) |data| {
                try self.write(.{ .response = data }, message.from);
            },
            .response => |data| {
                const copy = try self.allocator.dupe(u8, data);
                if (entry.value_ptr.response) |old| self.allocator.free(old);
                entry.value_ptr.response = copy;
            },
            .message => |packet| {
                if (packet.recipient_id != self.id or packet.data.len == 0 or std.mem.eql(u8, packet.data, "Ping")) return null;
                var signal = Signal.parse(packet.data) catch {
                    self.malformed_datagrams +|= 1;
                    return null;
                };
                signal.network_id = try std.fmt.bufPrint(&self.network_name, "{d}", .{decoded.sender_id});
                return signal;
            },
        }
        return null;
    }
    fn receive(self: *Discovery, timeout_ms: u32) !std.Io.net.IncomingMessage {
        return self.socket.receiveTimeout(self.io, self.input(), .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }) catch |err| switch (err) {
            // Zig 0.16 Threaded on Windows does not support concurrent batches
            // for UDP receive. Its cancellable blocking receive does work.
            error.ConcurrencyUnavailable => {
                const Result = union(enum) { packet: std.Io.net.Socket.ReceiveError!std.Io.net.IncomingMessage, timeout: std.Io.Cancelable!void };
                var results: [2]Result = undefined;
                var select = std.Io.Select(Result).init(self.io, &results);
                defer select.cancelDiscard();
                try select.concurrent(.packet, std.Io.net.Socket.receive, .{ &self.socket, self.io, self.input() });
                try select.concurrent(.timeout, std.Io.sleep, .{ self.io, std.Io.Duration.fromMilliseconds(timeout_ms), .awake });
                return switch (try select.await()) {
                    .packet => |result| result,
                    .timeout => |result| {
                        try result;
                        return error.Timeout;
                    },
                };
            },
            else => return err,
        };
    }
    fn write(self: *Discovery, packet: codec.Packet, address: std.Io.net.IpAddress) !void {
        if (self.closed) return error.ConnectionClosed;
        const wire = try self.codec.encode(packet, self.id, self.plain(), self.output());
        if (wire.len > 65507) return error.MessageTooLarge;
        try self.socket.send(self.io, &address, wire);
    }
    fn input(self: *Discovery) []u8 {
        return self.buffers[0..codec.maximum_datagram];
    }
    fn plain(self: *Discovery) []u8 {
        return self.buffers[codec.maximum_datagram .. codec.maximum_datagram * 2];
    }
    fn output(self: *Discovery) []u8 {
        return self.buffers[codec.maximum_datagram * 2 ..];
    }
};

test "UDP discovery and addressed signaling over loopback" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    const server = try Discovery.listen(a, io, address, .{ .network_id = 2 });
    defer server.destroy();
    const client = try Discovery.listen(a, io, address, .{ .network_id = 1 });
    defer client.destroy();
    try server.setServerData(.{ .server_name = "Zig" });
    try client.request(server.socket.address);
    _ = try server.poll(1000);
    _ = try client.poll(1000);
    const data = try ServerData.decode(client.servers.get(2).?.response.?);
    try std.testing.expectEqualStrings("Zig", data.server_name);
    try client.send(.{ .kind = Signal.offer, .connection_id = 9, .network_id = "2", .data = "v=0\r\n" });
    const signal = (try server.poll(1000)).?;
    try std.testing.expectEqualStrings("1", signal.network_id);
    try std.testing.expectEqualStrings("v=0\r\n", signal.data);
    server.close();
    server.close();
}

fn creationFailureScenario(a: std.mem.Allocator) !void {
    const discovery = try Discovery.listen(a, std.testing.io, try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"), .{ .maximum_servers = 2 });
    defer discovery.destroy();
    try discovery.setServerData(.{ .server_name = "allocation failure" });
}
test "discovery creation and advertisement allocation failures clean up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, creationFailureScenario, .{});
}
