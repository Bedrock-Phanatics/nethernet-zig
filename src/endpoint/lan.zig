const std = @import("std");

const auth = @import("../auth/sdp.zig");
const codec = @import("../discovery/codec.zig");
const discovery_client = @import("../discovery/client.zig");
const Discovery = discovery_client.Discovery;
const wake = @import("../internal/wakeup.zig");
const Signal = @import("../protocol/signal.zig").Signal;
const conn = @import("../transport/connection.zig");

pub const Options = struct {
    connection: conn.Options = .{},
    maximum_negotiations: usize = 64,
    maximum_negotiations_per_peer: usize = 4,
    /// New offers accepted per second across all peers, 0 is unlimited. Sender IDs are chosen by the sender, so
    /// this is what bounds the native peers and signature checks a LAN flood costs the polling thread.
    maximum_offers_per_second: u32 = 16,
    /// Signaled on discovery traffic and negotiation progress instead of the listener's own wakeup.
    wakeup: ?*wake.Wakeup = null,
    /// Vanilla LAN hosts answer without an identity, which keeps an answer within one datagram for consoles.
    /// go-nethernet before its LAN fit change rejects such answers, so sign them for those clients.
    sign_answers: bool = false,
};

pub const Listener = struct {
    allocator: std.mem.Allocator,
    discovery: *Discovery,
    options: Options,
    pending: []?*conn.Connection,
    closed: bool = false,
    wakeup: wake.Wakeup = .{},
    rejected_negotiations: u64 = 0,
    offers: discovery_client.RateLimit,

    pub fn listen(
        allocator: std.mem.Allocator,
        discovery: *Discovery,
        options: Options,
    ) !*Listener {
        try conn.validateServerIdentity(options.connection);
        if (options.maximum_negotiations == 0 or
            options.maximum_negotiations_per_peer == 0 or
            options.maximum_negotiations_per_peer > options.maximum_negotiations)
        {
            return error.InvalidConfiguration;
        }

        const self = try allocator.create(Listener);
        errdefer allocator.destroy(self);

        const pending = try allocator.alloc(
            ?*conn.Connection,
            options.maximum_negotiations,
        );
        @memset(pending, null);

        var actual_options = options;
        if (options.sign_answers and actual_options.connection.identity == null and
            actual_options.connection.server_identity_key == null)
        {
            actual_options.connection.server_identity_key = auth.KeyPair.generate(discovery.io);
        }

        self.* = .{
            .allocator = allocator,
            .discovery = discovery,
            .options = actual_options,
            .pending = pending,
            .offers = .{ .rate = options.maximum_offers_per_second },
        };

        discovery.subscribe(self.notifier());
        return self;
    }

    fn notifier(self: *Listener) *wake.Wakeup {
        return self.options.wakeup orelse &self.wakeup;
    }

    pub fn close(self: *Listener) void {
        if (self.closed) return;
        self.closed = true;
        self.notifier().signal(self.discovery.io);
        self.discovery.unsubscribe(self.notifier());

        for (self.pending) |*slot| {
            if (slot.*) |connection| {
                connection.destroy();
                slot.* = null;
            }
        }
    }

    pub fn destroy(self: *Listener) void {
        self.close();
        self.allocator.free(self.pending);
        self.allocator.destroy(self);
    }

    pub fn accept(self: *Listener) !*conn.Connection {
        try self.discovery.beginOperation();
        defer self.discovery.endOperation();
        while (true) {
            const token = self.notifier().prepare();
            if (try self.pollAcceptOwned()) |connection| return connection;
            var deadline = self.discovery.tickDeadline();
            var pending_work = false;
            for (self.pending) |slot| {
                if (slot) |connection| {
                    deadline = wake.earliest(deadline, connection.waitDeadline());
                    pending_work = pending_work or connection.peer.hasPending(true) or connection.ready();
                }
            }
            try self.discovery.io.checkCancel();
            if (!pending_work) try self.notifier().wait(self.discovery.io, token, deadline);
        }
    }

    pub fn pollAccept(self: *Listener) !?*conn.Connection {
        try self.discovery.beginOperation();
        defer self.discovery.endOperation();
        const accepted = try self.pollAcceptOwned();
        // Each poll handles one event per negotiation, so wake the host again while more are queued.
        if (accepted == null) for (self.pending) |slot| {
            const connection = slot orelse continue;
            if (connection.peer.hasPending(true) or connection.ready()) {
                self.notifier().signal(self.discovery.io);
                break;
            }
        };
        return accepted;
    }

    pub fn rejectedNegotiations(self: *const Listener) u64 {
        return self.rejected_negotiations;
    }

    fn pollAcceptOwned(self: *Listener) !?*conn.Connection {
        if (self.closed) return error.ConnectionClosed;

        if (try self.discovery.poll(0)) |signal| {
            try self.handle(signal);
        }

        var fitted: [maximum_signal_length]u8 = undefined;
        for (self.pending) |*slot| {
            const connection = slot.* orelse continue;

            if (connection.ready()) {
                slot.* = null;
                connection.peer.subscribe(null);
                return connection;
            }

            const event = connection.pollNegotiation() catch |err| {
                self.report(connection, err) catch {};
                connection.destroy();
                slot.* = null;
                continue;
            };

            if (event) |value| {
                switch (value) {
                    // One peer failing must not hold up the others
                    .signal => |signal| self.discovery.send(fitSignal(signal, &fitted)) catch {
                        connection.destroy();
                        slot.* = null;
                    },

                    .message => {
                        connection.destroy();
                        slot.* = null;
                    },
                }
            }
        }

        return null;
    }

    fn handle(self: *Listener, signal: Signal) !void {
        var free_slot: ?*?*conn.Connection = null;
        var peer_pending: usize = 0;

        for (self.pending) |*slot| {
            if (slot.*) |connection| {
                if (std.mem.eql(u8, connection.remote_id, signal.network_id))
                    peer_pending += 1;

                const matches_connection =
                    connection.id == signal.connection_id and
                    std.mem.eql(u8, connection.remote_id, signal.network_id);

                if (!matches_connection) continue;

                if (std.mem.eql(u8, signal.kind, Signal.offer)) return;

                connection.applySignal(signal) catch |err| {
                    self.report(connection, err) catch {};
                    connection.destroy();
                    slot.* = null;
                };

                return;
            }

            if (free_slot == null) {
                free_slot = slot;
            }
        }

        if (!std.mem.eql(u8, signal.kind, Signal.offer)) return;

        if (peer_pending >= self.options.maximum_negotiations_per_peer) {
            self.rejected_negotiations +|= 1;
            return;
        }

        const slot = free_slot orelse {
            self.rejected_negotiations +|= 1;
            return;
        };

        if (!self.offers.take(self.discovery.io)) {
            self.rejected_negotiations +|= 1;
            return;
        }

        var connection_options = self.options.connection;
        // Vanilla hosts send their candidates in the answer, a lost LAN candidate packet can't stall the join.
        connection_options.native.disable_trickle = true;
        connection_options.send_identity = self.options.sign_answers;

        var local_buf: [20]u8 = undefined;
        connection_options.local_network_id = try std.fmt.bufPrint(
            &local_buf,
            "{d}",
            .{self.discovery.id},
        );

        // One offer that can't get a peer must not end accepting for everyone else.
        const connection = conn.Connection.create(
            self.allocator,
            self.discovery.io,
            .server,
            signal.connection_id,
            signal.network_id,
            connection_options,
        ) catch {
            self.rejected_negotiations +|= 1;
            return;
        };

        connection.applySignal(signal) catch |err| {
            self.report(connection, err) catch {};
            connection.destroy();
            return;
        };

        connection.peer.subscribe(self.notifier());
        slot.* = connection;
    }

    fn report(
        self: *Listener,
        connection: *conn.Connection,
        err: anyerror,
    ) !void {
        // The peer already gave up, answering its error with another is pointless.
        if (err == error.RemoteFailure) return;
        const code: []const u8 = switch (err) {
            error.InvalidIdentity,
            error.IdentityNotAllowed,
            error.SignatureVerificationFailed,
            error.ExpiredIdentity,
            => "37",

            error.Timeout => "15",

            error.MalformedSignal,
            error.WebRtcFailure,
            => "13",

            error.NoLocalIceCandidate => "5",

            else => "35",
        };

        try self.discovery.send(.{
            .kind = Signal.failure,
            .connection_id = connection.id,
            .network_id = connection.remote_id,
            .data = code,
        });
    }
};

pub fn dial(
    allocator: std.mem.Allocator,
    discovery: *Discovery,
    target: u64,
    options: conn.Options,
) !*conn.Connection {
    try discovery.beginOperation();
    defer discovery.endOperation();

    var remote_buf: [20]u8 = undefined;
    const remote_id = try std.fmt.bufPrint(&remote_buf, "{d}", .{target});

    var local_buf: [20]u8 = undefined;
    const local_id = try std.fmt.bufPrint(&local_buf, "{d}", .{discovery.id});

    var connection_options = options;
    connection_options.local_network_id = local_id;
    // Vanilla hosts answer without an identity over LAN; one that is sent is still verified.
    if (options.verify_server == null) connection_options.allow_anonymous = true;

    var random: [8]u8 = undefined;
    discovery.io.random(&random);

    const connection_id = if (options.connection_id != 0)
        options.connection_id
    else
        std.mem.readInt(u64, &random, .little);

    const connection = try conn.Connection.create(
        allocator,
        discovery.io,
        .client,
        connection_id,
        remote_id,
        connection_options,
    );
    errdefer connection.destroy();

    var wakeup: wake.Wakeup = .{};
    const previous_subscriber = discovery.replaceSubscriber(&wakeup);
    defer discovery.restoreSubscriber(&wakeup, previous_subscriber);
    connection.peer.subscribe(&wakeup);
    defer connection.peer.subscribe(null);
    try connection.start();

    while (!connection.ready()) {
        const token = wakeup.prepare();
        if (try discovery.poll(0)) |signal| {
            const matches_connection =
                signal.connection_id == connection.id and
                std.mem.eql(u8, signal.network_id, connection.remote_id);

            if (matches_connection) {
                try connection.applySignal(signal);
            }
        }

        if (try connection.pollNegotiation()) |event| {
            switch (event) {
                .signal => |signal| try discovery.send(signal),
                .message => return error.UnexpectedMessage,
            }
        }
        try discovery.io.checkCancel();
        if (!connection.ready() and !connection.peer.hasPending(true)) {
            try wakeup.wait(discovery.io, token, wake.earliest(discovery.tickDeadline(), connection.waitDeadline()));
        }
    }

    return connection;
}

/// Vanilla declares at most this much message data, and Xbox consoles lose an answer split into IP fragments.
const maximum_signal_length = codec.maximum_declared_message_data;

/// Drops the last candidates until the signal fits one discovery datagram, keeping at least one.
fn fitSignal(signal: Signal, buffer: *[maximum_signal_length]u8) Signal {
    const limit = maximum_signal_length - (signal.kind.len + 2 + std.fmt.count("{d}", .{signal.connection_id}));
    if (signal.data.len <= limit) return signal;

    var keep = candidateCount(signal.data);
    var size = signal.data.len;
    while (keep > 1 and size > limit) {
        keep -= 1;
        size -= candidateLine(signal.data, keep).len;
    }
    if (size > limit) return signal;

    var length: usize = 0;
    var seen: usize = 0;
    var lines: Lines = .{ .data = signal.data };
    while (lines.next()) |line| {
        if (isCandidate(line)) {
            defer seen += 1;
            if (seen >= keep) continue;
        }
        @memcpy(buffer[length..][0..line.len], line);
        length += line.len;
    }
    var fitted = signal;
    fitted.data = buffer[0..length];
    return fitted;
}

const Lines = struct {
    data: []const u8,
    start: usize = 0,

    /// Each line with its ending.
    fn next(self: *Lines) ?[]const u8 {
        if (self.start == self.data.len) return null;
        const end = if (std.mem.indexOfScalarPos(u8, self.data, self.start, '\n')) |newline| newline + 1 else self.data.len;
        defer self.start = end;
        return self.data[self.start..end];
    }
};

fn isCandidate(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "a=candidate:");
}

fn candidateCount(sdp: []const u8) usize {
    var count: usize = 0;
    var lines: Lines = .{ .data = sdp };
    while (lines.next()) |line| count += @intFromBool(isCandidate(line));
    return count;
}

fn candidateLine(sdp: []const u8, index: usize) []const u8 {
    var seen: usize = 0;
    var lines: Lines = .{ .data = sdp };
    while (lines.next()) |line| {
        if (!isCandidate(line)) continue;
        if (seen == index) return line;
        seen += 1;
    }
    unreachable;
}

test "answers drop their last candidates to fit one datagram" {
    const head = "v=0\r\na=x:" ++ @as([950]u8, @splat('y')) ++ "\r\n";
    const first = "a=candidate:1 1 udp 2130706431 192.168.1.2 50000 typ host\r\n";
    const second = "a=candidate:2 1 udp 2130706175 fd00::2 50001 typ host\r\n";
    const third = "a=candidate:3 1 udp 2130705919 10.0.0.2 50002 typ host\r\n";
    const tail = "a=end-of-candidates\r\n";
    var buffer: [maximum_signal_length]u8 = undefined;

    const short: Signal = .{ .kind = Signal.answer, .connection_id = 7, .data = head ++ first ++ tail };
    try std.testing.expectEqualStrings(short.data, fitSignal(short, &buffer).data);

    const long: Signal = .{ .kind = Signal.answer, .connection_id = 7, .data = head ++ first ++ second ++ third ++ tail };
    const fitted = fitSignal(long, &buffer);
    try std.testing.expectEqualStrings(head ++ first ++ second ++ tail, fitted.data);
    try std.testing.expect(Signal.answer.len + 3 + fitted.data.len <= maximum_signal_length);

    const huge: Signal = .{ .kind = Signal.answer, .connection_id = 7, .data = head ++ @as([400]u8, @splat('y')) ++ first ++ second };
    try std.testing.expectEqualStrings(huge.data, fitSignal(huge, &buffer).data);
}

test "LAN offers are rate limited across every sender" {
    var offers: discovery_client.RateLimit = .{ .rate = 2 };
    try std.testing.expect(offers.take(std.testing.io));
    try std.testing.expect(offers.take(std.testing.io));
    try std.testing.expect(!offers.take(std.testing.io));
    var unlimited: discovery_client.RateLimit = .{ .rate = 0 };
    try std.testing.expect(unlimited.take(std.testing.io));
}
