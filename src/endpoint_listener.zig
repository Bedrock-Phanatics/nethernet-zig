const std = @import("std");
const conn = @import("connection.zig");
const Signal = @import("signal.zig").Signal;
const maximum_sdp_size = @import("endpoint.zig").maximum_sdp_size;

pub const Options = struct {
    connection: conn.Options = .{},
    maximum_negotiations: usize = 8,
    maximum_pending_accepts: usize = 64,
    request_timeout_ms: u32 = 15000,
};

/// HTTP endpoint listener with a fixed number of negotiation workers. Established
/// WebRTC connections have no dedicated worker. Allocator and verifier callbacks
/// must support concurrent calls. HTTPS may terminate at a reverse proxy; this
/// listener accepts HTTP streams.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    options: Options,
    group: std.Io.Group = .init,
    accepted: std.Io.Queue(*conn.Connection),
    slots: []*conn.Connection,
    closed: bool = false,

    pub fn listen(a: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress, options: Options) !*Listener {
        if (options.maximum_negotiations == 0 or options.maximum_negotiations > 1024 or options.maximum_pending_accepts == 0 or options.request_timeout_ms == 0) return error.InvalidConfiguration;
        const self = try a.create(Listener);
        errdefer a.destroy(self);
        const slots = try a.alloc(*conn.Connection, options.maximum_pending_accepts);
        errdefer a.free(slots);
        var server = try address.listen(io, .{});
        errdefer server.deinit(io);
        self.* = .{ .allocator = a, .io = io, .server = server, .options = options, .slots = slots, .accepted = .init(slots) };
        errdefer {
            self.accepted.close(io);
            self.group.cancel(io);
            while (self.accepted.getOneUncancelable(io)) |connection| connection.destroy() else |_| {}
        }
        for (0..options.maximum_negotiations) |_| try self.group.concurrent(io, worker, .{self});
        return self;
    }
    /// Returned connection transfers ownership to caller and survives listener close.
    pub fn accept(self: *Listener) !*conn.Connection {
        return self.accepted.getOne(self.io);
    }
    pub fn close(self: *Listener) void {
        if (self.closed) return;
        self.closed = true;
        self.accepted.close(self.io);
        self.group.cancel(self.io);
        self.server.deinit(self.io);
        while (self.accepted.getOneUncancelable(self.io)) |connection| connection.destroy() else |_| {}
    }
    pub fn destroy(self: *Listener) void {
        self.close();
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }
    fn worker(self: *Listener) std.Io.Cancelable!void {
        while (true) {
            const stream = self.server.accept(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    self.accepted.close(self.io);
                    return;
                },
            };
            defer stream.close(self.io);
            self.handleTimed(stream) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
        }
    }
    fn handleTimed(self: *Listener, stream: std.Io.net.Stream) !void {
        const Result = union(enum) { done: anyerror!void, timeout: std.Io.Cancelable!void };
        var results: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &results);
        defer select.cancelDiscard();
        try select.concurrent(.timeout, std.Io.sleep, .{ self.io, std.Io.Duration.fromMilliseconds(self.options.request_timeout_ms), .awake });
        try select.concurrent(.done, handle, .{ self, stream });
        switch (try select.await()) {
            .done => |result| try result,
            .timeout => |result| {
                try result;
                return error.Timeout;
            },
        }
    }
    fn handle(self: *Listener, stream: std.Io.net.Stream) anyerror!void {
        var input: [16384]u8 = undefined;
        var output: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &input);
        var writer = stream.writer(self.io, &output);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try http.receiveHead();
        if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/v1/join")) return request.respond("", .{ .keep_alive = false });
        if (request.head.method != .POST or !std.mem.startsWith(u8, request.head.target, "/v1/join/")) return request.respond("", .{ .status = .not_found, .keep_alive = false });
        const name = request.head.target[9..];
        if (name.len == 0) return request.respond("Network ID must be uint64", .{ .status = .bad_request, .keep_alive = false });
        for (name) |byte| if (byte < '0' or byte > '9') return request.respond("Network ID must be uint64", .{ .status = .bad_request, .keep_alive = false });
        _ = std.fmt.parseInt(u64, name, 10) catch return request.respond("Network ID must be uint64", .{ .status = .bad_request, .keep_alive = false });
        if ((request.head.content_length orelse 0) > maximum_sdp_size) return request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
        const network_id = try self.allocator.dupe(u8, name);
        defer self.allocator.free(network_id);
        var transfer: [4096]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&transfer);
        const body = body_reader.allocRemaining(self.allocator, .limited(maximum_sdp_size)) catch return request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
        defer self.allocator.free(body);
        if (body.len == 0) return request.respond("Missing SDP offer in request body", .{ .status = .bad_request, .keep_alive = false });
        var id_bytes: [8]u8 = undefined;
        self.io.random(&id_bytes);
        const id = std.mem.readInt(u64, &id_bytes, .little);
        var options = self.options.connection;
        options.native.disable_trickle = true;
        const connection = try conn.Connection.create(self.allocator, self.io, .server, id, network_id, options);
        var transferred = false;
        defer if (!transferred) connection.destroy();
        connection.applySignal(.{ .kind = Signal.offer, .connection_id = id, .network_id = network_id, .data = body }) catch return request.respond("Negotiation failed", .{ .status = .bad_request, .keep_alive = false });
        var answered = false;
        while (!answered or !connection.ready()) {
            if (try connection.pollNegotiation()) |event| switch (event) {
                .signal => |signal| {
                    if (!std.mem.eql(u8, signal.kind, Signal.answer) or answered) return error.UnexpectedSignal;
                    try request.respond(signal.data, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/sdp" }} });
                    answered = true;
                },
                .message => return error.UnexpectedMessage,
            };
            try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
        }
        if (try self.accepted.put(self.io, &.{connection}, 0) == 0) return error.AcceptQueueFull;
        transferred = true;
    }
};
