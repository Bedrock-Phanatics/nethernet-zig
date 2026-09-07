const std = @import("std");

const wake = @import("wakeup.zig");
const Discovery = @import("discovery.zig").Discovery;
const conn = @import("connection.zig");
const Signal = @import("signal.zig").Signal;

pub const Options = struct {
    connection: conn.Options = .{},
    maximum_negotiations: usize = 64,
};

/// Discovery must outlive the listener. The caller owns accepted connections.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    discovery: *Discovery,
    options: Options,
    pending: []?*conn.Connection,
    closed: bool = false,
    wakeup: wake.Wakeup = .{},

    pub fn listen(
        allocator: std.mem.Allocator,
        discovery: *Discovery,
        options: Options,
    ) !*Listener {
        if (options.maximum_negotiations == 0) {
            return error.InvalidConfiguration;
        }

        const self = try allocator.create(Listener);
        errdefer allocator.destroy(self);

        const pending = try allocator.alloc(
            ?*conn.Connection,
            options.maximum_negotiations,
        );
        @memset(pending, null);

        self.* = .{
            .allocator = allocator,
            .discovery = discovery,
            .options = options,
            .pending = pending,
        };

        discovery.subscribe(&self.wakeup);
        return self;
    }

    pub fn close(self: *Listener) void {
        if (self.closed) return;
        self.closed = true;
        self.wakeup.signal(self.discovery.io);
        self.discovery.subscribe(null);

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
        while (true) {
            self.wakeup.prepare();
            if (try self.pollAccept()) |connection| return connection;
            var deadline = self.discovery.tickDeadline();
            var pending_work = false;
            for (self.pending) |slot| {
                if (slot) |connection| {
                    deadline = wake.earliest(deadline, connection.waitDeadline());
                    pending_work = pending_work or connection.peer.hasPending(true) or connection.ready();
                }
            }
            try self.discovery.io.checkCancel();
            if (!pending_work) try self.wakeup.wait(self.discovery.io, deadline);
        }
    }

    pub fn pollAccept(self: *Listener) !?*conn.Connection {
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
                    .signal => |signal| {
                        self.discovery.send(signal) catch |err| {
                            connection.destroy();
                            slot.* = null;
                            return err;
                        };
                    },

                    .message => {
                        connection.destroy();
                        slot.* = null;
                        return error.UnexpectedMessage;
                    },
                }
            }
        }

        return null;
    }

    fn handle(self: *Listener, signal: Signal) !void {
        var free_slot: ?*?*conn.Connection = null;

        for (self.pending) |*slot| {
            if (slot.*) |connection| {
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

        const slot = free_slot orelse return;

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

        connection.peer.subscribe(&self.wakeup);
        slot.* = connection;
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
    discovery.subscribe(&wakeup);
    defer discovery.subscribe(null);
    connection.peer.subscribe(&wakeup);
    defer connection.peer.subscribe(null);
    try connection.start();

    while (!connection.ready()) {
        wakeup.prepare();
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
            try wakeup.wait(discovery.io, wake.earliest(discovery.tickDeadline(), connection.waitDeadline()));
        }
    }

    return connection;
}
