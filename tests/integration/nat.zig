const std = @import("std");
const nethernet = @import("nethernet");
const Connection = nethernet.Connection;
const IpAddress = std.Io.net.IpAddress;
const Socket = std.Io.net.Socket;

/// A 1:1 port forward from 127.0.0.2 to the same port on 127.0.0.1. Like a real NAT it gives every client
/// a mapping of its own, so the server only ever sees the NAT and can reach a client through it alone.
const Nat = struct {
    const maximum_forwards = 4;
    const maximum_mappings = 32;
    const Mapping = struct { client: IpAddress, forward: usize, inner: Socket };

    io: std.Io,
    forwards: [maximum_forwards]Socket = undefined,
    forward_count: usize = 0,
    mutex: std.Io.Mutex = .init,
    mappings: [maximum_mappings]Mapping = undefined,
    mapping_count: usize = 0,
    closing: std.atomic.Value(bool) = .init(false),
    group: std.Io.Group = .init,
    inbound: std.atomic.Value(u32) = .init(0),
    outbound: std.atomic.Value(u32) = .init(0),
    failure: std.atomic.Value(bool) = .init(false),

    /// Null when 127.0.0.2 isn't usable here, or no run of free ports turned up.
    fn open(io: std.Io, count: usize) !?*Nat {
        const self = try std.testing.allocator.create(Nat);
        self.* = .{ .io = io };
        var random = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.awake.now(io).nanoseconds & 0xffff_ffff));
        attempts: for (0..32) |_| {
            const base = 20000 + random.random().uintLessThan(u16, 40000);
            for (0..count) |index| {
                const address: IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 2 }, .port = base + @as(u16, @intCast(index)) } };
                self.forwards[index] = address.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err| {
                    for (self.forwards[0..index]) |socket| socket.close(io);
                    if (err == error.AddressUnavailable) break :attempts;
                    continue :attempts;
                };
            }
            self.forward_count = count;
            errdefer self.close();
            for (0..count) |index| try self.group.concurrent(io, run, .{ self, false, index });
            return self;
        }
        std.testing.allocator.destroy(self);
        return null;
    }

    fn close(self: *Nat) void {
        // Cancelling a receive blocked on Windows can hang, so each socket gets a datagram that ends its loop.
        self.mutex.lockUncancelable(self.io);
        self.closing.store(true, .release);
        self.mutex.unlock(self.io);
        const waker_address: IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 2 }, .port = 0 } };
        if (waker_address.bind(self.io, .{ .mode = .dgram, .protocol = .udp })) |waker| {
            defer waker.close(self.io);
            for (self.forwards[0..self.forward_count]) |socket| waker.send(self.io, &socket.address, "x") catch {};
            for (self.mappings[0..self.mapping_count]) |mapping| waker.send(self.io, &mapping.inner.address, "x") catch {};
            self.group.await(self.io) catch {};
        } else |_| self.group.cancel(self.io);
        for (self.forwards[0..self.forward_count]) |socket| socket.close(self.io);
        for (self.mappings[0..self.mapping_count]) |mapping| mapping.inner.close(self.io);
        std.testing.allocator.destroy(self);
    }

    fn firstPort(self: *const Nat) u16 {
        return self.forwards[0].address.getPort();
    }

    fn lastPort(self: *const Nat) u16 {
        return self.forwards[self.forward_count - 1].address.getPort();
    }

    fn run(self: *Nat, inner: bool, index: usize) std.Io.Cancelable!void {
        (if (inner) self.innerLoop(index) else self.forwardLoop(index)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => self.failure.store(true, .release),
        };
    }

    /// Null once closing. Windows reports an ICMP unreachable from a closed session on the next receive, a NAT
    /// just drops it.
    fn receive(self: *Nat, socket: *const Socket, buffer: []u8) !?std.Io.net.IncomingMessage {
        while (true) {
            const message = socket.receive(self.io, buffer) catch |err| switch (err) {
                error.PortUnreachable => continue,
                else => return err,
            };
            return if (self.closing.load(.acquire)) null else message;
        }
    }

    fn forwardLoop(self: *Nat, forward: usize) !void {
        var buffer: [2048]u8 = undefined;
        const server: IpAddress = .{ .ip4 = .loopback(self.forwards[forward].address.getPort()) };
        while (true) {
            const message = try self.receive(&self.forwards[forward], &buffer) orelse return;
            const inner = try self.mappingFor(message.from, forward) orelse return;
            inner.send(self.io, &server, message.data) catch continue;
            _ = self.inbound.fetchAdd(1, .monotonic);
        }
    }

    fn innerLoop(self: *Nat, index: usize) !void {
        var buffer: [2048]u8 = undefined;
        const mapping = self.mappings[index];
        while (true) {
            const message = try self.receive(&mapping.inner, &buffer) orelse return;
            self.forwards[mapping.forward].send(self.io, &mapping.client, message.data) catch continue;
            _ = self.outbound.fetchAdd(1, .monotonic);
        }
    }

    fn mappingFor(self: *Nat, client: IpAddress, forward: usize) !?*const Socket {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closing.load(.acquire)) return null;
        for (self.mappings[0..self.mapping_count]) |*mapping| {
            if (mapping.forward == forward and mapping.client.eql(&client)) return &mapping.inner;
        }
        if (self.mapping_count == maximum_mappings) return error.NatTableFull;
        const any: IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 2 }, .port = 0 } };
        const index = self.mapping_count;
        self.mappings[index] = .{
            .client = client,
            .forward = forward,
            .inner = try any.bind(self.io, .{ .mode = .dgram, .protocol = .udp }),
        };
        self.mapping_count += 1;
        try self.group.concurrent(self.io, run, .{ self, true, index });
        return &self.mappings[index].inner;
    }
};

/// Keeps the candidates that name `reachable`, or none.
fn onlyCandidates(allocator: std.mem.Allocator, sdp: []const u8, reachable: ?[]const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, sdp, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "a=candidate:") and
            (reachable == null or std.mem.indexOf(u8, line, reachable.?) == null)) continue;
        try output.appendSlice(allocator, line);
        try output.appendSlice(allocator, "\r\n");
    }
    return output.toOwnedSlice(allocator);
}

fn post(allocator: std.mem.Allocator, io: std.Io, url: []const u8, body: []const u8, answer: *std.Io.Writer) !std.http.Status {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .content_type = .{ .override = "application/sdp" } },
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.len };
    var writer = try request.sendBodyUnflushed(&.{});
    try writer.writer.writeAll(body);
    try writer.end();
    try request.connection.?.flush();

    var response = try request.receiveHead(&.{});
    var transfer: [64]u8 = undefined;
    _ = try response.reader(&transfer).streamRemaining(answer);
    return response.head.status;
}

fn expectAdvertised(answer: []const u8, nat: *const Nat) !void {
    var host: ?u16 = null;
    var advertised: ?u16 = null;
    var lines = std.mem.tokenizeAny(u8, answer, "\r\n");
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "a=candidate:")) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        for (0..4) |_| _ = fields.next();
        const address = fields.next().?;
        const port = try std.fmt.parseInt(u16, fields.next().?, 10);
        _ = fields.next();
        const kind = fields.next().?;
        if (std.mem.eql(u8, address, "127.0.0.1") and std.mem.eql(u8, kind, "host") and host == null) {
            host = port;
        } else if (std.mem.eql(u8, address, "127.0.0.2") and std.mem.eql(u8, kind, "srflx") and advertised == null) {
            advertised = port;
        } else return error.UnexpectedCandidate;
    }
    // The gathered host stays as it was, and the NAT address goes out on its socket's port.
    try std.testing.expectEqual(host.?, advertised.?);
    try std.testing.expect(host.? >= nat.firstPort() and host.? <= nat.lastPort());
    var media: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, answer, try std.fmt.bufPrint(&media, "\r\nm=application {d} ", .{host.?})) != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\r\nc=IN IP4 127.0.0.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\r\na=end-of-candidates\r\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, answer, "a=fingerprint:"));
}

/// Dials like `dialEndpoint`, but the offer names no candidates, so the server can only reach the
/// client by answering what reached it through the NAT.
fn join(allocator: std.mem.Allocator, io: std.Io, origin: []const u8, id: u64, nat: *const Nat) anyerror!*Connection {
    const client = try Connection.create(allocator, io, .client, id, "server", .{
        .native = .{ .disable_trickle = true, .bind_address = "127.0.0.1" },
    });
    errdefer client.destroy();
    try client.start();

    var answered = false;
    while (!client.ready()) {
        const token = client.prepareWait();
        if (try client.pollNegotiation()) |event| {
            if (answered or event != .signal) return error.UnexpectedEvent;
            const offer = try onlyCandidates(allocator, event.signal.data, null);
            defer allocator.free(offer);
            const url = try std.fmt.allocPrint(allocator, "{s}/v1/join/client-{d}", .{ origin, id });
            defer allocator.free(url);
            var answer: std.Io.Writer.Allocating = .init(allocator);
            defer answer.deinit();
            try std.testing.expectEqual(std.http.Status.ok, try post(allocator, io, url, offer, &answer.writer));
            try expectAdvertised(answer.written(), nat);
            // The private host is out of reach from beyond a real NAT, so the client only takes the NAT address.
            const reachable = try onlyCandidates(allocator, answer.written(), " 127.0.0.2 ");
            defer allocator.free(reachable);
            // The client verifies the server's identity, so this also proves adding candidates kept it valid.
            try client.applySignal(.{ .kind = nethernet.Signal.answer, .connection_id = id, .network_id = "server", .data = reachable });
            answered = true;
        }
        try client.wait(token, true);
    }
    return client;
}

fn expectThroughNat(server: *Connection) !void {
    var local: [128]u8 = undefined;
    var remote: [128]u8 = undefined;
    const selected = (try server.selectedIceAddresses(&local, &remote)) orelse return error.NoSelectedPair;
    try std.testing.expect(std.mem.startsWith(u8, selected.remote, "127.0.0.2:"));
}

fn exchange(client: *Connection, server: *Connection) !void {
    try client.send("through the nat", .reliable);
    try std.testing.expectEqualStrings("through the nat", (try server.receive()).data);
    try server.send("and back", .reliable);
    try std.testing.expectEqualStrings("and back", (try client.receive()).data);
}

test "HTTP joins cross a 1:1 NAT through advertised server-reflexive candidates" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    for ([_]bool{ true, false }) |mux| {
        const nat = try Nat.open(io, if (mux) 1 else 4) orelse return error.SkipZigTest;
        defer nat.close();

        const listener = try nethernet.EndpointListener.listen(allocator, io, try IpAddress.parseLiteral("127.0.0.1:0"), .{
            .connection = .{
                .allow_anonymous = true,
                .native = .{
                    .bind_address = "127.0.0.1",
                    .port_range_begin = nat.firstPort(),
                    .port_range_end = nat.lastPort(),
                    .enable_ice_udp_mux = mux,
                },
            },
            .advertise_addresses = &.{"127.0.0.2"},
        });
        defer listener.destroy();
        var origin_buffer: [64]u8 = undefined;
        const origin = try std.fmt.bufPrint(&origin_buffer, "http://127.0.0.1:{d}", .{listener.server.socket.address.getPort()});

        // Joins negotiate at once and stay open together, each on its own NAT mapping.
        var clients: [3]*Connection = undefined;
        var joins: [clients.len]std.Io.Future(anyerror!*Connection) = undefined;
        for (&joins, 0..) |*future, index| future.* = try io.concurrent(join, .{ allocator, io, origin, index + 1, nat });
        var joined: usize = 0;
        defer for (clients[0..joined]) |client| client.destroy();
        var failure: ?anyerror = null;
        for (&joins) |*future| {
            if (future.await(io)) |client| {
                clients[joined] = client;
                joined += 1;
            } else |err| failure = err;
        }
        if (failure) |err| return err;

        var servers: [clients.len]*Connection = undefined;
        for (&servers) |*server| server.* = try listener.accept();
        defer for (servers) |server| server.destroy();
        for (servers) |server| try expectThroughNat(server);
        for (clients) |client| {
            var name: [32]u8 = undefined;
            const path_id = try std.fmt.bufPrint(&name, "client-{d}", .{client.id});
            const server = for (servers) |server| {
                if (std.mem.eql(u8, server.remoteAddress().network_id, path_id)) break server;
            } else return error.ServerNotFound;
            try exchange(client, server);
        }

        for (0..4) |cycle| {
            const client = try join(allocator, io, origin, 100 + cycle, nat);
            defer client.destroy();
            const server = try listener.accept();
            defer server.destroy();
            try expectThroughNat(server);
            try exchange(client, server);
        }

        try std.testing.expect(!nat.failure.load(.acquire));
        try std.testing.expect(nat.inbound.load(.acquire) > 0 and nat.outbound.load(.acquire) > 0);
    }
}

test "an advertised family the server never gathered is skipped instead of guessed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try nethernet.EndpointListener.listen(allocator, io, try IpAddress.parseLiteral("127.0.0.1:0"), .{
        .connection = .{ .allow_anonymous = true, .native = .{ .bind_address = "127.0.0.1" } },
        .advertise_addresses = &.{"2001:db8::7"},
    });
    defer listener.destroy();

    const offer = try nethernet.Peer.create(allocator, io, .{ .disable_trickle = true, .bind_address = "127.0.0.1" });
    defer offer.destroy();
    try offer.offer();
    const buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(buffer);
    const sdp = while (true) {
        if (try offer.poll(buffer)) |event| break event.offer;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    };

    var url: [64]u8 = undefined;
    var answer: std.Io.Writer.Allocating = .init(allocator);
    defer answer.deinit();
    try std.testing.expectEqual(std.http.Status.ok, try post(
        allocator,
        io,
        try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/v1/join/1", .{listener.server.socket.address.getPort()}),
        sdp,
        &answer.writer,
    ));
    try std.testing.expect(std.mem.indexOf(u8, answer.written(), " 127.0.0.1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer.written(), "2001:db8::7") == null);
    try std.testing.expectError(error.InvalidAdvertiseAddress, nethernet.EndpointListener.listen(
        allocator,
        io,
        try IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .connection = .{ .allow_anonymous = true }, .advertise_addresses = &.{"203.0.113.7:19132"} },
    ));
}
