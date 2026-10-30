const std = @import("std");

const auth = @import("../auth/sdp.zig");
const Discovery = @import("../discovery/client.zig").Discovery;
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
};

pub const Listener = struct {
    allocator: std.mem.Allocator,
    discovery: *Discovery,
    options: Options,
    pending: []?*conn.Connection,
    closed: bool = false,
    wakeup: wake.Wakeup = .{},
    rejected_negotiations: u64 = 0,
    offer_tokens: u32 = 0,
    offers_refilled: ?std.Io.Timestamp = null,

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
        if (actual_options.connection.identity == null and
            actual_options.connection.server_identity_key == null)
        {
            actual_options.connection.server_identity_key =
                auth.KeyPair.generate(discovery.io);
        }

        self.* = .{
            .allocator = allocator,
            .discovery = discovery,
            .options = actual_options,
            .pending = pending,
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
                    .signal => |signal| self.discovery.send(signal) catch {
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

        if (!self.takeOffer()) {
            self.rejected_negotiations +|= 1;
            return;
        }

        var connection_options = self.options.connection;

        var local_buf: [20]u8 = undefined;
        connection_options.local_network_id = try std.fmt.bufPrint(
            &local_buf,
            "{d}",
            .{self.discovery.id},
        );

        const connection = try conn.Connection.create(
            self.allocator,
            self.discovery.io,
            .server,
            signal.connection_id,
            signal.network_id,
            connection_options,
        );
        errdefer connection.destroy();

        connection.applySignal(signal) catch |err| {
            self.report(connection, err) catch {};
            connection.destroy();
            return;
        };

        connection.peer.subscribe(self.notifier());
        slot.* = connection;
    }

    fn takeOffer(self: *Listener) bool {
        const rate = self.options.maximum_offers_per_second;
        if (rate == 0) return true;
        if (self.offer_tokens == 0) {
            const now = std.Io.Clock.awake.now(self.discovery.io);
            const elapsed: u64 = if (self.offers_refilled) |last| @intCast(@max(last.durationTo(now).toMilliseconds(), 0)) else 1000;
            const refill = @min(@as(u64, rate), elapsed * rate / 1000);
            if (refill == 0) return false;
            self.offer_tokens = @intCast(refill);
            self.offers_refilled = now;
        }
        self.offer_tokens -= 1;
        return true;
    }

    fn report(
        self: *Listener,
        connection: *conn.Connection,
        err: anyerror,
    ) !void {
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

test "LAN offers are rate limited across every sender" {
    var discovery: Discovery = undefined;
    discovery.io = std.testing.io;
    var listener: Listener = undefined;
    listener.discovery = &discovery;
    listener.options = .{ .maximum_offers_per_second = 2 };
    listener.offer_tokens = 0;
    listener.offers_refilled = null;
    try std.testing.expect(listener.takeOffer());
    try std.testing.expect(listener.takeOffer());
    try std.testing.expect(!listener.takeOffer());
    listener.options.maximum_offers_per_second = 0;
    try std.testing.expect(listener.takeOffer());
}
