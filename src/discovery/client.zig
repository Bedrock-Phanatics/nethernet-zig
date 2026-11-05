const std = @import("std");

const wake = @import("../internal/wakeup.zig");
const Signal = @import("../protocol/signal.zig").Signal;
const codec = @import("codec.zig");
const reliable = @import("reliable.zig");
const ServerData = @import("server_data.zig").ServerData;

pub const default_port = 7551;

/// Vanilla forgets a peer's address a minute after its last response or message, and a listed
/// world five seconds after its last response.
const address_lifetime_ms = 60_000;
const response_lifetime_ms = 5_000;
/// Request sources can be spoofed, so replies are capped to keep the port from amplifying floods.
/// Vanilla asks every two seconds, so this still serves over a hundred clients at once.
const maximum_replies_per_second = 64;

pub const RateLimit = struct {
    rate: u32,
    tokens: u32 = 0,
    refilled: ?std.Io.Timestamp = null,

    /// Always true when `rate` is 0.
    pub fn take(self: *RateLimit, io: std.Io) bool {
        if (self.rate == 0) return true;
        if (self.tokens == 0) {
            const now = std.Io.Clock.awake.now(io);
            const elapsed: u64 = if (self.refilled) |last| @intCast(@max(last.durationTo(now).toMilliseconds(), 0)) else 1000;
            const refill = @min(@as(u64, self.rate), elapsed * self.rate / 1000);
            if (refill == 0) return false;
            self.tokens = @intCast(refill);
            self.refilled = now;
        }
        self.tokens -= 1;
        return true;
    }
};

pub const Options = struct {
    network_id: u64 = 0,
    maximum_servers: u32 = 1024,
    broadcast_endpoint: ?std.Io.net.IpAddress = null,
    /// A server that only answers never reads other servers' responses, so it can skip storing them.
    keep_responses: bool = true,
};

pub const Known = struct {
    endpoint: std.Io.net.IpAddress,
    last_seen: std.Io.Timestamp,
    /// The world this peer advertised in the last five seconds, if any.
    response: ?[]u8 = null,
    responded: std.Io.Timestamp = .zero,
};

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

    wakeup: wake.Wakeup = .{},
    consumed: std.Io.Event = .unset,
    receive_group: std.Io.Group = .init,
    receive_mutex: std.Io.Mutex = .init,
    operation_active: bool = false,
    incoming: ?std.Io.net.IncomingMessage = null,
    receive_error: ?anyerror = null,
    subscriber: ?*wake.Wakeup = null,

    last_tick: std.Io.Timestamp,
    network_name: [20]u8 = undefined,
    closed: bool = false,

    replies: RateLimit = .{ .rate = maximum_replies_per_second },
    reliable_windows: reliable.Windows = .{},
    malformed_datagrams: u64 = 0,
    dropped_servers: u64 = 0,
    dropped_replies: u64 = 0,

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

        const socket = try @import("socket.zig").bind(io, address);
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
        if (encoded.len > codec.maximum_response_data) return error.MessageTooLarge;
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

        var iterator = self.servers.iterator();

        while (iterator.next()) |entry| {
            const known = entry.value_ptr;
            const expired = known.last_seen.durationTo(now).toMilliseconds() >= address_lifetime_ms;
            const stale = known.responded.durationTo(now).toMilliseconds() > response_lifetime_ms;
            if (known.response != null and (expired or stale)) {
                self.allocator.free(known.response.?);
                known.response = null;
            }
            if (expired) _ = self.servers.remove(entry.key_ptr.*);
        }
        self.reliable_windows.expire(now);

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

        if (decoded.packet == .request) {
            // Requests can come from spoofed sources, so a reply that fails to send is dropped
            const data = self.advertisement orelse return null;
            if (self.replies.take(self.io))
                self.write(.{ .response = data }, message.from) catch {}
            else
                self.dropped_replies +|= 1;
            return null;
        }

        switch (decoded.packet) {
            // We send no reliable packets, so there is nothing to acknowledge.
            .acknowledgement => return null,
            // One addressed elsewhere must not take a receive window.
            .reliable => |packet| if (packet.recipient_id != self.id) return null,
            else => {},
        }

        // Like vanilla, only responses and messages from a nonzero sender locate a peer.
        if (decoded.sender_id == 0) return null;

        if (!self.servers.contains(decoded.sender_id) and
            self.servers.count() >= self.options.maximum_servers)
        {
            self.dropped_servers +|= 1;
            return null;
        }

        const entry = self.servers.getOrPutAssumeCapacity(decoded.sender_id);
        const now = std.Io.Clock.awake.now(self.io);
        if (!entry.found_existing) entry.value_ptr.* = .{ .endpoint = message.from, .last_seen = now };
        entry.value_ptr.endpoint = message.from;
        entry.value_ptr.last_seen = now;

        switch (decoded.packet) {
            .request, .acknowledgement => unreachable,

            .response => |data| if (self.options.keep_responses) {
                try replaceResponse(self.allocator, entry.value_ptr, data);
                entry.value_ptr.responded = now;
            },

            .message => |packet| if (packet.recipient_id == self.id)
                return self.parseSignal(decoded.sender_id, packet.data),

            .reliable => |packet| {
                const outcome = self.reliable_windows.receive(decoded.sender_id, packet.nonce, packet.sequence, now);
                if (outcome == .stale) return null;
                // Retransmissions are acknowledged again, since the first acknowledgement may have been lost.
                self.acknowledge(message.from, decoded.sender_id, packet);
                if (outcome == .deliver) return self.parseSignal(decoded.sender_id, packet.data);
            },
        }

        return null;
    }

    fn parseSignal(self: *Discovery, sender_id: u64, data: []const u8) !?Signal {
        if (data.len == 0 or std.mem.eql(u8, data, "Ping")) return null;

        var signal = Signal.parse(data) catch {
            self.malformed_datagrams +|= 1;
            return null;
        };
        signal.network_id = try std.fmt.bufPrint(&self.network_name, "{d}", .{sender_id});
        return signal;
    }

    /// Uses its own buffers, as the shared ones still hold the message being delivered.
    fn acknowledge(self: *Discovery, address: std.Io.net.IpAddress, sender_id: u64, packet: codec.Reliable) void {
        var scratch: [48]u8 = undefined;
        var wire: [80]u8 = undefined;
        const encoded = self.codec.encode(.{ .acknowledgement = .{
            .recipient_id = sender_id,
            .nonce = packet.nonce,
            .sequence = packet.sequence,
        } }, self.id, &scratch, &wire) catch unreachable;
        // Like replies to requests, the source may be spoofed, so a failed send is dropped.
        self.socket.send(self.io, &address, encoded) catch {};
    }

    pub fn beginOperation(self: *Discovery) !void {
        self.receive_mutex.lockUncancelable(self.io);
        defer self.receive_mutex.unlock(self.io);
        if (self.operation_active) return error.OperationInProgress;
        self.operation_active = true;
    }

    pub fn endOperation(self: *Discovery) void {
        self.receive_mutex.lockUncancelable(self.io);
        defer self.receive_mutex.unlock(self.io);
        self.operation_active = false;
        self.notify();
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
            const token = self.wakeup.prepare();
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
            try self.wakeup.wait(self.io, token, timeout);
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

fn replaceResponse(allocator: std.mem.Allocator, known: *Known, data: []const u8) !void {
    if (known.response) |old| {
        if (std.mem.eql(u8, old, data)) return;
    }

    const copy = try allocator.dupe(u8, data);
    if (known.response) |old| allocator.free(old);
    known.response = copy;
}

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

    try client.beginOperation();
    try std.testing.expectError(error.OperationInProgress, client.beginOperation());
    client.endOperation();
    try client.beginOperation();
    client.endOperation();

    try server.setServerData(.{ .server_name = "Zig" });
    try client.request(server.socket.address);

    _ = try server.poll(1000);
    try std.testing.expectEqual(@as(u32, 0), server.servers.count());
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
    try std.testing.expect(server.servers.contains(1));

    // A listed world drops out five seconds after its last response, its address only after a minute.
    client.options.broadcast_endpoint = null;
    const known = client.servers.getPtr(2).?;
    known.responded = known.responded.subDuration(.fromMilliseconds(5001));
    client.last_tick = client.last_tick.subDuration(.fromMilliseconds(2000));
    try client.tick();
    try std.testing.expect(known.response == null);
    known.last_seen = known.last_seen.subDuration(.fromMilliseconds(60_000));
    client.last_tick = client.last_tick.subDuration(.fromMilliseconds(2000));
    try client.tick();
    try std.testing.expect(!client.servers.contains(2));

    server.close();
    server.close();
}

fn expectAcknowledgement(discovery: *Discovery, nonce: u64, sequence: u64) !void {
    const message = try discovery.receive(1000);
    defer discovery.consumed.set(discovery.io);
    const decoded = try discovery.codec.decode(message.data, discovery.plain());
    try std.testing.expectEqual(@as(u64, 2), decoded.sender_id);
    try std.testing.expectEqual(codec.Acknowledgement{
        .recipient_id = 1,
        .nonce = nonce,
        .sequence = sequence,
    }, decoded.packet.acknowledgement);
}

test "reliable LAN signals are acknowledged every time and delivered once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");

    const server = try Discovery.listen(allocator, io, address, .{ .network_id = 2 });
    defer server.destroy();
    const client = try Discovery.listen(allocator, io, address, .{ .network_id = 1 });
    defer client.destroy();

    const offer: codec.Packet = .{ .reliable = .{
        .recipient_id = 2,
        .nonce = 5,
        .sequence = 1,
        .data = "CONNECTREQUEST 9 v=0\r\n",
    } };
    try client.write(offer, server.socket.address);
    const signal = (try server.poll(1000)).?;
    try std.testing.expectEqualStrings(Signal.offer, signal.kind);
    try std.testing.expectEqual(@as(u64, 9), signal.connection_id);
    try std.testing.expectEqualStrings("1", signal.network_id);
    try std.testing.expectEqualStrings("v=0\r\n", signal.data);
    try std.testing.expect(server.servers.contains(1));
    try expectAcknowledgement(client, 5, 1);

    // A retransmission is acknowledged again but not delivered twice.
    try client.write(offer, server.socket.address);
    try std.testing.expectEqual(null, try server.poll(1000));
    try expectAcknowledgement(client, 5, 1);

    // Filler is acknowledged too, and later sequences still arrive.
    try client.write(.{ .reliable = .{ .recipient_id = 2, .nonce = 5, .sequence = 3, .data = "Ping" } }, server.socket.address);
    try std.testing.expectEqual(null, try server.poll(1000));
    try expectAcknowledgement(client, 5, 3);
    try client.write(.{ .reliable = .{
        .recipient_id = 2,
        .nonce = 5,
        .sequence = 2,
        .data = "CANDIDATEADD 9 candidate:1 1 udp 1 127.0.0.1 5 typ host",
    } }, server.socket.address);
    try std.testing.expectEqualStrings(Signal.candidate, (try server.poll(1000)).?.kind);
    try expectAcknowledgement(client, 5, 2);

    // Packets for another network and stray acknowledgements are dropped silently.
    try client.write(.{ .reliable = .{ .recipient_id = 3, .nonce = 5, .sequence = 4, .data = "Ping" } }, server.socket.address);
    try std.testing.expectEqual(null, try server.poll(1000));
    try client.write(.{ .acknowledgement = .{ .recipient_id = 2, .nonce = 5, .sequence = 4 } }, server.socket.address);
    try std.testing.expectEqual(null, try server.poll(1000));
    try std.testing.expectError(error.Timeout, client.receive(100));
}

test "identical discovery responses do not allocate again" {
    var known: Known = .{
        .endpoint = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:7551"),
        .last_seen = std.Io.Clock.awake.now(std.testing.io),
        .response = try std.testing.allocator.dupe(u8, "same"),
    };
    defer std.testing.allocator.free(known.response.?);

    try replaceResponse(std.testing.failing_allocator, &known, "same");
    try std.testing.expectEqualStrings("same", known.response.?);
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

test {
    _ = reliable;
}
