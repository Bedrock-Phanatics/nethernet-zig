const std = @import("std");

const Signal = @import("../protocol/signal.zig").Signal;
const connection = @import("../transport/connection.zig");

pub const maximum_sdp_size = 64 * 1024;

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
    // Like vanilla, a missing answer isn't signaled back, the dial just fails.
    return timed(io, timeout_ms, error.NoAnswer, exchangeWork, .{ allocator, io, origin, id, offer, output });
}

/// What vanilla sends about itself on its join probe.
pub const ClientInfo = struct {
    /// The game version, such as "1.26.70".
    version: []const u8,
    protocol: u32,
    platform: u32,
};

/// Sends the `GET /v1/join` probe vanilla makes before its offer and returns the server's status JSON.
/// With `info`, the query carries it and `network_id` in vanilla's order, so give the id the offer will use.
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    origin: []const u8,
    network_id: anytype,
    info: ?ClientInfo,
    output: []u8,
    timeout_ms: u32,
) ![]const u8 {
    var numeric: [maximum_numeric_network_id]u8 = undefined;
    const id = try networkIdText(network_id, &numeric);
    return timed(io, timeout_ms, error.Timeout, probeWork, .{ allocator, io, origin, id, info, output });
}

fn timed(io: std.Io, timeout_ms: u32, expired: anyerror, comptime work: anytype, args: anytype) ![]const u8 {
    const Result = union(enum) {
        done: anyerror![]const u8,
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
    try select.concurrent(.done, work, args);

    return switch (try select.await()) {
        .done => |result| result,
        .timeout => |result| {
            try result;
            return expired;
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

    const body = try send(allocator, io, .POST, base, url, offer, output);
    if (body.len == 0) return error.MissingAnswer;

    if (std.fmt.parseInt(u32, body, 10)) |_| {
        return error.RemoteFailure;
    } else |_| {}

    return body;
}

fn probeWork(
    allocator: std.mem.Allocator,
    io: std.Io,
    origin: []const u8,
    network_id: []const u8,
    info: ?ClientInfo,
    output: []u8,
) anyerror![]const u8 {
    try validateOrigin(origin);
    if (!connection.validNetworkId(network_id)) return error.InvalidNetworkId;

    const base = std.mem.trimEnd(u8, origin, "/");
    const url = if (info) |client| try std.fmt.allocPrint(
        allocator,
        "{s}/v1/join?version={f}&protocol={d}&platform={d}&id={f}",
        .{
            base,
            std.fmt.alt(std.Uri.Component{ .raw = client.version }, .formatEscaped),
            client.protocol,
            client.platform,
            std.fmt.alt(std.Uri.Component{ .raw = network_id }, .formatEscaped),
        },
    ) else try std.fmt.allocPrint(allocator, "{s}/v1/join", .{base});
    defer allocator.free(url);

    return send(allocator, io, .GET, base, url, null, output);
}

fn send(
    allocator: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    base: []const u8,
    url: []const u8,
    body: ?[]const u8,
    output: []u8,
) ![]const u8 {
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
    const host = try (uri.host orelse return error.UriMissingHost).toRaw(&host_buffer);
    const ipv6 = host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']';
    if (ipv6) uri.host = .{ .raw = host[1 .. host.len - 1] };

    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
    // std.http rejects IP literals as host names, but its resolver still connects to them.
    var req = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .connection = if (ipv6) try client.connectTcp(.{ .bytes = uri.host.?.raw }, uri.port.?, protocol) else null,
        .headers = .{
            .host = if (ipv6) .{ .override = base[uri.scheme.len + 3 ..] } else .default,
            .content_type = if (body != null) .{ .override = "application/sdp" } else .default,
            .user_agent = .{ .override = "libhttpclient/1.0.0.0" },
        },
    });
    defer req.deinit();

    if (body) |data| {
        req.transfer_encoding = .{ .content_length = data.len };
        var request_body = try req.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(data);
        try request_body.end();
        try req.connection.?.flush();
    } else try req.sendBodiless();

    var response = try req.receiveHead(&.{});
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer allocator.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    switch (@backingInt(response.head.status)) {
        200...299 => {},
        401 => return error.Unauthorized,
        403 => return error.Forbidden,
        503 => return error.ServiceUnavailable,
        else => return error.HttpFailure,
    }

    return writer.buffered();
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

test "the join probe sends vanilla's query and returns the status" {
    const io = std.testing.io;
    var server = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});

    const Serve = struct {
        fn run(server_ptr: *std.Io.net.Server, target: []const u8) !void {
            const stream = try server_ptr.accept(std.testing.io);
            defer stream.close(std.testing.io);
            var input: [4096]u8 = undefined;
            var output: [4096]u8 = undefined;
            var reader = stream.reader(std.testing.io, &input);
            var writer = stream.writer(std.testing.io, &output);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var req = try http.receiveHead();
            try std.testing.expectEqual(.GET, req.head.method);
            try std.testing.expectEqualStrings(target, req.head.target);
            try std.testing.expect(req.head.content_type == null);
            try req.respond("{\"version\":1}", .{ .keep_alive = false });
        }
    };

    const cases = [_]struct { ?ClientInfo, []const u8 }{
        .{ .{ .version = "1.26.70", .protocol = 975, .platform = 7 }, "/v1/join?version=1.26.70&protocol=975&platform=7&id=a%26b" },
        .{ null, "/v1/join" },
    };
    for (cases) |case| {
        var pending = try io.concurrent(Serve.run, .{ &server, case[1] });
        defer _ = pending.cancel(io) catch {};
        var output: [64]u8 = undefined;
        const status = try probe(std.testing.allocator, io, origin, "a&b", case[0], &output, 3000);
        try std.testing.expectEqualStrings("{\"version\":1}", status);
        try pending.await(io);
    }

    var output: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidNetworkId, probe(std.testing.allocator, io, origin, "", null, &output, 3000));
}

test "rejected joins report the HTTP status class" {
    const io = std.testing.io;
    var server = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});

    const Serve = struct {
        fn run(server_ptr: *std.Io.net.Server, status: std.http.Status) !void {
            const stream = try server_ptr.accept(std.testing.io);
            defer stream.close(std.testing.io);
            var input: [4096]u8 = undefined;
            var output: [4096]u8 = undefined;
            var reader = stream.reader(std.testing.io, &input);
            var writer = stream.writer(std.testing.io, &output);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try http.receiveHead();
            var body_buffer: [64]u8 = undefined;
            _ = try request.readerExpectNone(&body_buffer).discardRemaining();
            try request.respond("", .{ .status = status, .keep_alive = false });
        }
    };
    const cases = [_]struct { std.http.Status, anyerror }{
        .{ .forbidden, error.Forbidden },
        .{ .service_unavailable, error.ServiceUnavailable },
        .{ .bad_request, error.HttpFailure },
    };
    for (cases) |case| {
        var pending = try io.concurrent(Serve.run, .{ &server, case[0] });
        defer _ = pending.cancel(io) catch {};
        var output: [64]u8 = undefined;
        try std.testing.expectError(case[1], exchange(std.testing.allocator, io, origin, "1", "v=0\r\n", &output, 3000));
        try pending.await(io);
    }
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

    for ([_][]const u8{ "", "tab\there", &.{ '1', 0 }, &@as([connection.maximum_network_id_length + 1]u8, @splat('a')) }) |id| {
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
