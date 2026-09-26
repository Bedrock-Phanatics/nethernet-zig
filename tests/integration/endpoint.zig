const std = @import("std");
const nethernet = @import("nethernet");

const Listener = nethernet.EndpointListener;

const TestStatusProvider = struct {
    fail: bool = false,
    protocol: u32 = 800,
    version: []const u8 = "1.21.0",
    game_type: i32 = 1,

    fn get(context: ?*anyopaque) !nethernet.EndpointServerStatus {
        const self: *TestStatusProvider = @ptrCast(@alignCast(context.?));
        if (self.fail) return error.StatusUnavailable;

        return .{
            .name = "Nether \"Server\"\\One",
            .protocol = self.protocol,
            .version = self.version,
            .level = "Snowman ☃",
            .players = 3,
            .max_players = 20,
            .game_type = self.game_type,
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
    try std.testing.expect(client.public_key != null);

    const server = try listener.accept();
    defer server.destroy();

    const client_channels = client.diagnostics();
    const server_channels = server.diagnostics();
    try std.testing.expectEqual(nethernet.ChannelState.open, client_channels.reliable.state);
    try std.testing.expectEqual(nethernet.ChannelState.open, client_channels.unreliable.state);
    try std.testing.expectEqual(nethernet.ChannelState.open, server_channels.reliable.state);
    try std.testing.expectEqual(nethernet.ChannelState.open, server_channels.unreliable.state);

    listener.close();
    listener.close();

    try client.send("survives listener close", .reliable);
    const message = try server.receive();
    try std.testing.expectEqualStrings("survives listener close", message.data);
}

test "HTTP endpoint returns JSON only for valid available metadata" {
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
    var request = try client.request(.GET, try std.Uri.parse(url), .{});
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    try std.testing.expectEqual(std.http.Status.ok, response.head.status);
    try std.testing.expectEqualStrings("application/json", response.head.content_type.?);
    var transfer: [64]u8 = undefined;
    _ = try response.reader(&transfer).streamRemaining(&writer);

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

    for ([_]TestStatusProvider{
        .{ .protocol = 0 },
        .{ .version = "" },
        .{ .version = "\xff" },
        .{ .game_type = -1 },
        .{ .game_type = 3 },
    }) |invalid| {
        state = invalid;
        writer = std.Io.Writer.fixed(&output);
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &writer,
        });
        try std.testing.expectEqual(std.http.Status.internal_server_error, result.status);
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }

    state = .{};
    writer = std.Io.Writer.fixed(&output);
    const recovered = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &writer });
    try std.testing.expectEqual(std.http.Status.ok, recovered.status);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "HTTP rejects invalid routes, network IDs, empty SDP and oversized bodies" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .connection = .{ .allow_anonymous = true }, .maximum_negotiations = 2 },
    );
    defer listener.destroy();

    const Case = struct {
        request: []const u8,
        status: []const u8,
    };
    const cases = [_]Case{
        .{
            .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nnope",
            .status = "415",
        },
        .{
            .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 4\r\n\r\nnope",
            .status = "415",
        },
        .{
            .request = "GET /v1/join HTTP/1.1\r\nHost: localhost\r\n\r\n",
            .status = "503",
        },
        .{
            .request = "GET /bad HTTP/1.1\r\nHost: localhost\r\n\r\n",
            .status = "404",
        },
        .{
            .request = "NOTAMETHOD /v1/join HTTP/1.1\r\nHost: localhost\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "POST /v1/join HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 0\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "GET /v1/join/1 HTTP/1.1\r\nHost: localhost\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "GET /v1/join HTTP/1.1\r\nHost: localhost\r\nExpect: nope\r\n\r\n",
            .status = "417",
        },
        .{
            .request = "POST /v1/join/nope HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 0\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "POST /v1/join/ HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 0\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "POST /v1/join/one/two HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 0\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 0\r\n\r\n",
            .status = "400",
        },
        .{
            .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 1048577\r\n\r\n",
            .status = "413",
        },
        .{
            .request = "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 4\r\n\r\nnope",
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

test "HTTP rejects malformed percent escapes before negotiating" {
    const io = std.testing.io;
    const listener = try Listener.listen(std.testing.allocator, io, try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"), .{});
    defer listener.destroy();

    for ([_][]const u8{ "%", "%2", "%GG", "%+1", "%-1", "%0G", "%00", "%09", "%7f" }) |id| {
        const stream = try listener.server.socket.address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var output: [512]u8 = undefined;
        var writer = stream.writer(io, &output);
        try writer.interface.print("POST /v1/join/{s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 4\r\nConnection: close\r\n\r\nnope", .{id});
        try writer.interface.flush();
        var input: [256]u8 = undefined;
        var reader = stream.reader(io, &input);
        try std.testing.expectEqualStrings("HTTP/1.1 400", try reader.interface.take(12));
    }
}

test "HTTP reports identity rejection and peer creation failures" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");

    for ([_]struct { options: nethernet.EndpointListenerOptions, status: []const u8 }{
        .{ .options = .{}, .status = "403" },
        .{ .options = .{ .connection = .{
            .allow_anonymous = true,
            .native = .{ .port_range_begin = 30000 },
        } }, .status = "500" },
    }) |case| {
        const listener = try Listener.listen(allocator, io, address, case.options);
        defer listener.destroy();
        const stream = try listener.server.socket.address.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var write_buffer: [512]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(
            "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 4\r\n\r\nnope",
        );
        try writer.interface.flush();

        var read_buffer: [512]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        const prefix = try reader.interface.take(12);
        try std.testing.expectEqualStrings(case.status, prefix[9..12]);
    }
}

test "HTTP times out a stalled request with a response" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const listener = try Listener.listen(
        allocator,
        io,
        try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .{ .request_timeout_ms = 100 },
    );
    defer listener.destroy();

    const stream = try listener.server.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(
        "POST /v1/join/1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/sdp\r\nContent-Length: 4\r\n\r\n",
    );
    try writer.interface.flush();

    var read_buffer: [512]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const prefix = try reader.interface.take(12);
    try std.testing.expectEqualStrings("504", prefix[9..12]);
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

    for ([_][]const u8{ "a3f0-9c11", "18446744073709551616", "a/b?c#d% e", "literal%2F+id" }) |network_id| {
        const client = try nethernet.dialEndpoint(allocator, io, origin, network_id, .{});
        defer client.destroy();

        const server = try listener.accept();
        defer server.destroy();

        try std.testing.expectEqualStrings(network_id, server.remoteAddress().network_id);
        try std.testing.expectEqualStrings(network_id, client.localAddress().network_id);
        try std.testing.expectEqualStrings(network_id, client.remoteAddress().network_id);

        try client.send("opaque", .reliable);
        try std.testing.expectEqualStrings("opaque", (try server.receive()).data);
    }

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/join/7", .{origin});
    defer allocator.free(url);

    const offer = try nethernet.Peer.create(allocator, io, .{
        .disable_trickle = true,
        .bind_address = "127.0.0.1",
    });
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

    const rewritten = try allocator.dupe(u8, sdp);
    defer allocator.free(rewritten);
    var replacements: usize = 0;
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, rewritten, position, "127.0.0.1")) |found| {
        @memcpy(rewritten[found..][0..9], "192.0.2.1");
        replacements += 1;
        position = found + 9;
    }
    try std.testing.expect(replacements > 0);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var request = try client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .content_type = .{ .override = "Application/SDP; charset=utf-8" } },
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = rewritten.len };
    var body = try request.sendBodyUnflushed(&.{});
    try body.writer.writeAll(rewritten);
    try body.end();
    try request.connection.?.flush();

    var response = try request.receiveHead(&.{});
    try std.testing.expectEqual(std.http.Status.ok, response.head.status);
    try std.testing.expectEqualStrings("application/sdp", response.head.content_type.?);
    var output: [1024 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var transfer_buffer: [64]u8 = undefined;
    _ = try response.reader(&transfer_buffer).streamRemaining(&writer);

    const answer = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, answer, "v=0"));
    for ([_][]const u8{
        "\r\no=",             "\r\ns=",                                "\r\nt=",          "\r\nc=IN IP",
        "\r\nm=application ", " UDP/DTLS/SCTP webrtc-datachannel\r\n", "\r\na=mid:0\r\n", "\r\na=ice-ufrag:",
        "\r\na=ice-pwd:",
    }) |field| try std.testing.expect(std.mem.indexOf(u8, answer, field) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, answer, "\r\nm="));
    var candidates: usize = 0;
    var lines = std.mem.tokenizeAny(u8, answer, "\r\n");
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "a=candidate:")) continue;
        candidates += 1;
        try std.testing.expect(std.mem.indexOf(u8, line, " UDP ") != null or
            std.mem.indexOf(u8, line, " udp ") != null);
    }
    try std.testing.expect(candidates > 0);
    const media_start = std.mem.indexOf(u8, answer, "\r\nm=").? + 2;
    const identity_start = std.mem.indexOf(u8, answer, "a=identity:").?;
    try std.testing.expect(identity_start < media_start);
    try std.testing.expect(std.mem.indexOf(u8, answer, "a=group:BUNDLE 0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer[media_start..], "a=setup:active\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer[media_start..], "a=sctp-port:5000\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer[media_start..], "a=max-message-size:262144\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer[media_start..], "a=end-of-candidates\r\n") != null);

    const fingerprint_start = std.mem.indexOf(u8, answer, "a=fingerprint:").?;
    try std.testing.expect(std.mem.startsWith(u8, answer[fingerprint_start..], "a=fingerprint:sha-256 "));
    const digest_start = std.mem.indexOfScalarPos(u8, answer, fingerprint_start, ' ').? + 1;
    const digest_end = std.mem.indexOfScalarPos(u8, answer, digest_start, '\n').?;
    const digest = std.mem.trimEnd(u8, answer[digest_start..digest_end], "\r");
    for (digest) |byte| try std.testing.expect(byte < 'a' or byte > 'f');

    const payload = try nethernet.sdp_identity.fingerprintPayload(allocator, answer);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, digest) != null);
    try std.testing.expect((try nethernet.sdp_identity.verify(
        allocator,
        answer,
        std.Io.Clock.real.now(io).toSeconds(),
        .server,
        null,
    )) != null);

    const native_answer = try allocator.dupeZ(u8, answer);
    defer allocator.free(native_answer);
    try offer.remoteDescription(native_answer, .answer);
    const deadline = std.Io.Clock.awake.now(io);
    while (!offer.ready()) {
        if (deadline.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 15_000)
            return error.Timeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    const server = try listener.accept();
    defer server.destroy();
    try std.testing.expectEqual(std.mem.count(u8, rewritten, "a=candidate:") + 1, server.remoteIceCandidateCount());
}
