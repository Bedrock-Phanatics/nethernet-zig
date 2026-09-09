const std = @import("std");

const conn = @import("connection.zig");
const Signal = @import("signal.zig").Signal;
const maximum_sdp_size = @import("endpoint.zig").maximum_sdp_size;

pub const maximum_status_response_size = 16 * 1024;

pub const ServerStatus = struct {
    name: []const u8,
    protocol: u32,
    version: []const u8,
    level: []const u8,
    players: u32,
    max_players: u32,
    game_type: i32,
};

pub const StatusProvider = struct {
    context: ?*anyopaque = null,
    get: *const fn (context: ?*anyopaque) anyerror!ServerStatus,
};

pub const Options = struct {
    connection: conn.Options = .{},
    maximum_negotiations: usize = 8,
    maximum_pending_accepts: usize = 64,
    request_timeout_ms: u32 = 15000,
    /// Called concurrently by HTTP workers. Returned strings must remain valid
    /// while the listener is running.
    status_provider: ?StatusProvider = null,
};

/// Uses a fixed worker pool. The allocator and verifier must support concurrent calls.
/// HTTPS must be handled by an upstream proxy.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    options: Options,

    group: std.Io.Group = .init,
    accepted: std.Io.Queue(*conn.Connection),
    slots: []*conn.Connection,
    accept_mutex: std.Io.Mutex = .init,
    reserved_accepts: usize = 0,
    closed: bool = false,

    pub fn listen(
        allocator: std.mem.Allocator,
        io: std.Io,
        address: std.Io.net.IpAddress,
        options: Options,
    ) !*Listener {
        if (options.maximum_negotiations == 0 or
            options.maximum_negotiations > 1024 or
            options.maximum_pending_accepts == 0 or
            options.request_timeout_ms == 0)
        {
            return error.InvalidConfiguration;
        }

        const self = try allocator.create(Listener);
        errdefer allocator.destroy(self);

        const slots = try allocator.alloc(
            *conn.Connection,
            options.maximum_pending_accepts,
        );
        errdefer allocator.free(slots);

        var server = try address.listen(io, .{});
        errdefer server.deinit(io);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .options = options,
            .slots = slots,
            .accepted = .init(slots),
        };

        errdefer {
            self.accepted.close(io);
            self.group.cancel(io);

            while (self.accepted.getOneUncancelable(io)) |connection| {
                connection.destroy();
            } else |_| {}
        }

        for (0..options.maximum_negotiations) |_| {
            try self.group.concurrent(io, worker, .{self});
        }

        return self;
    }

    /// The caller owns the returned connection, even after the listener closes.
    pub fn accept(self: *Listener) !*conn.Connection {
        const connection = try self.accepted.getOne(self.io);
        self.releaseAccept();
        return connection;
    }

    fn reserveAccept(self: *Listener) bool {
        self.accept_mutex.lockUncancelable(self.io);
        defer self.accept_mutex.unlock(self.io);
        if (self.reserved_accepts == self.options.maximum_pending_accepts) return false;
        self.reserved_accepts += 1;
        return true;
    }

    fn releaseAccept(self: *Listener) void {
        self.accept_mutex.lockUncancelable(self.io);
        defer self.accept_mutex.unlock(self.io);
        std.debug.assert(self.reserved_accepts != 0);
        self.reserved_accepts -= 1;
    }

    pub fn close(self: *Listener) void {
        if (self.closed) return;

        self.closed = true;
        self.accepted.close(self.io);
        self.group.cancel(self.io);
        self.server.deinit(self.io);

        while (self.accepted.getOneUncancelable(self.io)) |connection| {
            connection.destroy();
        } else |_| {}
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
        const Result = union(enum) {
            done: anyerror!void,
            timeout: std.Io.Cancelable!void,
        };

        var results: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &results);
        defer select.cancelDiscard();

        try select.concurrent(
            .timeout,
            std.Io.sleep,
            .{
                self.io,
                std.Io.Duration.fromMilliseconds(self.options.request_timeout_ms),
                .awake,
            },
        );
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

        if (request.head.method == .GET and
            std.mem.eql(u8, request.head.target, "/v1/join"))
        {
            const provider = self.options.status_provider orelse
                return request.respond("", .{ .keep_alive = false });

            const status = provider.get(provider.context) catch
                return request.respond("", .{
                    .status = .service_unavailable,
                    .keep_alive = false,
                });

            var status_output: [maximum_status_response_size]u8 = undefined;
            const body = encodeStatus(status, &status_output) catch
                return request.respond("", .{
                    .status = .internal_server_error,
                    .keep_alive = false,
                });

            return request.respond(body, .{
                .keep_alive = false,
                .extra_headers = &.{.{
                    .name = "Content-Type",
                    .value = "application/json",
                }},
            });
        }

        if (request.head.method != .POST or
            !std.mem.startsWith(u8, request.head.target, "/v1/join/"))
        {
            return request.respond("", .{
                .status = .not_found,
                .keep_alive = false,
            });
        }

        const network_name = request.head.target[9..];

        if (network_name.len == 0) {
            return request.respond("Network ID must be uint64", .{
                .status = .bad_request,
                .keep_alive = false,
            });
        }

        for (network_name) |byte| {
            if (byte < '0' or byte > '9') {
                return request.respond("Network ID must be uint64", .{
                    .status = .bad_request,
                    .keep_alive = false,
                });
            }
        }

        _ = std.fmt.parseInt(u64, network_name, 10) catch {
            return request.respond("Network ID must be uint64", .{
                .status = .bad_request,
                .keep_alive = false,
            });
        };

        if ((request.head.content_length orelse 0) > maximum_sdp_size) {
            return request.respond("", .{
                .status = .payload_too_large,
                .keep_alive = false,
            });
        }

        const network_id = try self.allocator.dupe(u8, network_name);
        defer self.allocator.free(network_id);

        var transfer: [4096]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&transfer);

        const body = body_reader.allocRemaining(
            self.allocator,
            .limited(maximum_sdp_size),
        ) catch {
            return request.respond("", .{
                .status = .payload_too_large,
                .keep_alive = false,
            });
        };
        defer self.allocator.free(body);

        if (body.len == 0) {
            return request.respond("Missing SDP offer in request body", .{
                .status = .bad_request,
                .keep_alive = false,
            });
        }

        var random: [8]u8 = undefined;
        self.io.random(&random);

        const connection_id = std.mem.readInt(u64, &random, .little);

        if (!self.reserveAccept()) {
            return request.respond("Accept queue full", .{
                .status = .service_unavailable,
                .keep_alive = false,
            });
        }
        var accept_reserved = true;
        defer if (accept_reserved) self.releaseAccept();

        var connection_options = self.options.connection;
        connection_options.native.disable_trickle = true;

        const connection = try conn.Connection.create(
            self.allocator,
            self.io,
            .server,
            connection_id,
            network_id,
            connection_options,
        );

        var transferred = false;
        defer if (!transferred) connection.destroy();

        connection.applySignal(.{
            .kind = Signal.offer,
            .connection_id = connection_id,
            .network_id = network_id,
            .data = body,
        }) catch {
            return request.respond("Negotiation failed", .{
                .status = .bad_request,
                .keep_alive = false,
            });
        };

        var answered = false;

        while (!answered or !connection.ready()) {
            connection.prepareWait();
            if (try connection.pollNegotiation()) |event| {
                switch (event) {
                    .signal => |signal| {
                        if (!std.mem.eql(u8, signal.kind, Signal.answer) or answered) {
                            return error.UnexpectedSignal;
                        }

                        try request.respond(signal.data, .{
                            .keep_alive = false,
                            .extra_headers = &.{
                                .{
                                    .name = "Content-Type",
                                    .value = "application/sdp",
                                },
                            },
                        });

                        answered = true;
                    },

                    .message => return error.UnexpectedMessage,
                }
            }

            try connection.wait(true);
        }

        if (try self.accepted.put(self.io, &.{connection}, 0) == 0) unreachable;
        transferred = true;
        accept_reserved = false;
    }
};
fn encodeStatus(status: ServerStatus, output: []u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(status.name) or
        !std.unicode.utf8ValidateSlice(status.version) or
        !std.unicode.utf8ValidateSlice(status.level) or
        status.players > status.max_players)
    {
        return error.InvalidServerStatus;
    }

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"name\":");
    try writeJsonString(&writer, status.name);
    try writer.print(",\"protocol\":{d},\"version\":", .{status.protocol});
    try writeJsonString(&writer, status.version);
    try writer.writeAll(",\"level\":");
    try writeJsonString(&writer, status.level);
    try writer.print(",\"gameType\":{d},\"players\":{d},\"maxPlayers\":{d}}}", .{
        status.game_type,
        status.players,
        status.max_players,
    });
    return writer.buffered();
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\x08' => try writer.writeAll("\\b"),
        '\x0c' => try writer.writeAll("\\f"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...7, 11, 14...31 => try writer.print("\\u00{x:0>2}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

test "server status JSON is bounded and escaped" {
    var output: [maximum_status_response_size]u8 = undefined;
    const json = try encodeStatus(.{
        .name = "Nether \"Server\"\\One\n",
        .protocol = 800,
        .version = "1.21.0",
        .level = "Snowman ☃\t",
        .players = 3,
        .max_players = 20,
        .game_type = 1,
    }, &output);

    try std.testing.expectEqualStrings(
        "{\"name\":\"Nether \\\"Server\\\"\\\\One\\n\",\"protocol\":800,\"version\":\"1.21.0\",\"level\":\"Snowman ☃\\t\",\"gameType\":1,\"players\":3,\"maxPlayers\":20}",
        json,
    );

    try std.testing.expectError(error.InvalidServerStatus, encodeStatus(.{
        .name = "server",
        .protocol = 800,
        .version = "1.21.0",
        .level = "level",
        .players = 21,
        .max_players = 20,
        .game_type = 0,
    }, &output));

    var tiny: [1]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encodeStatus(.{
        .name = "server",
        .protocol = 800,
        .version = "1.21.0",
        .level = "level",
        .players = 0,
        .max_players = 20,
        .game_type = 0,
    }, &tiny));
}
