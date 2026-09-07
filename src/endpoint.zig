const std = @import("std");

const connection = @import("connection.zig");
const Signal = @import("signal.zig").Signal;

pub const maximum_sdp_size = 1024 * 1024;

/// Sends a complete SDP offer over HTTP or HTTPS. The origin must include a port.
/// The returned answer uses the output buffer.
pub fn exchange(
    allocator: std.mem.Allocator,
    io: std.Io,
    origin: []const u8,
    network_id: u64,
    offer: []const u8,
    output: []u8,
    timeout_ms: u32,
) ![]const u8 {
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
        .{ allocator, io, origin, network_id, offer, output },
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
    network_id: u64,
    offer: []const u8,
    output: []u8,
) anyerror![]const u8 {
    try validateOrigin(origin);

    if (offer.len == 0 or offer.len > maximum_sdp_size) {
        return error.MessageTooLarge;
    }

    const base = std.mem.trimEnd(u8, origin, "/");
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/v1/join/{d}",
        .{ base, network_id },
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

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = offer,
        .response_writer = &writer,
        .headers = .{
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

/// Returns a ready connection owned by the caller.
pub fn dial(
    allocator: std.mem.Allocator,
    io: std.Io,
    origin: []const u8,
    network_id: u64,
    options: connection.Options,
) !*connection.Connection {
    var actual_options = options;
    actual_options.native.disable_trickle = true;

    var local_buf: [20]u8 = undefined;
    actual_options.local_network_id = try std.fmt.bufPrint(
        &local_buf,
        "{d}",
        .{network_id},
    );

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
        origin,
        actual_options,
    );
    errdefer peer.destroy();

    try peer.start();

    const answer = try allocator.alloc(u8, maximum_sdp_size);
    defer allocator.free(answer);

    while (!peer.ready()) {
        peer.prepareWait();
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
                        network_id,
                        signal.data,
                        answer,
                        options.negotiation_timeout_ms,
                    );

                    try peer.applySignal(.{
                        .kind = Signal.answer,
                        .connection_id = connection_id,
                        .network_id = origin,
                        .data = sdp,
                    });
                },

                .message => return error.UnexpectedMessage,
            }
        }

        try peer.wait(true);
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
