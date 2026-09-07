const std = @import("std");
const native = @import("peer.zig");
const framing = @import("framing.zig");
const Signal = @import("signal.zig").Signal;
const auth = @import("sdp_identity.zig");
const jwt = @import("identity.zig");

pub const Role = enum { client, server };
pub const Address = struct { network_id: []const u8, connection_id: u64 };
pub const Message = struct { reliability: framing.Reliability, data: []const u8 };
pub const Options = struct {
    connection_id: u64 = 0,
    local_network_id: []const u8 = "",
    native: native.Options = .{},
    maximum_message_size: usize = framing.default_maximum_message_size,
    negotiation_timeout_ms: u32 = 15000,
    connection_timeout_ms: u32 = 10000,
    reassembly_timeout_ms: u32 = 30000,
    allow_anonymous: bool = false,
    identity: ?auth.Identity = null,
    verify_client: ?auth.Verifier = null,
};
pub const Event = union(enum) {
    signal: Signal,
    message: Message,
};
const Assembly = struct {
    buffer: std.ArrayList(u8) = .empty,
    decoder: framing.Reassembler,
    started: ?std.Io.Timestamp = null,
    fn push(self: *Assembly, a: std.mem.Allocator, io: std.Io, data: []const u8, limit: usize) !?[]const u8 {
        if (data.len < 2) return error.MalformedFragment;
        const payload_len = data.len - 1;
        if (self.decoder.used > limit or payload_len > limit - self.decoder.used) return error.MessageTooLarge;
        const needed = self.decoder.used + payload_len;
        self.buffer.items.len = self.decoder.used;
        if (needed > self.buffer.capacity) {
            const capacity = @min(limit, @max(needed, self.buffer.capacity +| @max(self.buffer.capacity, 1024)));
            try self.buffer.ensureTotalCapacityPrecise(a, capacity);
        }
        self.decoder.storage = self.buffer.allocatedSlice();
        if (self.started == null) self.started = std.Io.Clock.awake.now(io);
        const result = try self.decoder.push(data);
        if (result != null) self.started = null;
        return result;
    }
};

/// One application owner drives poll/send/applySignal/close. Native callbacks are
/// synchronized internally. Message data borrows reassembly storage until the
/// next poll; signal strings borrow internal storage until the next poll.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    peer: *native.Peer,
    role: Role,
    id: u64,
    remote_id: []u8,
    local_id: []u8,
    options: Options,
    public_key: ?auth.Key = null,
    started: std.Io.Timestamp,
    answered: ?std.Io.Timestamp = null,
    established: bool = false,
    scratch: []u8,
    send_buffer: []u8,
    assemblies: [2]Assembly = .{
        .{ .decoder = framing.Reassembler.init(&.{}, .reliable) },
        .{ .decoder = framing.Reassembler.init(&.{}, .unreliable) },
    },
    owned_token: ?[]u8 = null,
    signal_buffer: ?[:0]u8 = null,
    received_messages: u64 = 0,
    sent_messages: u64 = 0,
    received_bytes: u64 = 0,
    sent_bytes: u64 = 0,

    pub fn create(a: std.mem.Allocator, io: std.Io, role: Role, id: u64, remote_id: []const u8, options: Options) !*Connection {
        if (options.maximum_message_size == 0 or options.maximum_message_size > framing.maximum_segment_payload * 256 or options.negotiation_timeout_ms == 0 or options.connection_timeout_ms == 0 or options.reassembly_timeout_ms == 0) return error.InvalidConfiguration;
        const self = try a.create(Connection);
        errdefer a.destroy(self);
        if (remote_id.len > 4096 or options.local_network_id.len > 4096) return error.InvalidConfiguration;
        const local_id = try a.dupe(u8, options.local_network_id);
        errdefer a.free(local_id);
        const name = try a.dupe(u8, remote_id);
        errdefer a.free(name);
        const scratch = try a.alloc(u8, 1024 * 1024 + 1);
        errdefer a.free(scratch);
        const send_buffer = try a.alloc(u8, framing.maximum_segment_payload + 1);
        errdefer a.free(send_buffer);
        var native_options = options.native;
        native_options.maximum_message_size = options.maximum_message_size;
        const peer = try native.Peer.create(a, io, native_options);
        errdefer peer.destroy();
        self.* = .{ .allocator = a, .io = io, .peer = peer, .role = role, .id = id, .remote_id = name, .local_id = local_id, .options = options, .scratch = scratch, .send_buffer = send_buffer, .started = std.Io.Clock.awake.now(io) };
        if (role == .server and self.options.identity == null) {
            const key = jwt.Scheme.KeyPair.generate(io);
            const token = try jwt.serverToken(a, key, std.Io.Clock.real.now(io).toSeconds());
            self.owned_token = token;
            self.options.identity = .{ .key = key, .token = token };
        }
        return self;
    }

    pub fn destroy(self: *Connection) void {
        self.peer.destroy();
        for (&self.assemblies) |*assembly| assembly.buffer.deinit(self.allocator);
        if (self.owned_token) |token| self.allocator.free(token);
        if (self.signal_buffer) |buffer| self.allocator.free(buffer);
        self.allocator.free(self.scratch);
        self.allocator.free(self.send_buffer);
        self.allocator.free(self.remote_id);
        self.allocator.free(self.local_id);
        self.allocator.destroy(self);
    }
    pub fn close(self: *Connection) void {
        self.peer.close();
    }
    pub fn ready(self: *Connection) bool {
        return self.peer.ready();
    }
    pub fn state(self: *Connection) native.State {
        return self.peer.getState();
    }
    pub fn start(self: *Connection) !void {
        if (self.role != .client) return error.InvalidState;
        try self.peer.offer();
    }
    pub fn applySignal(self: *Connection, signal: Signal) !void {
        if (signal.connection_id != self.id or !std.mem.eql(u8, signal.network_id, self.remote_id)) return error.UnexpectedSignal;
        errdefer self.close();
        if (std.mem.eql(u8, signal.kind, Signal.failure)) return error.RemoteFailure;
        const is_offer = std.mem.eql(u8, signal.kind, Signal.offer);
        const is_answer = std.mem.eql(u8, signal.kind, Signal.answer);
        if (!is_offer and !is_answer and !std.mem.eql(u8, signal.kind, Signal.candidate)) return error.UnexpectedSignal;
        if (signal.data.len > 1024 * 1024) return error.MessageTooLarge;
        const terminated = try self.allocator.dupeZ(u8, signal.data);
        defer self.allocator.free(terminated);
        if (!is_offer and !is_answer) return self.peer.remoteCandidate(terminated);
        if ((is_offer and self.role != .server) or (is_answer and self.role != .client)) return error.UnexpectedSignal;
        const identity_kind: auth.IdentityKind = if (self.role == .client) .server else .client;
        const key = try auth.verify(self.allocator, signal.data, std.Io.Clock.real.now(self.io).toSeconds(), identity_kind, self.options.verify_client);
        if (self.role == .server and key == null and !self.options.allow_anonymous) return error.IdentityNotAllowed;
        try self.peer.remoteDescription(terminated, if (is_offer) .offer else .answer);
        self.public_key = key;
        self.answered = std.Io.Clock.awake.now(self.io);
    }

    pub fn poll(self: *Connection) !?Event {
        return self.pollInternal(false);
    }
    /// Used by dialers/listeners to leave early application messages queued.
    pub fn pollNegotiation(self: *Connection) !?Event {
        return self.pollInternal(true);
    }
    fn pollInternal(self: *Connection, signals_only: bool) !?Event {
        errdefer self.close();
        const now = std.Io.Clock.awake.now(self.io);
        if (self.peer.ready()) self.established = true;
        if (!self.established) {
            const from = self.answered orelse self.started;
            const timeout = if (self.answered != null) self.options.connection_timeout_ms else self.options.negotiation_timeout_ms;
            if (from.durationTo(now).toMilliseconds() >= timeout) return error.Timeout;
        }
        for (&self.assemblies) |*assembly| if (assembly.started) |started| {
            if (started.durationTo(now).toMilliseconds() >= self.options.reassembly_timeout_ms) return error.ReassemblyTimeout;
        };
        if (self.signal_buffer) |buffer| {
            self.allocator.free(buffer);
            self.signal_buffer = null;
        }
        const event = try self.peer.pollRestricted(self.scratch, signals_only) orelse return null;
        switch (event) {
            .offer, .answer, .candidate => |data| {
                var body = data;
                if (event != .candidate) {
                    if (self.options.identity) |identity| {
                        self.signal_buffer = try auth.add(self.allocator, data, identity);
                        body = self.signal_buffer.?;
                    }
                }
                return .{ .signal = .{ .kind = if (event == .offer) Signal.offer else if (event == .answer) Signal.answer else Signal.candidate, .connection_id = self.id, .network_id = self.remote_id, .data = body } };
            },
            .reliable_fragment, .unreliable_fragment => |fragment| {
                const index: usize = if (event == .reliable_fragment) 0 else 1;
                const message = try self.assemblies[index].push(self.allocator, self.io, fragment, self.options.maximum_message_size) orelse return null;
                self.received_messages +|= 1;
                self.received_bytes +|= message.len;
                return .{ .message = .{ .reliability = @enumFromInt(index), .data = message } };
            },
        }
    }
    pub fn localAddress(self: *const Connection) Address {
        return .{ .network_id = self.local_id, .connection_id = self.id };
    }
    pub fn remoteAddress(self: *const Connection) Address {
        return .{ .network_id = self.remote_id, .connection_id = self.id };
    }
    /// Receives either channel without discarding messages from the other one.
    /// Message data borrows storage until the next poll/receive. For custom
    /// signaling, use poll and route its signal events instead.
    pub fn receive(self: *Connection) !Message {
        while (true) {
            if (try self.poll()) |event| switch (event) {
                .message => |message| return message,
                .signal => |signal| if (!std.mem.eql(u8, signal.kind, Signal.candidate)) return error.UnexpectedSignal,
            };
            try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
        }
    }
    pub fn send(self: *Connection, data: []const u8, reliability: framing.Reliability) !void {
        if (data.len > self.options.maximum_message_size) return error.MessageTooLarge;
        try self.peer.send(data, reliability, self.send_buffer);
        if (data.len != 0) self.sent_messages +|= 1;
        self.sent_bytes +|= data.len;
    }
};

fn assemblyAllocationScenario(a: std.mem.Allocator) !void {
    var assembly = Assembly{ .decoder = framing.Reassembler.init(&.{}, .reliable) };
    defer assembly.buffer.deinit(a);
    const frame = [_]u8{1} ++ [_]u8{42} ** 1024;
    _ = try assembly.push(a, std.testing.io, &frame, 4096);
    const final = [_]u8{0} ++ [_]u8{43} ** 1024;
    const message = (try assembly.push(a, std.testing.io, &final, 4096)).?;
    try std.testing.expectEqual(@as(usize, 2048), message.len);
    for (message[0..1024]) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
}
test "reassembly growth and every allocation failure preserve ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, assemblyAllocationScenario, .{});
}

fn connectionCreationFailureScenario(a: std.mem.Allocator) !void {
    const value = try Connection.create(a, std.testing.io, .server, 1, "remote", .{ .local_network_id = "local" });
    defer value.destroy();
    try std.testing.expectEqualStrings("local", value.localAddress().network_id);
}
test "connection setup allocation failures release native and Zig resources" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, connectionCreationFailureScenario, .{});
}
test "negotiation timeout and repeated close fail pending sends" {
    const value = try Connection.create(std.testing.allocator, std.testing.io, .client, 1, "remote", .{ .negotiation_timeout_ms = 1 });
    defer value.destroy();
    try std.Io.sleep(std.testing.io, .fromMilliseconds(3), .awake);
    try std.testing.expectError(error.Timeout, value.poll());
    value.close();
    value.close();
    try std.testing.expectError(error.InvalidState, value.send("hello", .reliable));
}

test "incomplete reassembly expires and closes connection" {
    const value = try Connection.create(std.testing.allocator, std.testing.io, .client, 1, "remote", .{ .reassembly_timeout_ms = 1 });
    defer value.destroy();
    value.established = true;
    _ = try value.assemblies[0].push(std.testing.allocator, std.testing.io, &.{ 1, 42 }, 1024);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(3), .awake);
    try std.testing.expectError(error.ReassemblyTimeout, value.poll());
}
