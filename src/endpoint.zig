const std = @import("std");
const connection = @import("connection.zig");
const Signal = @import("signal.zig").Signal;
pub const maximum_sdp_size = 1024 * 1024;

/// Performs complete-SDP HTTP(S) negotiation. Origin must contain an explicit
/// port, including default ports. Answer borrows output. No redirects are sent
/// an SDP offer; HTTP failures, numeric errors, and oversized bodies fail closed.
pub fn exchange(a: std.mem.Allocator, io: std.Io, origin: []const u8, network_id: u64, offer: []const u8, output: []u8, timeout_ms: u32) ![]const u8 {
    const Result = union(enum) { answer: anyerror![]const u8, timeout: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromMilliseconds(timeout_ms), .awake });
    try select.concurrent(.answer, exchangeWork, .{ a, io, origin, network_id, offer, output });
    return switch (try select.await()) {
        .answer => |result| result,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    };
}
fn exchangeWork(a: std.mem.Allocator, io: std.Io, origin: []const u8, network_id: u64, offer: []const u8, output: []u8) anyerror![]const u8 {
    try validateOrigin(origin);
    if (offer.len == 0 or offer.len > maximum_sdp_size) return error.MessageTooLarge;
    const base = std.mem.trimEnd(u8, origin, "/");
    const url = try std.fmt.allocPrint(a, "{s}/v1/join/{d}", .{ base, network_id });
    defer a.free(url);
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var writer = std.Io.Writer.fixed(output[0..@min(output.len, maximum_sdp_size)]);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = offer,
        .response_writer = &writer,
        .headers = .{ .content_type = .{ .override = "application/sdp" }, .user_agent = .{ .override = "libhttpclient/1.0.0.0" } },
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) return error.HttpFailure;
    const body = writer.buffered();
    if (body.len == 0) return error.MissingAnswer;
    if (std.fmt.parseInt(u32, body, 10)) |_| return error.RemoteFailure else |_| {}
    return body;
}
pub fn validateOrigin(origin: []const u8) !void {
    const uri = try std.Uri.parse(origin);
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or uri.port == null or uri.host == null or uri.query != null or uri.fragment != null or uri.user != null or uri.password != null) return error.InvalidEndpoint;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |path| path,
    };
    if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.InvalidEndpoint;
}

/// Returns an owned ready connection. No endpoint background task survives dial.
/// The caller drives receive/poll and eventually calls destroy.
pub fn dial(a: std.mem.Allocator, io: std.Io, origin: []const u8, network_id: u64, options: connection.Options) !*connection.Connection {
    var actual = options;
    actual.native.disable_trickle = true;
    var local_name: [20]u8 = undefined;
    actual.local_network_id = try std.fmt.bufPrint(&local_name, "{d}", .{network_id});
    var random: [8]u8 = undefined;
    io.random(&random);
    const id = if (options.connection_id != 0) options.connection_id else std.mem.readInt(u64, &random, .little);
    const peer = try connection.Connection.create(a, io, .client, id, origin, actual);
    errdefer peer.destroy();
    try peer.start();
    const answer = try a.alloc(u8, maximum_sdp_size);
    defer a.free(answer);
    while (!peer.ready()) {
        if (try peer.pollNegotiation()) |event| switch (event) {
            .signal => |signal| {
                if (!std.mem.eql(u8, signal.kind, Signal.offer)) return error.UnexpectedSignal;
                const sdp = try exchange(a, io, origin, network_id, signal.data, answer, options.negotiation_timeout_ms);
                try peer.applySignal(.{ .kind = Signal.answer, .connection_id = id, .network_id = origin, .data = sdp });
            },
            .message => return error.UnexpectedMessage,
        };
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return peer;
}

test "endpoint origins retain explicit default ports" {
    try validateOrigin("https://localhost:443");
    try validateOrigin("http://[::1]:80/");
    for ([_][]const u8{ "https://localhost", "http://localhost:80/x", "ftp://localhost:21", "https://localhost:443/?x" }) |bad| {
        if (validateOrigin(bad)) |_| return error.InvalidOriginAccepted else |_| {}
    }
}
