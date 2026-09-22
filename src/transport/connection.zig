const std = @import("std");

const auth = @import("../auth/sdp.zig");
const jwt = @import("../auth/token.zig");
const wake = @import("../internal/wakeup.zig");
const Signal = @import("../protocol/signal.zig").Signal;
const framing = @import("framing.zig");
const native = @import("peer.zig");
pub const CallbackStats = native.CallbackStats;
pub const IceState = native.IceState;
pub const IceGatheringState = native.GatheringState;
pub const ChannelState = native.ChannelState;
pub const ChannelDiagnostics = native.ChannelDiagnostics;
pub const SelectedIceAddresses = native.SelectedIceAddresses;

pub const maximum_network_id_length = 4096;
const maximum_signal_size = 1024 * 1024;

/// Validates an opaque network ID for use in an HTTP path segment.
pub fn validNetworkId(text: []const u8) bool {
    if (text.len == 0 or text.len > maximum_network_id_length) return false;
    if (std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..")) return false;

    for (text) |byte| {
        if (byte < 0x21 or byte > 0x7e) return false;
        switch (byte) {
            '/', '?', '#', '%' => return false,
            else => {},
        }
    }

    return true;
}

pub const Role = enum { client, server };
pub const Diagnostics = struct {
    ice_state: IceState,
    ice_gathering_state: IceGatheringState,
    reliable: ChannelDiagnostics,
    unreliable: ChannelDiagnostics,
    remote_ice_candidates: usize,

    pub fn bufferedOutgoingBytes(self: Diagnostics) usize {
        return (self.reliable.buffered_outgoing_bytes orelse 0) +|
            (self.unreliable.buffered_outgoing_bytes orelse 0);
    }
};

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
    graceful_shutdown_timeout_ms: u32 = 2000,
    maximum_remote_candidates: usize = 32,
    /// Allows unauthenticated remote peers when no verifier is configured.
    allow_anonymous: bool = false,
    identity: ?auth.Identity = null,
    server_identity_key: ?auth.KeyPair = null,
    server_identity_domain: []const u8 = "self",
    /// Verifies the issuer of a remote server token.
    verify_server: ?auth.Verifier = null,
    /// Verifies the issuer of a remote client token.
    verify_client: ?auth.Verifier = null,
};

fn verifierForRole(options: Options, role: Role) ?auth.Verifier {
    return if (role == .client)
        options.verify_server orelse options.verify_client
    else
        options.verify_client;
}

fn remoteIdentityRequired(options: Options, role: Role) bool {
    if (verifierForRole(options, role) != null) return true;
    return role == .server and !options.allow_anonymous;
}

fn validateOptions(options: Options) !void {
    if (options.maximum_message_size == 0 or
        options.maximum_message_size > framing.maximum_reliable_message_size or
        options.negotiation_timeout_ms == 0 or
        options.connection_timeout_ms == 0 or
        options.reassembly_timeout_ms == 0 or
        options.graceful_shutdown_timeout_ms == 0 or
        options.server_identity_domain.len == 0 or
        options.server_identity_domain.len > 255)
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

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    peer: *native.Peer,

    role: Role,
    id: u64,
    remote_id: []u8,
    local_id: []u8,
    options: Options,

    /// Key that signed the remote DTLS fingerprint assertion.
    public_key: ?auth.Key = null,
    /// Whether the remote token passed issuer verification.
    identity_issuer_verified: bool = false,
    started: std.Io.Timestamp,
    answered: ?std.Io.Timestamp = null,
    established: bool = false,
    remote_candidates: RemoteCandidates = .{},
    remote_candidate_count: std.atomic.Value(usize) = .init(0),

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

        self.options.local_network_id = local_id;

        if (role == .server and self.options.identity == null) {
            const key = self.options.server_identity_key orelse
                jwt.Scheme.KeyPair.generate(io);
            const timestamp = std.Io.Clock.real.now(io).toSeconds();
            const token = try jwt.serverToken(allocator, key, timestamp);

            self.owned_token = token;
            self.options.identity = .{
                .key = key,
                .token = token,
                .domain = self.options.server_identity_domain,
            };
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

    pub fn closeGracefully(self: *Connection) !void {
        try self.peer.closeGracefully(self.options.graceful_shutdown_timeout_ms);
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

    pub fn diagnostics(self: *Connection) Diagnostics {
        const transport = self.peer.diagnostics();
        return .{
            .ice_state = transport.ice_state,
            .ice_gathering_state = transport.gathering_state,
            .reliable = transport.reliable,
            .unreliable = transport.unreliable,
            .remote_ice_candidates = self.remote_candidate_count.load(.acquire),
        };
    }

    pub fn remoteIceCandidateCount(self: *Connection) usize {
        return self.remote_candidate_count.load(.acquire);
    }

    pub fn selectedIceAddresses(
        self: *Connection,
        local_buffer: []u8,
        remote_buffer: []u8,
    ) !?SelectedIceAddresses {
        return self.peer.selectedIceAddresses(local_buffer, remote_buffer);
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
        self.remote_candidate_count.store(self.remote_candidates.count, .release);

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

        const verifier = verifierForRole(self.options, self.role);
        const key = try auth.verify(
            self.allocator,
            signal.data,
            std.Io.Clock.real.now(self.io).toSeconds(),
            identity_kind,
            verifier,
        );

        if (key == null and remoteIdentityRequired(self.options, self.role))
            return error.IdentityNotAllowed;

        self.public_key = key;
        self.identity_issuer_verified = key != null and verifier != null;

        try self.peer.remoteDescription(
            auth.removeIdentity(terminated),
            if (is_offer) .offer else .answer,
        );

        self.answered = std.Io.Clock.awake.now(self.io);
    }

    pub fn poll(self: *Connection) !?Event {
        return self.pollInternal(false);
    }

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

    pub fn waitDeadline(self: *Connection) std.Io.Timeout {
        var result: std.Io.Timeout = .none;
        if (!self.established) {
            const started = self.answered orelse self.started;
            const timeout_ms = if (self.answered != null)
                self.options.connection_timeout_ms
            else
                self.options.negotiation_timeout_ms;
            result = wake.deadline(started, timeout_ms);
        }
        for (&self.assemblies) |*assembly| {
            if (assembly.started) |started| {
                result = wake.earliest(result, wake.deadline(started, self.options.reassembly_timeout_ms));
            }
        }
        return result;
    }

    pub fn prepareWait(self: *Connection) void {
        self.peer.wakeup.prepare();
    }

    pub fn wait(self: *Connection, negotiation: bool) !void {
        try self.io.checkCancel();
        if (self.peer.hasPending(negotiation)) return;
        if (negotiation and self.ready()) return;
        try self.peer.wakeup.wait(self.io, self.waitDeadline());
    }

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

test "remote identity verifiers are selected by connection role" {
    const Verifiers = struct {
        fn server(_: ?*anyopaque, _: []const u8) anyerror!?auth.Key {
            return null;
        }
        fn client(_: ?*anyopaque, _: []const u8) anyerror!?auth.Key {
            return null;
        }
    };

    const options: Options = .{
        .verify_server = .{ .verify = Verifiers.server },
        .verify_client = .{ .verify = Verifiers.client },
    };
    try std.testing.expect(verifierForRole(options, .client).?.verify == Verifiers.server);
    try std.testing.expect(verifierForRole(options, .server).?.verify == Verifiers.client);
    try std.testing.expect(
        verifierForRole(
            .{ .verify_client = .{ .verify = Verifiers.client } },
            .client,
        ).?.verify == Verifiers.client,
    );

    try std.testing.expect(remoteIdentityRequired(options, .client));
    try std.testing.expect(remoteIdentityRequired(.{
        .verify_client = .{ .verify = Verifiers.client },
    }, .client));
    try std.testing.expect(!remoteIdentityRequired(.{}, .client));
    try std.testing.expect(remoteIdentityRequired(.{}, .server));
    try std.testing.expect(!remoteIdentityRequired(.{ .allow_anonymous = true }, .server));

    try std.testing.expect(remoteIdentityRequired(.{
        .allow_anonymous = true,
        .verify_client = .{ .verify = Verifiers.client },
    }, .server));
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
        framing.maximum_segment_payload,
    );

    options.maximum_message_size = framing.maximum_reliable_message_size + 1;
    try std.testing.expectError(error.InvalidConfiguration, validateOptions(options));
    try std.testing.expectError(
        error.MessageTooLarge,
        framing.validateMessageSize(
            framing.maximum_reliable_message_size + 1,
            .reliable,
            options.maximum_message_size,
            framing.maximum_segment_payload,
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

test "diagnostics total buffered bytes handles unavailable channels" {
    const diagnostics: Diagnostics = .{
        .ice_state = .new,
        .ice_gathering_state = .new,
        .reliable = .{
            .state = .open,
            .buffered_outgoing_bytes = 20,
        },
        .unreliable = .{
            .state = .unavailable,
            .buffered_outgoing_bytes = null,
        },
        .remote_ice_candidates = 3,
    };
    try std.testing.expectEqual(@as(usize, 20), diagnostics.bufferedOutgoingBytes());
}

test "applied descriptions reach the transport without an identity attribute" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const connection = try Connection.create(
        allocator,
        io,
        .server,
        7,
        "remote",
        .{ .allow_anonymous = true },
    );
    defer connection.destroy();

    const key = try jwt.Scheme.KeyPair.generateDeterministic(.{13} ** 48);
    const token = try jwt.serverToken(
        allocator,
        key,
        std.Io.Clock.real.now(io).toSeconds(),
    );
    defer allocator.free(token);

    const source =
        "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n" ++
        "a=fingerprint:sha-256 00:11\r\na=ice-ufrag:abcd\r\na=ice-pwd:0123456789abcdef\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=max-message-size:262144\r\na=setup:actpass\r\na=mid:0\r\na=sctp-port:5000\r\n";

    const signed = try auth.add(allocator, source, .{ .key = key, .token = token });
    defer allocator.free(signed);

    const Observer = struct {
        var seen: [4096]u8 = undefined;
        var length: usize = 0;

        fn record(sdp: []const u8) void {
            length = sdp.len;
            @memcpy(seen[0..sdp.len], sdp);
        }
    };
    Observer.length = 0;
    connection.peer.remote_description_test_hook = Observer.record;

    connection.applySignal(.{
        .kind = Signal.offer,
        .connection_id = 7,
        .network_id = "remote",
        .data = signed,
    }) catch {};

    const observed = Observer.seen[0..Observer.length];
    try std.testing.expect(std.mem.indexOf(u8, observed, "a=identity:") == null);
    try std.testing.expectEqualStrings(source, observed);
}

test "a transient disconnect neither closes nor stops the connection" {
    const connection = try Connection.create(
        std.testing.allocator,
        std.testing.io,
        .client,
        1,
        "remote",
        .{},
    );
    defer connection.destroy();

    connection.established = true;
    connection.peer.state = .connected;

    connection.peer.state = .disconnected;
    try connection.peer.queue.push(3, &.{ 0, 42 });

    const event = (try connection.poll()).?;
    try std.testing.expectEqualSlices(u8, &.{42}, event.message.data);
    try std.testing.expectEqual(native.State.disconnected, connection.state());

    connection.peer.state = .connected;
    try std.testing.expect((try connection.poll()) == null);
    try std.testing.expectEqual(native.State.connected, connection.state());

    connection.peer.state = .failed;
    try std.testing.expectError(error.ConnectionClosed, connection.poll());
    try std.testing.expectEqual(native.State.closed, connection.state());
}

fn signedOffer(
    allocator: std.mem.Allocator,
    io: std.Io,
    key: jwt.Scheme.KeyPair,
) ![:0]u8 {
    const token = try jwt.serverToken(
        allocator,
        key,
        std.Io.Clock.real.now(io).toSeconds(),
    );
    defer allocator.free(token);

    return auth.add(
        allocator,
        "v=0\r\na=fingerprint:sha-256 00:11\r\n" ++
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n",
        .{ .key = key, .token = token },
    );
}

test "an application verifier cannot be bypassed by the remote identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const key = try jwt.Scheme.KeyPair.generateDeterministic(.{16} ** 48);
    const offer = try signedOffer(allocator, io, key);
    defer allocator.free(offer);

    const unsigned = "v=0\r\na=fingerprint:sha-256 00:11\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n";

    const Verifiers = struct {
        var accepted: jwt.Scheme.PublicKey = undefined;

        fn reject(_: ?*anyopaque, _: []const u8) anyerror!?auth.Key {
            return null;
        }
        fn fail(_: ?*anyopaque, _: []const u8) anyerror!?auth.Key {
            return error.IdentityRefused;
        }
        fn substitute(_: ?*anyopaque, _: []const u8) anyerror!?auth.Key {
            const other = try jwt.Scheme.KeyPair.generateDeterministic(.{17} ** 48);
            return other.public_key;
        }
        fn accept(_: ?*anyopaque, _: []const u8) anyerror!?auth.Key {
            return accepted;
        }
    };
    Verifiers.accepted = key.public_key;

    const Case = struct {
        verify: *const fn (?*anyopaque, []const u8) anyerror!?auth.Key,
        data: []const u8,
    };

    for ([_]Case{
        .{ .verify = Verifiers.reject, .data = offer },
        .{ .verify = Verifiers.fail, .data = offer },
        .{ .verify = Verifiers.substitute, .data = offer },
        .{ .verify = Verifiers.accept, .data = unsigned },
    }) |case| {
        const connection = try Connection.create(allocator, io, .server, 7, "remote", .{
            .allow_anonymous = true,
            .verify_client = .{ .verify = case.verify },
        });
        defer connection.destroy();

        if (connection.applySignal(.{
            .kind = Signal.offer,
            .connection_id = 7,
            .network_id = "remote",
            .data = case.data,
        })) |_| {
            return error.VerifierBypassed;
        } else |_| {}

        try std.testing.expect(connection.public_key == null);
        try std.testing.expect(!connection.identity_issuer_verified);
    }

    const connection = try Connection.create(allocator, io, .server, 7, "remote", .{
        .verify_client = .{ .verify = Verifiers.accept },
    });
    defer connection.destroy();

    connection.peer.remote_description_test_hook = struct {
        fn ignore(_: []const u8) void {}
    }.ignore;

    connection.applySignal(.{
        .kind = Signal.offer,
        .connection_id = 7,
        .network_id = "remote",
        .data = offer,
    }) catch {};

    try std.testing.expect(connection.public_key != null);
    try std.testing.expect(connection.identity_issuer_verified);
}

test "proof of possession alone is not issuer verification" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const key = try jwt.Scheme.KeyPair.generateDeterministic(.{18} ** 48);
    const offer = try signedOffer(allocator, io, key);
    defer allocator.free(offer);

    const connection = try Connection.create(allocator, io, .server, 7, "remote", .{
        .allow_anonymous = true,
    });
    defer connection.destroy();

    connection.applySignal(.{
        .kind = Signal.offer,
        .connection_id = 7,
        .network_id = "remote",
        .data = offer,
    }) catch {};

    try std.testing.expect(connection.public_key != null);
    try std.testing.expect(!connection.identity_issuer_verified);
}

test "network IDs are opaque but bounded to one path segment" {
    for ([_][]const u8{
        "1",
        "18446744073709551615",
        "18446744073709551616",
        "a3f0-9c11",
        "{1}",
        "..a",
        "a" ** maximum_network_id_length,
    }) |id| try std.testing.expect(validNetworkId(id));

    for ([_][]const u8{
        "",
        ".",
        "..",
        "123/extra",
        "123?x=1",
        "123#f",
        "%7B1%7D",
        "%2e%2e",
        "with space",
        "tab\there",
        &.{ '1', 0 },
        "\xff\xfe",
        "a" ** (maximum_network_id_length + 1),
    }) |id| try std.testing.expect(!validNetworkId(id));
}

test "stored options never outlive a caller's local network ID buffer" {
    var scratch: [20]u8 = undefined;
    const id = try std.fmt.bufPrint(&scratch, "{d}", .{12345});

    const connection = try Connection.create(
        std.testing.allocator,
        std.testing.io,
        .client,
        1,
        "remote",
        .{ .local_network_id = id },
    );
    defer connection.destroy();

    @memset(&scratch, 0);
    try std.testing.expectEqualStrings("12345", connection.options.local_network_id);
    try std.testing.expectEqualStrings("12345", connection.localAddress().network_id);
}
