const std = @import("std");
const nethernet = @import("nethernet");

const Listener = nethernet.EndpointListener;

fn origin(allocator: std.mem.Allocator, listener: *Listener, host: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{
        host,
        listener.server.socket.address.getPort(),
    });
}

/// Sends raw bytes, then checks the listener still answers a normal request.
fn survives(listener: *Listener, io: std.Io, garbage: []const u8) !void {
    {
        const stream = try listener.server.socket.address.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        writer.interface.writeAll(garbage) catch {};
        writer.interface.flush() catch {};
    }

    const stream = try listener.server.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("GET /bad HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const prefix = try reader.interface.take(12);
    try std.testing.expectEqualStrings("404", prefix[9..12]);
}

test "listener survives TLS handshakes, truncated requests and malformed HTTP" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .maximum_negotiations = 2 },
    );
    defer listener.destroy();

    // Bedrock tries TLS before the plain listener.
    try survives(listener, io, &.{
        0x16, 0x03, 0x01, 0x00, 0x2c, 0x01, 0x00, 0x00,
        0x28, 0x03, 0x03, 0x00, 0x01, 0x02, 0x03, 0x04,
    });

    try survives(listener, io, "POST /v1/join/1 HTTP/1.1\r\nHost: local");
    try survives(listener, io, "");
    try survives(listener, io, "\x00\x01\x02\x03\xff\xfe\xfd\r\n\r\n");
    try survives(listener, io, "NOTAMETHOD /v1/join HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try survives(listener, io, "GET /v1/join HTTP/9.9\r\n\r\n");
    try survives(listener, io, "POST /v1/join/1 HTTP/1.1\r\nContent-Length: abc\r\n\r\n");
}

test "failed negotiation releases its slot and leaves the listener usable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .connection = .{ .allow_anonymous = true }, .maximum_negotiations = 1 },
    );
    defer listener.destroy();

    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/v1/join/1",
        .{listener.server.socket.address.getPort()},
    );
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // A leaked slot would starve later requests.
    for (0..4) |_| {
        var output: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = "v=0\r\nnot really an offer\r\n",
            .response_writer = &writer,
            .headers = .{ .content_type = .{ .override = "application/sdp" } },
        });
        try std.testing.expect(result.status == .bad_request or
            result.status == .service_unavailable);
    }

    const working = try origin(allocator, listener, "127.0.0.1");
    defer allocator.free(working);

    const dialer = try nethernet.dialEndpoint(allocator, io, working, 7, .{});
    defer dialer.destroy();

    const accepted = try listener.accept();
    defer accepted.destroy();

    try dialer.send("slot was released", .reliable);
    const message = try accepted.receive();
    try std.testing.expectEqualStrings("slot was released", message.data);
}

test "endpoint negotiates over IPv6 loopback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const address = std.Io.net.IpAddress.parseLiteral("[::1]:0") catch
        return error.SkipZigTest;
    const listener = Listener.listen(allocator, io, address, .{
        .connection = .{ .allow_anonymous = true },
        .maximum_negotiations = 2,
    }) catch |err| switch (err) {
        error.AddressFamilyUnsupported, error.AddressUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer listener.destroy();

    const url = try origin(allocator, listener, "[::1]");
    defer allocator.free(url);

    const client = try nethernet.dialEndpoint(allocator, io, url, 6, .{});
    defer client.destroy();

    const server = try listener.accept();
    defer server.destroy();

    try client.send("over v6", .reliable);
    const message = try server.receive();
    try std.testing.expectEqualStrings("over v6", message.data);
}

test "wildcard bind accepts a loopback client" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("0.0.0.0:0"),
        .{ .connection = .{ .allow_anonymous = true }, .maximum_negotiations = 2 },
    );
    defer listener.destroy();

    const url = try origin(allocator, listener, "127.0.0.1");
    defer allocator.free(url);

    const client = try nethernet.dialEndpoint(allocator, io, url, 4, .{});
    defer client.destroy();

    const server = try listener.accept();
    defer server.destroy();

    try client.send("wildcard", .reliable);
    const message = try server.receive();
    try std.testing.expectEqualStrings("wildcard", message.data);
}

fn portOf(address: []const u8) !u16 {
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse
        return error.NoPort;
    return std.fmt.parseInt(u16, address[colon + 1 ..], 10);
}

test "ICE honours a constrained UDP port range" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const server_begin = 31200;
    const server_end = 31219;

    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{
            .connection = .{
                .allow_anonymous = true,
                .native = .{
                    .port_range_begin = server_begin,
                    .port_range_end = server_end,
                },
            },
            .maximum_negotiations = 2,
        },
    );
    defer listener.destroy();

    const url = try origin(allocator, listener, "127.0.0.1");
    defer allocator.free(url);

    const client = try nethernet.dialEndpoint(allocator, io, url, 5, .{
        .native = .{ .port_range_begin = 31220, .port_range_end = 31239 },
    });
    defer client.destroy();

    const server = try listener.accept();
    defer server.destroy();

    try client.send("ranged", .reliable);
    const message = try server.receive();
    try std.testing.expectEqualStrings("ranged", message.data);

    var local: [256]u8 = undefined;
    var remote: [256]u8 = undefined;
    const pair = (try server.selectedIceAddresses(&local, &remote)) orelse
        return error.NoSelectedCandidatePair;
    const port = try portOf(pair.local);
    try std.testing.expect(port >= server_begin and port <= server_end);
}

test "one listener serves several simultaneous clients" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .connection = .{ .allow_anonymous = true }, .maximum_negotiations = 4 },
    );
    defer listener.destroy();

    const url = try origin(allocator, listener, "127.0.0.1");
    defer allocator.free(url);

    const count = 3;
    var clients: [count]*nethernet.Connection = undefined;
    var servers: [count]*nethernet.Connection = undefined;
    var opened: usize = 0;

    defer for (0..opened) |i| {
        clients[i].destroy();
        servers[i].destroy();
    };

    for (0..count) |i| {
        clients[i] = try nethernet.dialEndpoint(allocator, io, url, @as(u64, @intCast(i + 1)), .{});
        servers[i] = try listener.accept();
        opened += 1;
    }

    for (0..count) |i| {
        var payload: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&payload, "client {d}", .{i});
        try clients[i].send(text, .reliable);
    }

    for (0..count) |i| {
        var payload: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&payload, "client {d}", .{i});
        const message = try servers[i].receive();
        try std.testing.expectEqualStrings(text, message.data);
    }
}

/// Field set of a real Bedrock Dedicated Server `GET /v1/join` response.
const bds_status_fields = [_][]const u8{
    "name",     "protocol", "version",    "level",
    "gameType", "players",  "maxPlayers",
};

test "status response carries exactly the fields Bedrock expects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const Provider = struct {
        fn get(_: ?*anyopaque) !nethernet.EndpointServerStatus {
            return .{
                .name = "srv",
                .protocol = 2216,
                .version = "1.26.60-beta.28",
                .level = "world",
                .players = 0,
                .max_players = 10,
                .game_type = 0,
            };
        }
    };

    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .status_provider = .{ .get = Provider.get } },
    );
    defer listener.destroy();

    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/v1/join",
        .{listener.server.socket.address.getPort()},
    );
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
    });
    try std.testing.expectEqual(std.http.Status.ok, result.status);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        writer.buffered(),
        .{},
    );
    defer parsed.deinit();

    for (bds_status_fields) |field| {
        if (parsed.value.object.get(field) == null) {
            std.debug.print("missing status field: {s}\n", .{field});
            return error.MissingStatusField;
        }
    }
    try std.testing.expectEqual(bds_status_fields.len, parsed.value.object.count());

    try std.testing.expectEqual(@as(i64, 2216), parsed.value.object.get("protocol").?.integer);
    try std.testing.expectEqualStrings("1.26.60-beta.28", parsed.value.object.get("version").?.string);
    try std.testing.expectEqual(@as(i64, 10), parsed.value.object.get("maxPlayers").?.integer);
}

test "listener destroyed while a negotiation is in flight" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    for (0..8) |_| {
        const listener = try Listener.listen(
            allocator,
            io,
            try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
            .{ .connection = .{ .allow_anonymous = true }, .maximum_negotiations = 2 },
        );

        const stream = try listener.server.socket.address.connect(io, .{ .mode = .stream });

        var buffer: [512]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        writer.interface.writeAll(
            "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 64\r\n\r\nv=0\r\n",
        ) catch {};
        writer.interface.flush() catch {};

        listener.destroy();
        stream.close(io);
    }
}

// Windows reports INVALID_PARAMETER when a pending accept is canceled.
test "repeated listener create and destroy does not leak handles" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    for (0..12) |_| {
        const listener = try Listener.listen(
            allocator,
            io,
            try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
            .{ .maximum_http_workers = 2, .maximum_negotiations = 1 },
        );
        listener.close();
        listener.close();
        listener.destroy();
    }
}

test "an exhausted UDP port range fails instead of hanging" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{
            .connection = .{
                .allow_anonymous = true,
                .native = .{ .port_range_begin = 31301, .port_range_end = 31301 },
            },
            .maximum_negotiations = 2,
            .request_timeout_ms = 2000,
        },
    );
    defer listener.destroy();

    const url = try origin(allocator, listener, "127.0.0.1");
    defer allocator.free(url);

    const first = try nethernet.dialEndpoint(allocator, io, url, 1, .{
        .negotiation_timeout_ms = 3000,
        .connection_timeout_ms = 3000,
    });
    defer first.destroy();

    const accepted = try listener.accept();
    defer accepted.destroy();

    const started = std.Io.Clock.awake.now(io);
    if (nethernet.dialEndpoint(allocator, io, url, 2, .{
        .negotiation_timeout_ms = 3000,
        .connection_timeout_ms = 3000,
    })) |second| {
        second.destroy();
    } else |_| {}

    try std.testing.expect(
        started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 30_000,
    );
}

test "network IDs at and beyond the limit are handled over real HTTP" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .maximum_negotiations = 2 },
    );
    defer listener.destroy();

    const port = listener.server.socket.address.getPort();

    for ([_]usize{ 1, 4095, 4096, 4097, 8192 }) |length| {
        const id = try allocator.alloc(u8, length);
        defer allocator.free(id);
        @memset(id, 'a');

        const request = try std.fmt.allocPrint(
            allocator,
            "POST /v1/join/{s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 0\r\n\r\n",
            .{id},
        );
        defer allocator.free(request);

        const stream = try listener.server.socket.address.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var write_buffer: [16384]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(request);
        try writer.interface.flush();

        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        const prefix = try reader.interface.take(12);
        try std.testing.expect(std.mem.startsWith(u8, prefix[9..12], "4"));
    }

    _ = port;
}
