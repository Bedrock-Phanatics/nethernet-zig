const std = @import("std");

const wake = @import("wakeup.zig");
const native = @import("peer.zig");
const framing = @import("framing.zig");
const auth = @import("sdp_identity.zig");
const jwt = @import("identity.zig");
const Signal = @import("signal.zig").Signal;

const maximum_network_id_length = 4096;
const maximum_signal_size = 1024 * 1024;

pub const Role = enum { client, server };
pub const CallbackStats = native.CallbackStats;

pub const Address = struct {
    network_id: []const u8,
    connection_id: u64,
};

pub const Message = struct {
    reliability: framing.Reliability,
    data: []const u8,
};

pub const Options = struct {
    connection_id: u64 = 0,
    local_network_id: []const u8 = "",
    native: native.Options = .{},
    maximum_message_size: usize = framing.default_maximum_message_size,
    negotiation_timeout_ms: u32 = 15000,
    connection_timeout_ms: u32 = 10000,
    reassembly_timeout_ms: u32 = 30000,
    maximum_remote_candidates: usize = 32,
    allow_anonymous: bool = false,
    identity: ?auth.Identity = null,
    verify_client: ?auth.Verifier = null,
};

fn validateOptions(options: Options) !void {
    if (options.maximum_message_size == 0 or
        options.maximum_message_size > framing.maximum_reliable_message_size or
        options.negotiation_timeout_ms == 0 or
        options.connection_timeout_ms == 0 or
        options.reassembly_timeout_ms == 0)
    {
        return error.InvalidConfiguration;
    }
}

const RemoteCandidates = struct {
    count: usize = 0,

    fn addSdp(self: *RemoteCandidates, sdp: []const u8, maximum: usize) !void {
        var additional: usize = 0;
        var lines = std.mem.splitScalar(u8, sdp, '\n');
        while (lines.next()) |line_with_cr| {
            const line = std.mem.trimEnd(u8, line_with_cr, "\r");
            if (!std.mem.startsWith(u8, line, "a=candidate:")) continue;
            if (additional >= maximum) return error.TooManyRemoteCandidates;
            additional += 1;
        }
        try self.add(additional, maximum);
    }

    fn addTrickled(self: *RemoteCandidates, maximum: usize) !void {
        try self.add(1, maximum);
    }

    fn add(self: *RemoteCandidates, additional: usize, maximum: usize) !void {
        if (self.count > maximum or additional > maximum - self.count)
            return error.TooManyRemoteCandidates;
        self.count += additional;
    }
};
pub const Event = union(enum) {
    signal: Signal,
    message: Message,
};

const Assembly = struct {
    buffer: std.ArrayList(u8) = .empty,
    decoder: framing.Reassembler,
    started: ?std.Io.Timestamp = null,

    fn push(
        self: *Assembly,
        allocator: std.mem.Allocator,
        io: std.Io,
        data: []const u8,
        limit: usize,
    ) !?[]const u8 {
        if (data.len < 2) return error.MalformedFragment;

        const payload_len = data.len - 1;
        if (self.decoder.used > limit or payload_len > limit - self.decoder.used) {
            return error.MessageTooLarge;
        }

        // The peer poll buffer already has the required borrowed lifetime.
        if (self.decoder.used == 0) {
            if (self.decoder.failed) return error.ConnectionClosed;
            if (try framing.singleFragmentPayload(data, self.decoder.reliability)) |payload| {
                return payload;
            }
        }

        const needed = self.decoder.used + payload_len;
        self.buffer.items.len = self.decoder.used;

        if (needed > self.buffer.capacity) {
            const growth = self.buffer.capacity +| @max(self.buffer.capacity, 1024);
            const capacity = @min(limit, @max(needed, growth));
            try self.buffer.ensureTotalCapacityPrecise(allocator, capacity);
        }

        self.decoder.storage = self.buffer.allocatedSlice();

        if (self.started == null) {
            self.started = std.Io.Clock.awake.now(io);
        }

        const result = try self.decoder.push(data);
        if (result != null) self.started = null;

        return result;
    }
};

/// Use the connection from one owner. Event data lasts until the next poll.
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
    remote_candidates: RemoteCandidates = .{},

    packet_scratch: []u8,
    negotiation_scratch: ?[]u8,
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

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        role: Role,
        id: u64,
        remote_id: []const u8,
        options: Options,
    ) !*Connection {
        try validateOptions(options);

        if (remote_id.len > maximum_network_id_length or
            options.local_network_id.len > maximum_network_id_length)
        {
            return error.InvalidConfiguration;
        }

        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);

        const local_id = try allocator.dupe(u8, options.local_network_id);
        errdefer allocator.free(local_id);

        const remote_id_copy = try allocator.dupe(u8, remote_id);
        errdefer allocator.free(remote_id_copy);

        const packet_payload_size: usize = @min(options.maximum_message_size, framing.maximum_segment_payload);
        const packet_buffer_size = packet_payload_size + 1;

        const packet_scratch = try allocator.alloc(u8, packet_buffer_size);
        errdefer allocator.free(packet_scratch);

        const negotiation_scratch = try allocator.alloc(u8, maximum_signal_size + 1);
        errdefer allocator.free(negotiation_scratch);

        const send_buffer = try allocator.alloc(u8, packet_buffer_size);
        errdefer allocator.free(send_buffer);

        var native_options = options.native;
        native_options.maximum_message_size = options.maximum_message_size;

        const peer = try native.Peer.create(allocator, io, native_options);
        errdefer peer.destroy();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .peer = peer,
            .role = role,
            .id = id,
            .remote_id = remote_id_copy,
            .local_id = local_id,
            .options = options,
            .packet_scratch = packet_scratch,
            .negotiation_scratch = negotiation_scratch,
            .send_buffer = send_buffer,
            .started = std.Io.Clock.awake.now(io),
        };

        if (role == .server and self.options.identity == null) {
            const key = jwt.Scheme.KeyPair.generate(io);
            const timestamp = std.Io.Clock.real.now(io).toSeconds();
            const token = try jwt.serverToken(allocator, key, timestamp);

            self.owned_token = token;
            self.options.identity = .{ .key = key, .token = token };
        }

        return self;
    }

    pub fn destroy(self: *Connection) void {
        self.peer.destroy();

        for (&self.assemblies) |*assembly| {
            assembly.buffer.deinit(self.allocator);
        }

        if (self.owned_token) |token| self.allocator.free(token);
        if (self.signal_buffer) |buffer| self.allocator.free(buffer);

        self.allocator.free(self.packet_scratch);
        if (self.negotiation_scratch) |scratch| self.allocator.free(scratch);
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

    pub fn callbackStats(self: *Connection) CallbackStats {
        return self.peer.callbackStats();
    }

    pub fn state(self: *Connection) native.State {
        return self.peer.getState();
    }

    pub fn start(self: *Connection) !void {
        if (self.role != .client) return error.InvalidState;
        try self.peer.offer();
    }

    pub fn applySignal(self: *Connection, signal: Signal) !void {
        const matches_connection =
            signal.connection_id == self.id and
            std.mem.eql(u8, signal.network_id, self.remote_id);

        if (!matches_connection) return error.UnexpectedSignal;

        errdefer self.close();

        if (std.mem.eql(u8, signal.kind, Signal.failure)) {
            return error.RemoteFailure;
        }

        const is_offer = std.mem.eql(u8, signal.kind, Signal.offer);
        const is_answer = std.mem.eql(u8, signal.kind, Signal.answer);
        const is_candidate = std.mem.eql(u8, signal.kind, Signal.candidate);

        if (!is_offer and !is_answer and !is_candidate) {
            return error.UnexpectedSignal;
        }

        if (signal.data.len > maximum_signal_size) return error.MessageTooLarge;

        if (is_candidate) {
            try self.remote_candidates.addTrickled(self.options.maximum_remote_candidates);
        } else {
            try self.remote_candidates.addSdp(signal.data, self.options.maximum_remote_candidates);
        }

        const terminated = try self.allocator.dupeZ(u8, signal.data);
        defer self.allocator.free(terminated);

        if (is_candidate) return self.peer.remoteCandidate(terminated);
        if ((is_offer and self.role != .server) or
            (is_answer and self.role != .client))
        {
            return error.UnexpectedSignal;
        }

        const identity_kind: auth.IdentityKind =
            if (self.role == .client) .server else .client;

        const key = try auth.verify(
            self.allocator,
            signal.data,
            std.Io.Clock.real.now(self.io).toSeconds(),
            identity_kind,
            self.options.verify_client,
        );

        if (self.role == .server and key == null and !self.options.allow_anonymous) {
            return error.IdentityNotAllowed;
        }

        try self.peer.remoteDescription(
            terminated,
            if (is_offer) .offer else .answer,
        );

        self.public_key = key;
        self.answered = std.Io.Clock.awake.now(self.io);
    }

    pub fn poll(self: *Connection) !?Event {
        return self.pollInternal(false);
    }

    /// Lets dialers and listeners leave early messages in the queue.
    pub fn pollNegotiation(self: *Connection) !?Event {
        return self.pollInternal(true);
    }

    fn pollInternal(self: *Connection, signals_only: bool) !?Event {
        errdefer self.close();

        const now = std.Io.Clock.awake.now(self.io);

        if (self.peer.ready()) self.established = true;

        if (!self.established) {
            const started = self.answered orelse self.started;
            const timeout_ms = if (self.answered != null)
                self.options.connection_timeout_ms
            else
                self.options.negotiation_timeout_ms;

            if (started.durationTo(now).toMilliseconds() >= timeout_ms) {
                return error.Timeout;
            }
        }

        for (&self.assemblies) |*assembly| {
            if (assembly.started) |started| {
                if (started.durationTo(now).toMilliseconds() >=
                    self.options.reassembly_timeout_ms)
                {
                    return error.ReassemblyTimeout;
                }
            }
        }

        if (self.signal_buffer) |buffer| {
            self.allocator.free(buffer);
            self.signal_buffer = null;
        }

        const needs_negotiation = self.peer.needsNegotiationBuffer();
        if (self.established and !needs_negotiation) {
            if (self.negotiation_scratch) |scratch| {
                self.allocator.free(scratch);
                self.negotiation_scratch = null;
            }
        }

        const scratch = if (needs_negotiation)
            self.negotiation_scratch orelse return error.InvalidState
        else
            self.packet_scratch;
        const event = try self.peer.pollRestricted(scratch, signals_only) orelse return null;

        switch (event) {
            .offer, .answer, .candidate => |data| {
                var body = data;

                if (event != .candidate) {
                    if (self.options.identity) |identity| {
                        self.signal_buffer = try auth.add(self.allocator, data, identity);
                        body = self.signal_buffer.?;
                    }
                }

                const kind = if (event == .offer)
                    Signal.offer
                else if (event == .answer)
                    Signal.answer
                else
                    Signal.candidate;

                return .{
                    .signal = .{
                        .kind = kind,
                        .connection_id = self.id,
                        .network_id = self.remote_id,
                        .data = body,
                    },
                };
            },

            .reliable_fragment, .unreliable_fragment => |fragment| {
                const reliable = event == .reliable_fragment;
                const index: usize = if (reliable) 0 else 1;

                const message = try self.assemblies[index].push(
                    self.allocator,
                    self.io,
                    fragment,
                    self.options.maximum_message_size,
                ) orelse return null;

                self.received_messages +|= 1;
                self.received_bytes +|= message.len;

                return .{
                    .message = .{
                        .reliability = if (reliable) .reliable else .unreliable,
                        .data = message,
                    },
                };
            },
        }
    }

    pub fn localAddress(self: *const Connection) Address {
        return .{
            .network_id = self.local_id,
            .connection_id = self.id,
        };
    }

    pub fn remoteAddress(self: *const Connection) Address {
        return .{
            .network_id = self.remote_id,
            .connection_id = self.id,
        };
    }

    /// Wakeups do not extend the deadline.
    pub fn waitDeadline(self: *Connection) std.Io.Timeout {
        var result: std.Io.Timeout = .none;
        if (!self.established) {
            result = wake.deadline(self.answered orelse self.started, if (self.answered != null) self.options.connection_timeout_ms else self.options.negotiation_timeout_ms);
        }
        for (&self.assemblies) |*assembly| {
            if (assembly.started) |started| {
                result = wake.earliest(result, wake.deadline(started, self.options.reassembly_timeout_ms));
            }
        }
        return result;
    }

    /// Call before polling to avoid missing a wakeup.
    pub fn prepareWait(self: *Connection) void {
        self.peer.wakeup.prepare();
    }

    pub fn wait(self: *Connection, negotiation: bool) !void {
        try self.io.checkCancel();
        if (self.peer.hasPending(negotiation)) return;
        if (negotiation and self.ready()) return;
        try self.peer.wakeup.wait(self.io, self.waitDeadline());
    }

    /// Waits for either channel. Use poll when handling signaling yourself.
    pub fn receive(self: *Connection) !Message {
        while (true) {
            self.prepareWait();
            if (try self.poll()) |event| {
                switch (event) {
                    .message => |message| return message,
                    .signal => |signal| {
                        if (!std.mem.eql(u8, signal.kind, Signal.candidate)) {
                            return error.UnexpectedSignal;
                        }
                    },
                }
            }

            try self.wait(false);
        }
    }

    pub fn send(
        self: *Connection,
        data: []const u8,
        reliability: framing.Reliability,
    ) !void {
        if (data.len > self.options.maximum_message_size) {
            return error.MessageTooLarge;
        }

        try self.peer.send(data, reliability, self.send_buffer);

        if (data.len != 0) self.sent_messages +|= 1;
        self.sent_bytes +|= data.len;
    }
};

fn assemblyAllocationScenario(allocator: std.mem.Allocator) !void {
    var assembly = Assembly{
        .decoder = framing.Reassembler.init(&.{}, .reliable),
    };
    defer assembly.buffer.deinit(allocator);

    const frame = [_]u8{1} ++ [_]u8{42} ** 1024;
    _ = try assembly.push(allocator, std.testing.io, &frame, 4096);

    const final = [_]u8{0} ++ [_]u8{43} ** 1024;
    const message = (try assembly.push(allocator, std.testing.io, &final, 4096)).?;

    try std.testing.expectEqual(@as(usize, 2048), message.len);

    for (message[0..1024]) |byte| {
        try std.testing.expectEqual(@as(u8, 42), byte);
    }
}

test "reassembly growth and every allocation failure preserve ownership" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        assemblyAllocationScenario,
        .{},
    );
}

fn connectionCreationFailureScenario(allocator: std.mem.Allocator) !void {
    const connection = try Connection.create(
        allocator,
        std.testing.io,
        .server,
        1,
        "remote",
        .{ .local_network_id = "local" },
    );
    defer connection.destroy();

    try std.testing.expectEqualStrings("local", connection.localAddress().network_id);
}

test "connection setup allocation failures release native and Zig resources" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        connectionCreationFailureScenario,
        .{},
    );
}

test "negotiation timeout and repeated close fail pending sends" {
    const connection = try Connection.create(
        std.testing.allocator,
        std.testing.io,
        .client,
        1,
        "remote",
        .{ .negotiation_timeout_ms = 1 },
    );
    defer connection.destroy();

    try std.testing.expectError(error.Timeout, connection.receive());

    connection.close();
    connection.close();

    try std.testing.expectError(
        error.InvalidState,
        connection.send("hello", .reliable),
    );
}

test "incomplete reassembly expires and closes connection" {
    const connection = try Connection.create(
        std.testing.allocator,
        std.testing.io,
        .client,
        1,
        "remote",
        .{ .reassembly_timeout_ms = 1 },
    );
    defer connection.destroy();

    connection.established = true;
    _ = try connection.assemblies[0].push(
        std.testing.allocator,
        std.testing.io,
        &.{ 1, 42 },
        1024,
    );

    try std.testing.expectError(error.ReassemblyTimeout, connection.receive());
}

test "cancel and close unblock receive" {
    const io = std.testing.io;
    const connection = try Connection.create(std.testing.allocator, io, .client, 1, "remote", .{});
    defer connection.destroy();
    connection.established = true;
    var canceled = try io.concurrent(Connection.receive, .{connection});
    try std.testing.expectError(error.Canceled, canceled.cancel(io));
    var closed = try io.concurrent(Connection.receive, .{connection});
    connection.close();
    try std.testing.expectError(error.ConnectionClosed, closed.await(io));
}

test "receive drains partial messages without waiting" {
    const io = std.testing.io;
    const connection = try Connection.create(std.testing.allocator, io, .client, 1, "remote", .{});
    defer connection.destroy();
    connection.established = true;
    try connection.peer.queue.push(3, &.{ 1, 'a' });
    try connection.peer.queue.push(3, &.{ 0, 'b' });
    const message = try connection.receive();
    try std.testing.expectEqualStrings("ab", message.data);
}

test "buffers follow message limit and negotiation scratch is released" {
    const connection = try Connection.create(
        std.testing.allocator,
        std.testing.io,
        .client,
        1,
        "remote",
        .{ .maximum_message_size = 1024 },
    );
    defer connection.destroy();

    try std.testing.expectEqual(@as(usize, 1025), connection.packet_scratch.len);
    try std.testing.expectEqual(@as(usize, 1025), connection.send_buffer.len);
    try std.testing.expect(connection.negotiation_scratch != null);

    connection.established = true;
    connection.peer.gathered = true;
    try std.testing.expect((try connection.poll()) == null);
    try std.testing.expect(connection.negotiation_scratch == null);
}

test "single-fragment assembly borrows poll storage without allocation" {
    var assembly = Assembly{
        .decoder = framing.Reassembler.init(&.{}, .reliable),
    };
    defer assembly.buffer.deinit(std.testing.allocator);

    const fragment = [_]u8{ 0, 1, 2, 3 };
    const message = (try assembly.push(std.testing.allocator, std.testing.io, &fragment, 3)).?;
    try std.testing.expectEqual(@intFromPtr(fragment[1..].ptr), @intFromPtr(message.ptr));
    try std.testing.expectEqual(@as(usize, 0), assembly.buffer.capacity);
}

test "connection and encoder maximum message limits agree" {
    var options: Options = .{ .maximum_message_size = framing.maximum_reliable_message_size };
    try validateOptions(options);
    try framing.validateMessageSize(
        framing.maximum_reliable_message_size,
        .reliable,
        options.maximum_message_size,
    );

    options.maximum_message_size = framing.maximum_reliable_message_size + 1;
    try std.testing.expectError(error.InvalidConfiguration, validateOptions(options));
    try std.testing.expectError(
        error.MessageTooLarge,
        framing.validateMessageSize(
            framing.maximum_reliable_message_size + 1,
            .reliable,
            options.maximum_message_size,
        ),
    );
}

test "remote ICE candidates accept exactly the configured limit" {
    try std.testing.expectEqual(@as(usize, 32), (Options{}).maximum_remote_candidates);

    var candidates: RemoteCandidates = .{};
    try candidates.addSdp(
        "v=0\r\na=candidate:first\r\na=candidate:second\r\n",
        2,
    );
    try std.testing.expectEqual(@as(usize, 2), candidates.count);
}

test "remote ICE candidates reject an over-limit bundled SDP" {
    var candidates: RemoteCandidates = .{};
    try std.testing.expectError(
        error.TooManyRemoteCandidates,
        candidates.addSdp(
            "v=0\n" ++
                "a=candidate:first\n" ++
                "a=candidate:second\n" ++
                "a=candidate:third\n",
            2,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), candidates.count);
}

test "remote ICE candidates reject over-limit trickle" {
    var candidates: RemoteCandidates = .{};
    try candidates.addTrickled(2);
    try candidates.addTrickled(2);
    try std.testing.expectError(
        error.TooManyRemoteCandidates,
        candidates.addTrickled(2),
    );
    try std.testing.expectEqual(@as(usize, 2), candidates.count);

    candidates.count = std.math.maxInt(usize);
    try std.testing.expectError(
        error.TooManyRemoteCandidates,
        candidates.addTrickled(std.math.maxInt(usize) - 1),
    );
}

test "bundled and trickled remote ICE candidates share one limit" {
    var candidates: RemoteCandidates = .{};
    try candidates.addSdp(
        "a=candidate:bundled-one\r\na=candidate:bundled-two\r\n",
        3,
    );
    try candidates.addTrickled(3);
    try std.testing.expectError(
        error.TooManyRemoteCandidates,
        candidates.addTrickled(3),
    );
    try std.testing.expectEqual(@as(usize, 3), candidates.count);
}
