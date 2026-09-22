const std = @import("std");
const nethernet = @import("nethernet");

const Listener = nethernet.EndpointListener;

const TestStatusProvider = struct {
    fail: bool = false,

    fn get(context: ?*anyopaque) !nethernet.EndpointServerStatus {
        const self: *TestStatusProvider = @ptrCast(@alignCast(context.?));
        if (self.fail) return error.StatusUnavailable;

        return .{
            .name = "Nether \"Server\"\\One",
            .protocol = 800,
            .version = "1.21.0",
            .level = "Snowman ☃",
            .players = 3,
            .max_players = 20,
            .game_type = 1,
        };
    }
};

test "HTTP endpoint listener and dialer transfer ownership and shut down" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{
            .connection = .{ .allow_anonymous = true },
            .maximum_negotiations = 2,
        },
    );
    defer listener.destroy();

    const origin = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{listener.server.socket.address.getPort()},
    );
    defer allocator.free(origin);

    const client = try nethernet.dialEndpoint(allocator, io, origin, 12, .{});
    defer client.destroy();

    const server = try listener.accept();
    defer server.destroy();

    listener.close();
    listener.close();

    try client.send("survives listener close", .reliable);
    const message = try server.receive();
    try std.testing.expectEqualStrings("survives listener close", message.data);
}

test "HTTP endpoint status is optional and provider errors are safe" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var state: TestStatusProvider = .{};

    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{
            .maximum_negotiations = 2,
            .status_provider = .{
                .context = &state,
                .get = TestStatusProvider.get,
            },
        },
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

    var output: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
    });
    try std.testing.expectEqual(std.http.Status.ok, result.status);

    const expected =
        "{\"name\":\"Nether \\\"Server\\\"\\\\One\"," ++
        "\"protocol\":800,\"version\":\"1.21.0\"," ++
        "\"level\":\"Snowman ☃\",\"gameType\":1," ++
        "\"players\":3,\"maxPlayers\":20}";
    try std.testing.expectEqualStrings(expected, writer.buffered());

    state.fail = true;
    writer = std.Io.Writer.fixed(&output);
    const failed = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
    });
    try std.testing.expectEqual(std.http.Status.service_unavailable, failed.status);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "HTTP rejects invalid routes, network IDs, empty SDP and oversized bodies" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .maximum_negotiations = 2 },
    );
    defer listener.destroy();

    const Case = struct {
        request: []const u8,
        status: []const u8,
    };
    const cases = [_]Case{
        .{
            .request = "GET /v1/join HTTP/1.1\r\nHost: localhost\r\n\r\n",
            .status = "503",
        },
        .{
            .request = "GET /bad HTTP/1.1\r\nHost: localhost\r\n\r\n",
            .status = "404",
        },
        .{
            .request = "POST /v1/join/nope HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "POST /v1/join/ HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "POST /v1/join/one/two HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048577\r\n\r\n",
            .status = "413",
        },
        .{
            .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nnope",
            .status = "400",
        },
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

test "endpoint listener keeps one server identity key for its lifetime" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .connection = .{ .allow_anonymous = true } },
    );
    defer listener.destroy();

    const origin = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{listener.server.socket.address.getPort()},
    );
    defer allocator.free(origin);

    const first_client = try nethernet.dialEndpoint(allocator, io, origin, 1, .{});
    defer first_client.destroy();
    const first_server = try listener.accept();
    defer first_server.destroy();

    const second_client = try nethernet.dialEndpoint(allocator, io, origin, 2, .{});
    defer second_client.destroy();
    const second_server = try listener.accept();
    defer second_server.destroy();

    const first_key = first_client.public_key.?.toUncompressedSec1();
    const second_key = second_client.public_key.?.toUncompressedSec1();
    try std.testing.expectEqualSlices(u8, &first_key, &second_key);
}

test "HTTP signaling uses application/sdp and an opaque network ID" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{
            .connection = .{ .allow_anonymous = true },
            .maximum_negotiations = 2,
        },
    );
    defer listener.destroy();

    const origin = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{listener.server.socket.address.getPort()},
    );
    defer allocator.free(origin);

    for ([_][]const u8{ "a3f0-9c11", "18446744073709551616" }) |network_id| {
        const client = try nethernet.dialEndpoint(allocator, io, origin, network_id, .{});
        defer client.destroy();

        const server = try listener.accept();
        defer server.destroy();

        try std.testing.expectEqualStrings(network_id, server.remoteAddress().network_id);
        try std.testing.expectEqualStrings(network_id, client.localAddress().network_id);

        try client.send("opaque", .reliable);
        try std.testing.expectEqualStrings("opaque", (try server.receive()).data);
    }

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/join/7", .{origin});
    defer allocator.free(url);

    const offer = try nethernet.Peer.create(allocator, io, .{ .disable_trickle = true });
    defer offer.destroy();
    try offer.offer();

    const buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buffer);

    const started = std.Io.Clock.awake.now(io);
    const sdp = while (true) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 15_000) {
            return error.Timeout;
        }
        if (try offer.poll(buffer)) |event| switch (event) {
            .offer => |data| break data,
            else => return error.UnexpectedEvent,
        };
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    };

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var output: [1024 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = sdp,
        .response_writer = &writer,
        .headers = .{ .content_type = .{ .override = "application/sdp" } },
    });

    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "v=0"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=candidate:") != null);
}
