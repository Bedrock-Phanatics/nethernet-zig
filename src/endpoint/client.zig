const std = @import("std");

const Signal = @import("../protocol/signal.zig").Signal;
const connection = @import("../transport/connection.zig");

pub const maximum_sdp_size = 1024 * 1024;

const maximum_numeric_network_id = 20;

fn networkIdText(
    network_id: anytype,
    buffer: *[maximum_numeric_network_id]u8,
) ![]const u8 {
    return switch (@typeInfo(@TypeOf(network_id))) {
        .int, .comptime_int => std.fmt.bufPrint(buffer, "{d}", .{network_id}),
        else => network_id,
    };
}

pub fn exchange(
    allocator: std.mem.Allocator,
    io: std.Io,
    origin: []const u8,
    network_id: anytype,
    offer: []const u8,
    output: []u8,
    timeout_ms: u32,
) ![]const u8 {
    var numeric: [maximum_numeric_network_id]u8 = undefined;
    const id = try networkIdText(network_id, &numeric);
    const Result = union(enum) {
        answer: anyerror![]const u8,
        timeout: std.Io.Cancelable!void,
    };

    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer select.cancelDiscard();

    try select.concurrent(
        .timeout,
        std.Io.sleep,
        .{ io, std.Io.Duration.fromMilliseconds(timeout_ms), .awake },
    );
    try select.concurrent(
        .answer,
        exchangeWork,
        .{ allocator, io, origin, id, offer, output },
    );

    return switch (try select.await()) {
        .answer => |result| result,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    };
}

fn exchangeWork(
    allocator: std.mem.Allocator,
    io: std.Io,
    origin: []const u8,
    network_id: []const u8,
    offer: []const u8,
    output: []u8,
) anyerror![]const u8 {
    try validateOrigin(origin);

    if (!connection.validNetworkId(network_id)) return error.InvalidNetworkId;

    if (offer.len == 0 or offer.len > maximum_sdp_size) {
        return error.MessageTooLarge;
    }

    const base = std.mem.trimEnd(u8, origin, "/");
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/v1/join/{f}",
        .{ base, std.fmt.alt(std.Uri.Component{ .raw = network_id }, .formatEscaped) },
    );
    defer allocator.free(url);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var writer = std.Io.Writer.fixed(
        output[0..@min(output.len, maximum_sdp_size)],
    );

    var uri = try std.Uri.parse(url);
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (try uri.getHost(&host_buffer)).bytes;
    const ipv6 = host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']';
    if (ipv6) uri.host = .{ .raw = host[1 .. host.len - 1] };

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = offer,
        .response_writer = &writer,
        .headers = .{
            .host = if (ipv6) .{ .override = base[uri.scheme.len + 3 ..] } else .default,
            .content_type = .{ .override = "application/sdp" },
            .user_agent = .{ .override = "libhttpclient/1.0.0.0" },
        },
    });

    const status = @intFromEnum(result.status);
    if (status < 200 or status >= 300) return error.HttpFailure;

    const body = writer.buffered();
    if (body.len == 0) return error.MissingAnswer;

    if (std.fmt.parseInt(u32, body, 10)) |_| {
        return error.RemoteFailure;
    } else |_| {}

    return body;
}

pub fn validateOrigin(origin: []const u8) !void {
    const uri = try std.Uri.parse(origin);

    const valid_scheme =
        std.mem.eql(u8, uri.scheme, "http") or
        std.mem.eql(u8, uri.scheme, "https");

    if (!valid_scheme or
        uri.port == null or
        uri.host == null or
        uri.query != null or
        uri.fragment != null or
        uri.user != null or
        uri.password != null)
    {
        return error.InvalidEndpoint;
    }

    const path = switch (uri.path) {
        .raw, .percent_encoded => |path| path,
    };

    if (path.len != 0 and !std.mem.eql(u8, path, "/")) {
        return error.InvalidEndpoint;
    }
}

pub fn dial(
    allocator: std.mem.Allocator,
    io: std.Io,
    origin: []const u8,
    network_id: anytype,
    options: connection.Options,
) !*connection.Connection {
    var numeric: [maximum_numeric_network_id]u8 = undefined;
    const id = try networkIdText(network_id, &numeric);

    if (!connection.validNetworkId(id)) return error.InvalidNetworkId;

    var actual_options = options;
    actual_options.native.disable_trickle = true;
    actual_options.local_network_id = id;

    var random: [8]u8 = undefined;
    io.random(&random);

    const connection_id = if (options.connection_id != 0)
        options.connection_id
    else
        std.mem.readInt(u64, &random, .little);

    const peer = try connection.Connection.create(
        allocator,
        io,
        .client,
        connection_id,
        id,
        actual_options,
    );
    errdefer peer.destroy();

    try peer.start();

    const answer = try allocator.alloc(u8, maximum_sdp_size);
    defer allocator.free(answer);

    while (!peer.ready()) {
        const token = peer.prepareWait();
        if (try peer.pollNegotiation()) |event| {
            switch (event) {
                .signal => |signal| {
                    if (!std.mem.eql(u8, signal.kind, Signal.offer)) {
                        return error.UnexpectedSignal;
                    }

                    const sdp = try exchange(
                        allocator,
                        io,
                        origin,
                        id,
                        signal.data,
                        answer,
                        options.negotiation_timeout_ms,
                    );

                    try peer.applySignal(.{
                        .kind = Signal.answer,
                        .connection_id = connection_id,
                        .network_id = id,
                        .data = sdp,
                    });
                },

                .message => return error.UnexpectedMessage,
            }
        }

        try peer.wait(token, true);
    }

    return peer;
}

test "endpoint origins retain explicit default ports" {
    try validateOrigin("https://localhost:443");
    try validateOrigin("http://[::1]:80/");

    const invalid_origins = [_][]const u8{
        "https://localhost",
        "http://localhost:80/x",
        "ftp://localhost:21",
        "https://localhost:443/?x",
    };

    for (invalid_origins) |origin| {
        if (validateOrigin(origin)) |_| {
            return error.InvalidOriginAccepted;
        } else |_| {}
    }
}

test "IPv6 endpoint exchange preserves the Host header" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var server = try (try std.Io.net.IpAddress.parseIp6("::1", 0)).listen(io, .{});
    defer server.deinit(io);

    const host = try std.fmt.allocPrint(allocator, "[::1]:{d}", .{server.socket.address.getPort()});
    defer allocator.free(host);
    const origin = try std.fmt.allocPrint(allocator, "http://{s}/", .{host});
    defer allocator.free(origin);

    const Serve = struct {
        fn run(server_ptr: *std.Io.net.Server, expected_host: []const u8) !void {
            const stream = try server_ptr.accept(std.testing.io);
            defer stream.close(std.testing.io);
            var input: [4096]u8 = undefined;
            var output: [4096]u8 = undefined;
            var reader = stream.reader(std.testing.io, &input);
            var writer = stream.writer(std.testing.io, &output);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try http.receiveHead();
            try std.testing.expectEqual(.POST, request.head.method);
            try std.testing.expectEqualStrings("/v1/join/opaque%2Fid", request.head.target);
            var headers = request.iterateHeaders();
            var found_host = false;
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase("host", header.name)) {
                    try std.testing.expectEqualStrings(expected_host, header.value);
                    found_host = true;
                }
            }
            try std.testing.expect(found_host);
            var body_buffer: [64]u8 = undefined;
            const body = request.readerExpectNone(&body_buffer);
            try std.testing.expectEqualStrings("v=0\r\n", try body.take(5));
            try request.respond("v=0\r\n", .{ .keep_alive = false });
        }
    };
    var pending = try io.concurrent(Serve.run, .{ &server, host });
    defer _ = pending.cancel(io) catch {};
    var output: [64]u8 = undefined;
    const answer = try exchange(allocator, io, origin, "opaque/id", "v=0\r\n", &output, 3000);
    try std.testing.expectEqualStrings("v=0\r\n", answer);
    try pending.await(io);
}

test "opaque and numeric network IDs share one representation" {
    var numeric: [maximum_numeric_network_id]u8 = undefined;

    try std.testing.expectEqualStrings(
        "18446744073709551615",
        try networkIdText(@as(u64, std.math.maxInt(u64)), &numeric),
    );
    try std.testing.expectEqualStrings("12", try networkIdText(12, &numeric));
    try std.testing.expectEqualStrings(
        "a3f0-9c11",
        try networkIdText(@as([]const u8, "a3f0-9c11"), &numeric),
    );
    try std.testing.expectEqualStrings(
        "18446744073709551616",
        try networkIdText("18446744073709551616", &numeric),
    );
}

test "endpoint exchanges reject empty, control, and oversized IDs" {
    const allocator = std.testing.allocator;
    var output: [64]u8 = undefined;

    for ([_][]const u8{ "", "tab\there", &.{ '1', 0 }, "a" ** (connection.maximum_network_id_length + 1) }) |id| {
        try std.testing.expectError(error.InvalidNetworkId, exchangeWork(
            allocator,
            undefined,
            "http://127.0.0.1:19132",
            id,
            "v=0\r\n",
            &output,
        ));
    }
}
