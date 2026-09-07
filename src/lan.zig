const std = @import("std");
const Discovery = @import("discovery.zig").Discovery;
const conn = @import("connection.zig");
const Signal = @import("signal.zig").Signal;
pub const Options = struct { connection: conn.Options = .{}, maximum_negotiations: usize = 64 };

/// Single-owner listener. Discovery is borrowed and must outlive the listener.
/// accept/pollAccept drive signaling for all pending connections. Accepted
/// connections transfer to the caller and survive listener shutdown.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    discovery: *Discovery,
    options: Options,
    pending: []?*conn.Connection,
    closed: bool = false,

    pub fn listen(a: std.mem.Allocator, discovery: *Discovery, options: Options) !*Listener {
        if (options.maximum_negotiations == 0) return error.InvalidConfiguration;
        const self = try a.create(Listener);
        errdefer a.destroy(self);
        const pending = try a.alloc(?*conn.Connection, options.maximum_negotiations);
        @memset(pending, null);
        self.* = .{ .allocator = a, .discovery = discovery, .options = options, .pending = pending };
        return self;
    }
    pub fn close(self: *Listener) void {
        if (self.closed) return;
        self.closed = true;
        for (self.pending) |*slot| if (slot.*) |connection| {
            connection.destroy();
            slot.* = null;
        };
    }
    pub fn destroy(self: *Listener) void {
        self.close();
        self.allocator.free(self.pending);
        self.allocator.destroy(self);
    }
    pub fn accept(self: *Listener) !*conn.Connection {
        while (true) if (try self.pollAccept()) |connection| return connection;
    }
    pub fn pollAccept(self: *Listener) !?*conn.Connection {
        if (self.closed) return error.ConnectionClosed;
        if (try self.discovery.poll(1)) |signal| try self.handle(signal);
        for (self.pending) |*slot| if (slot.*) |connection| {
            if (connection.ready()) {
                slot.* = null;
                return connection;
            }
            const event = connection.pollNegotiation() catch |err| {
                self.report(connection, err) catch {};
                connection.destroy();
                slot.* = null;
                continue;
            };
            if (event) |value| switch (value) {
                .signal => |signal| self.discovery.send(signal) catch |err| {
                    connection.destroy();
                    slot.* = null;
                    return err;
                },
                .message => {
                    connection.destroy();
                    slot.* = null;
                    return error.UnexpectedMessage;
                },
            };
        };
        return null;
    }
    fn handle(self: *Listener, signal: Signal) !void {
        var free: ?*?*conn.Connection = null;
        for (self.pending) |*slot| {
            if (slot.*) |connection| {
                if (connection.id == signal.connection_id and std.mem.eql(u8, connection.remote_id, signal.network_id)) {
                    if (std.mem.eql(u8, signal.kind, Signal.offer)) return; // Duplicate cannot replace live negotiation.
                    connection.applySignal(signal) catch |err| {
                        self.report(connection, err) catch {};
                        connection.destroy();
                        slot.* = null;
                    };
                    return;
                }
            } else if (free == null) {
                free = slot;
            }
        }
        if (!std.mem.eql(u8, signal.kind, Signal.offer)) return;
        const slot = free orelse return; // NOOP: Ignore new offers when all negotiation slots are occupied.
        var actual = self.options.connection;
        var local_name: [20]u8 = undefined;
        actual.local_network_id = try std.fmt.bufPrint(&local_name, "{d}", .{self.discovery.id});
        const connection = try conn.Connection.create(self.allocator, self.discovery.io, .server, signal.connection_id, signal.network_id, actual);
        errdefer connection.destroy();
        connection.applySignal(signal) catch |err| {
            self.report(connection, err) catch {};
            connection.destroy();
            return;
        };
        slot.* = connection;
    }
    fn report(self: *Listener, connection: *conn.Connection, err: anyerror) !void {
        const code: []const u8 = switch (err) {
            error.InvalidIdentity, error.IdentityNotAllowed, error.SignatureVerificationFailed, error.ExpiredIdentity => "37",
            error.Timeout => "15",
            error.MalformedSignal, error.WebRtcFailure => "13",
            else => "35",
        };
        try self.discovery.send(.{ .kind = Signal.failure, .connection_id = connection.id, .network_id = connection.remote_id, .data = code });
    }
};

pub fn dial(a: std.mem.Allocator, discovery: *Discovery, target: u64, options: conn.Options) !*conn.Connection {
    var name: [20]u8 = undefined;
    const remote = try std.fmt.bufPrint(&name, "{d}", .{target});
    var random: [8]u8 = undefined;
    discovery.io.random(&random);
    var actual = options;
    var local_name: [20]u8 = undefined;
    actual.local_network_id = try std.fmt.bufPrint(&local_name, "{d}", .{discovery.id});
    const id = if (options.connection_id != 0) options.connection_id else std.mem.readInt(u64, &random, .little);
    const connection = try conn.Connection.create(a, discovery.io, .client, id, remote, actual);
    errdefer connection.destroy();
    try connection.start();
    while (!connection.ready()) {
        if (try discovery.poll(1)) |signal| {
            if (signal.connection_id == connection.id and std.mem.eql(u8, signal.network_id, connection.remote_id)) try connection.applySignal(signal);
        }
        if (try connection.pollNegotiation()) |event| switch (event) {
            .signal => |signal| try discovery.send(signal),
            .message => return error.UnexpectedMessage,
        };
    }
    return connection;
}
