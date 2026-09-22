const std = @import("std");

const auth = @import("../auth/sdp.zig");
const Signal = @import("../protocol/signal.zig").Signal;
const conn = @import("../transport/connection.zig");
const maximum_sdp_size = @import("client.zig").maximum_sdp_size;

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
    maximum_http_workers: usize = 32,
    maximum_pending_accepts: usize = 64,
    request_timeout_ms: u32 = 15000,
    status_provider: ?StatusProvider = null,
    trace: bool = false,
};

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
    active_negotiations: usize = 0,
    closed: bool = false,

    pub fn listen(
        allocator: std.mem.Allocator,
        io: std.Io,
        address: std.Io.net.IpAddress,
        options: Options,
    ) !*Listener {
        if (options.maximum_negotiations == 0 or
            options.maximum_negotiations > 1024 or
            options.maximum_http_workers == 0 or
            options.maximum_http_workers > 4096 or
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

        var actual_options = options;
        if (actual_options.connection.identity == null and
            actual_options.connection.server_identity_key == null)
        {
            actual_options.connection.server_identity_key =
                auth.KeyPair.generate(io);
        }

        self.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .options = actual_options,
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

        const worker_count = @max(
            actual_options.maximum_http_workers,
            actual_options.maximum_negotiations,
        );
        for (0..worker_count) |_| {
            try self.group.concurrent(io, worker, .{self});
        }

        return self;
    }

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

    fn reserveNegotiation(self: *Listener) bool {
        self.accept_mutex.lockUncancelable(self.io);
        defer self.accept_mutex.unlock(self.io);
        if (self.active_negotiations >= self.options.maximum_negotiations)
            return false;
        self.active_negotiations += 1;
        return true;
    }

    fn releaseNegotiation(self: *Listener) void {
        self.accept_mutex.lockUncancelable(self.io);
        defer self.accept_mutex.unlock(self.io);
        std.debug.assert(self.active_negotiations != 0);
        self.active_negotiations -= 1;
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

    fn trace(self: *Listener, comptime format: []const u8, args: anytype) void {
        if (self.options.trace) std.debug.print("nethernet HTTP: " ++ format ++ "\n", args);
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
                else => {
                    self.trace("request failed ({s})", .{@errorName(err)});
                    continue;
                },
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
            self.trace("GET /v1/join received", .{});
            const provider = self.options.status_provider orelse {
                self.trace("GET /v1/join HTTP 503 (no status provider)", .{});
                return request.respond("", .{
                    .status = .service_unavailable,
                    .keep_alive = false,
                });
            };

            const status = provider.get(provider.context) catch |err| {
                self.trace("GET /v1/join HTTP 503 (status provider: {s})", .{@errorName(err)});
                return request.respond("", .{
                    .status = .service_unavailable,
                    .keep_alive = false,
                });
            };

            var status_output: [maximum_status_response_size]u8 = undefined;
            const body = encodeStatus(status, &status_output) catch |err| {
                self.trace("GET /v1/join HTTP 500 (status encoding: {s})", .{@errorName(err)});
                return request.respond("", .{
                    .status = .internal_server_error,
                    .keep_alive = false,
                });
            };

            self.trace("GET /v1/join HTTP 200, status bytes={d}", .{body.len});
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
            self.trace("HTTP 404 (unknown route)", .{});
            return request.respond("", .{
                .status = .not_found,
                .keep_alive = false,
            });
        }

        const network_name = request.head.target[9..];
        self.trace("POST /v1/join/{{networkId}} received", .{});

        if (!conn.validNetworkId(network_name)) {
            self.trace("POST HTTP 400 (invalid network ID)", .{});
            return request.respond("Invalid network ID", .{
                .status = .bad_request,
                .keep_alive = false,
            });
        }

        if ((request.head.content_length orelse 0) > maximum_sdp_size) {
            self.trace("POST HTTP 413 (content length)", .{});
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
        ) catch |err| {
            self.trace("POST HTTP 413 (body read: {s})", .{@errorName(err)});
            return request.respond("", .{
                .status = .payload_too_large,
                .keep_alive = false,
            });
        };
        defer self.allocator.free(body);

        if (body.len == 0) {
            self.trace("POST HTTP 400 (empty offer)", .{});
            return request.respond("Missing SDP offer in request body", .{
                .status = .bad_request,
                .keep_alive = false,
            });
        }

        if (self.options.trace) {
            const offer_summary = summarizeSdp(body);
            self.trace("offer bytes={d}, identity={s}, candidates={d} (host={d}, srflx={d}, relay={d}, other={d})", .{
                body.len,
                if (offer_summary.identity) "present" else "missing",
                offer_summary.candidates,
                offer_summary.host,
                offer_summary.srflx,
                offer_summary.relay,
                offer_summary.other,
            });
        }

        var random: [8]u8 = undefined;
        self.io.random(&random);

        const connection_id = std.mem.readInt(u64, &random, .little);

        if (!self.reserveAccept()) {
            self.trace("POST HTTP 503 (accept queue full)", .{});
            return request.respond("Accept queue full", .{
                .status = .service_unavailable,
                .keep_alive = false,
            });
        }
        var accept_reserved = true;
        defer if (accept_reserved) self.releaseAccept();

        if (!self.reserveNegotiation()) {
            self.trace("POST HTTP 503 (negotiation capacity)", .{});
            return request.respond("Negotiation capacity reached", .{
                .status = .service_unavailable,
                .keep_alive = false,
            });
        }
        defer self.releaseNegotiation();

        var connection_options = self.options.connection;
        connection_options.native.disable_trickle = true;
        connection_options.trace = connection_options.trace or self.options.trace;

        const connection = conn.Connection.create(
            self.allocator,
            self.io,
            .server,
            connection_id,
            network_id,
            connection_options,
        ) catch |err| {
            self.trace("peer creation failed ({s})", .{@errorName(err)});
            return err;
        };
        self.trace("peer created", .{});

        var transferred = false;
        defer if (!transferred) connection.destroy();

        connection.applySignal(.{
            .kind = Signal.offer,
            .connection_id = connection_id,
            .network_id = network_id,
            .data = body,
        }) catch |err| {
            self.trace("offer rejected ({s}); HTTP 400", .{@errorName(err)});
            return request.respond("Negotiation failed", .{
                .status = .bad_request,
                .keep_alive = false,
            });
        };

        var answered = false;
        var previous_state = connection.state();
        var previous_diagnostics: ?conn.Diagnostics = if (self.options.trace) connection.diagnostics() else null;
        if (previous_diagnostics) |diagnostics| {
            self.trace("peer={s}, ICE={s}, gathering={s}, reliable={s}, unreliable={s}", .{
                @tagName(previous_state),
                @tagName(diagnostics.ice_state),
                @tagName(diagnostics.ice_gathering_state),
                @tagName(diagnostics.reliable.state),
                @tagName(diagnostics.unreliable.state),
            });
        }

        while (!answered or !connection.ready()) {
            connection.prepareWait();
            if (previous_diagnostics) |previous| {
                const state = connection.state();
                const diagnostics = connection.diagnostics();
                if (state != previous_state or
                    diagnostics.ice_state != previous.ice_state or
                    diagnostics.ice_gathering_state != previous.ice_gathering_state or
                    diagnostics.reliable.state != previous.reliable.state or
                    diagnostics.unreliable.state != previous.unreliable.state)
                {
                    self.trace("peer={s}, ICE={s}, gathering={s}, reliable={s}, unreliable={s}", .{
                        @tagName(state),
                        @tagName(diagnostics.ice_state),
                        @tagName(diagnostics.ice_gathering_state),
                        @tagName(diagnostics.reliable.state),
                        @tagName(diagnostics.unreliable.state),
                    });
                    if (diagnostics.ice_state == .connected or diagnostics.ice_state == .completed) {
                        var local: [256]u8 = undefined;
                        var remote: [256]u8 = undefined;
                        if (connection.selectedIceAddresses(&local, &remote)) |selected| {
                            if (selected) |pair| self.trace("selected ICE local={s}, remote={s}", .{ pair.local, pair.remote });
                        } else |_| {}
                    }
                    previous_state = state;
                    previous_diagnostics = diagnostics;
                }
            }
            if (try connection.pollNegotiation()) |event| {
                switch (event) {
                    .signal => |signal| {
                        if (!std.mem.eql(u8, signal.kind, Signal.answer) or answered) {
                            return error.UnexpectedSignal;
                        }

                        if (self.options.trace) {
                            const answer_summary = summarizeSdp(signal.data);
                            self.trace("answer bytes={d}, identity={s}, candidates={d} (host={d}, srflx={d}, relay={d}, other={d}); HTTP 200 application/sdp", .{
                                signal.data.len,
                                if (answer_summary.identity) "present" else "missing",
                                answer_summary.candidates,
                                answer_summary.host,
                                answer_summary.srflx,
                                answer_summary.relay,
                                answer_summary.other,
                            });
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

        if (try self.accepted.put(self.io, &.{connection}, 0) == 0)
            return error.ConnectionClosed;
        transferred = true;
        accept_reserved = false;
        self.trace("both data channels open; connection accepted", .{});
    }
};

const SdpSummary = struct {
    identity: bool = false,
    candidates: usize = 0,
    host: usize = 0,
    srflx: usize = 0,
    relay: usize = 0,
    other: usize = 0,
};

fn summarizeSdp(sdp: []const u8) SdpSummary {
    var result: SdpSummary = .{};
    var lines = std.mem.splitScalar(u8, sdp, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "a=identity:")) result.identity = true;
        if (!std.mem.startsWith(u8, line, "a=candidate:")) continue;
        result.candidates += 1;
        const type_start = std.mem.indexOf(u8, line, " typ ") orelse {
            result.other += 1;
            continue;
        };
        var fields = std.mem.tokenizeAny(u8, line[type_start + 5 ..], " \t\r");
        const kind = fields.next() orelse "";
        if (std.mem.eql(u8, kind, "host")) {
            result.host += 1;
        } else if (std.mem.eql(u8, kind, "srflx")) {
            result.srflx += 1;
        } else if (std.mem.eql(u8, kind, "relay")) {
            result.relay += 1;
        } else {
            result.other += 1;
        }
    }
    return result;
}

test "SDP trace summary exposes only identity presence and candidate counts" {
    const summary = summarizeSdp(
        "a=identity:secret\r\n" ++
            "a=candidate:1 1 UDP 1 127.0.0.1 1 typ host\r\n" ++
            "a=candidate:2 1 UDP 1 127.0.0.1 2 typ srflx\r\n" ++
            "a=candidate:3 1 UDP 1 127.0.0.1 3 typ relay\r\n" ++
            "a=candidate:4 1 UDP 1 127.0.0.1 4 typ prflx\r\n",
    );
    try std.testing.expect(summary.identity);
    try std.testing.expectEqual(@as(usize, 4), summary.candidates);
    try std.testing.expectEqual(@as(usize, 1), summary.host);
    try std.testing.expectEqual(@as(usize, 1), summary.srflx);
    try std.testing.expectEqual(@as(usize, 1), summary.relay);
    try std.testing.expectEqual(@as(usize, 1), summary.other);
}

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

    const expected =
        "{\"name\":\"Nether \\\"Server\\\"\\\\One\\n\"," ++
        "\"protocol\":800,\"version\":\"1.21.0\"," ++
        "\"level\":\"Snowman ☃\\t\",\"gameType\":1," ++
        "\"players\":3,\"maxPlayers\":20}";
    try std.testing.expectEqualStrings(expected, json);

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
