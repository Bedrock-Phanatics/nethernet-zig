const std = @import("std");

const wake = @import("wakeup.zig");
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

/// Call poll from one owner. Returned responses and signals use internal storage.
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

    // One packet at a time. The reader waits until decoding finishes.
    wakeup: wake.Wakeup = .{},
    consumed: std.Io.Event = .unset,
    receive_group: std.Io.Group = .init,
    receive_mutex: std.Io.Mutex = .init,
    incoming: ?std.Io.net.IncomingMessage = null,
    receive_error: ?anyerror = null,
    subscriber: ?*wake.Wakeup = null,

    last_tick: std.Io.Timestamp,
    network_name: [20]u8 = undefined,
    closed: bool = false,

    malformed_datagrams: u64 = 0,
    dropped_servers: u64 = 0,

    pub fn listen(
        allocator: std.mem.Allocator,
        io: std.Io,
        address: std.Io.net.IpAddress,
        options: Options,
    ) !*Discovery {
        if (options.maximum_servers == 0) {
            return error.InvalidConfiguration;
        }

        const self = try allocator.create(Discovery);
        errdefer allocator.destroy(self);

        const buffers = try allocator.alloc(u8, codec.maximum_datagram * 4);
        errdefer allocator.free(buffers);

        const socket = try address.bind(io, .{
            .mode = .dgram,
            .protocol = .udp,
            .allow_broadcast = true,
        });
        errdefer socket.close(io);

        var actual_options = options;

        if (actual_options.broadcast_endpoint == null and
            socket.address.getPort() != default_port)
        {
            actual_options.broadcast_endpoint =
                try std.Io.net.IpAddress.parseLiteral("255.255.255.255:7551");
        }

        var random: [8]u8 = undefined;
        io.random(&random);

        const network_id = if (options.network_id != 0)
            options.network_id
        else
            std.mem.readInt(u64, &random, .little);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .socket = socket,
            .id = network_id,
            .options = actual_options,
            .codec = codec.Codec.init(),
            .buffers = buffers,
            .last_tick = std.Io.Clock.awake.now(io),
        };

        try self.servers.ensureTotalCapacity(
            allocator,
            options.maximum_servers,
        );

        errdefer self.servers.deinit(allocator);
        try self.receive_group.concurrent(io, receiveWorker, .{self});
        return self;
    }

    pub fn close(self: *Discovery) void {
        if (self.closed) return;

        self.closed = true;
        self.receive_mutex.lockUncancelable(self.io);
        self.notify();
        self.receive_mutex.unlock(self.io);
        self.receive_group.cancel(self.io);
        self.socket.close(self.io);
    }

    pub fn destroy(self: *Discovery) void {
        self.close();

        var iterator = self.servers.valueIterator();
        while (iterator.next()) |known| {
            if (known.response) |data| {
                self.allocator.free(data);
            }
        }

        self.servers.deinit(self.allocator);

        if (self.advertisement) |data| {
            self.allocator.free(data);
        }

        self.allocator.free(self.buffers);
        self.allocator.destroy(self);
    }

    pub fn setServerData(self: *Discovery, data: ServerData) !void {
        const encoded = try data.encode(self.plain());
        const owned = try self.allocator.dupe(u8, encoded);

        if (self.advertisement) |old| {
            self.allocator.free(old);
        }

        self.advertisement = owned;
    }

    pub fn setPongData(self: *Discovery, pong: []const u8) !void {
        try self.setServerData(try ServerData.fromPong(pong));
    }

    pub fn request(
        self: *Discovery,
        address: std.Io.net.IpAddress,
    ) !void {
        try self.write(.request, address);
    }

    pub fn send(self: *Discovery, signal: Signal) !void {
        const recipient = std.fmt.parseInt(
            u64,
            signal.network_id,
            10,
        ) catch return error.InvalidNetworkId;

        const known = self.servers.get(recipient) orelse
            return error.UnknownNetworkId;

        const data = try signal.encode(self.input());

        try self.write(
            .{
                .message = .{
                    .recipient_id = recipient,
                    .data = data,
                },
            },
            known.endpoint,
        );
    }

    pub fn tick(self: *Discovery) !void {
        if (self.closed) return error.ConnectionClosed;

        const now = std.Io.Clock.awake.now(self.io);

        if (self.last_tick.durationTo(now).toMilliseconds() < 2000) {
            return;
        }

        self.last_tick = now;

        // Removing the current entry keeps this iterator valid.
        var iterator = self.servers.iterator();

        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_seen.durationTo(now).toMilliseconds() <= 15000) {
                continue;
            }

            if (entry.value_ptr.response) |data| {
                self.allocator.free(data);
            }

            _ = self.servers.remove(entry.key_ptr.*);
        }

        if (self.options.broadcast_endpoint) |address| {
            try self.request(address);
        }
    }

    pub fn poll(self: *Discovery, timeout_ms: u32) !?Signal {
        try self.tick();

        const message = self.receive(timeout_ms) catch |err| switch (err) {
            error.Timeout => return null,
            else => return err,
        };

        defer self.consumed.set(self.io);

        if (message.flags.trunc) {
            self.malformed_datagrams +|= 1;
            return null;
        }

        const decoded = self.codec.decode(
            message.data,
            self.plain(),
        ) catch {
            self.malformed_datagrams +|= 1;
            return null;
        };

        if (decoded.sender_id == self.id) return null;

        if (!self.servers.contains(decoded.sender_id) and
            self.servers.count() >= self.options.maximum_servers)
        {
            self.dropped_servers +|= 1;
            return null;
        }

        const entry = self.servers.getOrPutAssumeCapacity(decoded.sender_id);
        const now = std.Io.Clock.awake.now(self.io);

        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .endpoint = message.from,
                .last_seen = now,
            };
        }

        entry.value_ptr.endpoint = message.from;
        entry.value_ptr.last_seen = now;

        switch (decoded.packet) {
            .request => {
                if (self.advertisement) |data| {
                    try self.write(.{ .response = data }, message.from);
                }
            },

            .response => |data| {
                const copy = try self.allocator.dupe(u8, data);

                if (entry.value_ptr.response) |old| {
                    self.allocator.free(old);
                }

                entry.value_ptr.response = copy;
            },

            .message => |packet| {
                if (packet.recipient_id != self.id or
                    packet.data.len == 0 or
                    std.mem.eql(u8, packet.data, "Ping"))
                {
                    return null;
                }

                var signal = Signal.parse(packet.data) catch {
                    self.malformed_datagrams +|= 1;
                    return null;
                };

                signal.network_id = try std.fmt.bufPrint(
                    &self.network_name,
                    "{d}",
                    .{decoded.sender_id},
                );

                return signal;
            },
        }

        return null;
    }

    pub fn subscribe(self: *Discovery, subscriber: ?*wake.Wakeup) void {
        _ = self.replaceSubscriber(subscriber);
    }

    pub fn replaceSubscriber(self: *Discovery, subscriber: ?*wake.Wakeup) ?*wake.Wakeup {
        self.receive_mutex.lockUncancelable(self.io);
        defer self.receive_mutex.unlock(self.io);
        const previous = self.subscriber;
        self.subscriber = subscriber;
        self.notify();
        return previous;
    }

    pub fn restoreSubscriber(self: *Discovery, temporary: *wake.Wakeup, previous: ?*wake.Wakeup) void {
        self.receive_mutex.lockUncancelable(self.io);
        defer self.receive_mutex.unlock(self.io);
        if (self.subscriber == temporary) self.subscriber = previous;
        self.notify();
    }

    pub fn unsubscribe(self: *Discovery, subscriber: *wake.Wakeup) void {
        self.receive_mutex.lockUncancelable(self.io);
        defer self.receive_mutex.unlock(self.io);
        if (self.subscriber == subscriber) self.subscriber = null;
        self.notify();
    }

    pub fn isSubscribed(self: *Discovery, subscriber: *wake.Wakeup) bool {
        self.receive_mutex.lockUncancelable(self.io);
        defer self.receive_mutex.unlock(self.io);
        return self.subscriber == subscriber;
    }

    fn notify(self: *Discovery) void {
        self.wakeup.signal(self.io);
        if (self.subscriber) |subscriber| subscriber.signal(self.io);
    }

    pub fn tickDeadline(self: *Discovery) std.Io.Timeout {
        return wake.deadline(self.last_tick, 2000);
    }

    fn receiveWorker(self: *Discovery) std.Io.Cancelable!void {
        while (true) {
            self.consumed.reset();
            const message = self.socket.receive(self.io, self.buffers[codec.maximum_datagram * 3 ..]) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                self.receive_mutex.lockUncancelable(self.io);
                self.receive_error = err;
                self.notify();
                self.receive_mutex.unlock(self.io);
                return;
            };
            self.receive_mutex.lockUncancelable(self.io);
            self.incoming = message;
            self.notify();
            self.receive_mutex.unlock(self.io);
            try self.consumed.wait(self.io);
        }
    }

    fn receive(self: *Discovery, timeout_ms: u32) !std.Io.net.IncomingMessage {
        const timeout = wake.deadline(std.Io.Clock.awake.now(self.io), timeout_ms);
        while (true) {
            try self.io.checkCancel();
            self.wakeup.prepare();
            self.receive_mutex.lockUncancelable(self.io);
            const message = self.incoming;
            self.incoming = null;
            const failure = self.receive_error;
            self.receive_mutex.unlock(self.io);
            if (message) |value| return value;
            if (failure) |err| return err;
            if (self.closed) return error.ConnectionClosed;
            if (std.Io.Clock.awake.now(self.io).nanoseconds >= timeout.deadline.raw.nanoseconds)
                return error.Timeout;
            try self.wakeup.wait(self.io, timeout);
        }
    }

    fn write(
        self: *Discovery,
        packet: codec.Packet,
        address: std.Io.net.IpAddress,
    ) !void {
        if (self.closed) return error.ConnectionClosed;

        const wire = try self.codec.encode(
            packet,
            self.id,
            self.plain(),
            self.output(),
        );

        if (wire.len > 65507) {
            return error.MessageTooLarge;
        }

        try self.socket.send(self.io, &address, wire);
    }

    fn input(self: *Discovery) []u8 {
        return self.buffers[0..codec.maximum_datagram];
    }

    fn plain(self: *Discovery) []u8 {
        return self.buffers[codec.maximum_datagram .. codec.maximum_datagram * 2];
    }

    fn output(self: *Discovery) []u8 {
        return self.buffers[codec.maximum_datagram * 2 .. codec.maximum_datagram * 3];
    }
};

test "UDP discovery and addressed signaling over loopback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");

    const server = try Discovery.listen(
        allocator,
        io,
        address,
        .{ .network_id = 2 },
    );
    defer server.destroy();

    const client = try Discovery.listen(
        allocator,
        io,
        address,
        .{ .network_id = 1 },
    );
    defer client.destroy();

    try server.setServerData(.{ .server_name = "Zig" });
    try client.request(server.socket.address);

    _ = try server.poll(1000);
    _ = try client.poll(1000);

    const data = try ServerData.decode(
        client.servers.get(2).?.response.?,
    );
    try std.testing.expectEqualStrings("Zig", data.server_name);

    try client.send(.{
        .kind = Signal.offer,
        .connection_id = 9,
        .network_id = "2",
        .data = "v=0\r\n",
    });

    const signal = (try server.poll(1000)).?;

    try std.testing.expectEqualStrings("1", signal.network_id);
    try std.testing.expectEqualStrings("v=0\r\n", signal.data);

    server.close();
    server.close();
}

fn creationFailureScenario(allocator: std.mem.Allocator) !void {
    const discovery = try Discovery.listen(
        allocator,
        std.testing.io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .maximum_servers = 2 },
    );
    defer discovery.destroy();

    try discovery.setServerData(.{
        .server_name = "allocation failure",
    });
}

test "discovery creation and advertisement allocation failures clean up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        creationFailureScenario,
        .{},
    );
}
