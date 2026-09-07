const std = @import("std");
const framing = @import("framing.zig");
const Queue = @import("queue.zig").Queue;

const c = @cImport({
    @cDefine("RTC_ENABLE_MEDIA", "0");
    @cDefine("RTC_ENABLE_WEBSOCKET", "0");
    @cInclude("rtc/rtc.h");
});

pub const State = enum(u8) { new, connecting, connected, disconnected, failed, closed };
pub const Event = union(enum) {
    offer: []const u8,
    answer: []const u8,
    candidate: []const u8,
    reliable_fragment: []const u8,
    unreliable_fragment: []const u8,
};

pub const Options = struct {
    queue_bytes: usize = 4 * 1024 * 1024,
    queue_entries: usize = 512,
    maximum_buffered_send: usize = 16 * 1024 * 1024 + 255,
    maximum_message_size: usize = framing.default_maximum_message_size,
    ice_servers: []const [*:0]const u8 = &.{},
    disable_trickle: bool = false,
};

/// Use the WebRTC peer from one owner. Callbacks write to a bounded queue.
/// The allocator and I/O context must outlive it.
pub const Peer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: c_int = -1,
    channels: [2]c_int = .{ -1, -1 },
    mutex: std.Io.Mutex = .init,
    state: State = .new,
    stopping: bool = false,
    gathered: bool = false,
    description_sent: bool = false,
    description_kind: enum { offer, answer } = .offer,
    options: Options,
    queue: Queue,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Peer {
        if (options.queue_bytes < framing.maximum_segment_payload + 1 or options.queue_entries < 2 or
            options.maximum_buffered_send == 0 or options.ice_servers.len > 64) return error.InvalidConfiguration;
        const self = try allocator.create(Peer);
        errdefer allocator.destroy(self);

        const bytes = try allocator.alloc(u8, options.queue_bytes);
        errdefer allocator.free(bytes);

        const entries = try allocator.alloc(Queue.Entry, options.queue_entries);
        errdefer allocator.free(entries);

        self.* = .{ .allocator = allocator, .io = io, .options = options, .queue = try Queue.init(bytes, entries) };
        var config = std.mem.zeroes(c.rtcConfiguration);
        config.disableAutoNegotiation = true;
        config.maxMessageSize = framing.maximum_segment_payload + 1;
        config.iceServers = @ptrCast(@constCast(options.ice_servers.ptr));
        config.iceServersCount = @intCast(options.ice_servers.len);
        self.id = c.rtcCreatePeerConnection(&config);
        if (self.id < 0) return error.WebRtcFailure;
        errdefer _ = c.rtcDeletePeerConnection(self.id);

        c.rtcSetUserPointer(self.id, self);
        try check(c.rtcSetStateChangeCallback(self.id, onState));
        try check(c.rtcSetGatheringStateChangeCallback(self.id, onGathered));
        try check(c.rtcSetLocalDescriptionCallback(self.id, onDescription));
        try check(c.rtcSetLocalCandidateCallback(self.id, onCandidate));
        try check(c.rtcSetDataChannelCallback(self.id, onChannel));
        return self;
    }

    pub fn close(self: *Peer) void {
        self.mutex.lockUncancelable(self.io);
        if (self.stopping) {
            self.mutex.unlock(self.io);
            return;
        }
        self.stopping = true;
        self.state = .closed;
        self.mutex.unlock(self.io);
        // Never wait for native callbacks while holding their mutex.
        _ = c.rtcDeletePeerConnection(self.id);
        for (self.channels) |id| if (id >= 0) {
            _ = c.rtcDeleteDataChannel(id);
        };
        self.id = -1;
    }

    /// Call this once when the owner is finished with the peer.
    pub fn destroy(self: *Peer) void {
        self.close();
        const allocator = self.allocator;
        allocator.free(self.queue.bytes);
        allocator.free(self.queue.entries);
        allocator.destroy(self);
    }

    pub fn getState(self: *Peer) State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.state;
    }

    pub fn ready(self: *Peer) bool {
        self.mutex.lockUncancelable(self.io);
        const channels = self.channels;
        const connected = self.state == .connected and !self.stopping;
        self.mutex.unlock(self.io);
        return connected and channels[0] >= 0 and channels[1] >= 0 and c.rtcIsOpen(channels[0]) and c.rtcIsOpen(channels[1]);
    }

    pub fn offer(self: *Peer) !void {
        if (self.getState() != .new) return error.InvalidState;
        for ([_][:0]const u8{ "ReliableDataChannel", "UnreliableDataChannel" }, 0..) |label, index| {
            var init = std.mem.zeroes(c.rtcDataChannelInit);
            init.reliability.unordered = index == 1;
            init.reliability.unreliable = index == 1;
            init.reliability.maxRetransmits = 0;
            const channel = c.rtcCreateDataChannelEx(self.id, label, &init);
            if (channel < 0) {
                self.close();
                return error.WebRtcFailure;
            }
            self.attach(channel) catch |err| {
                self.close();
                return err;
            };
        }
        self.description_kind = .offer;
        self.mutex.lockUncancelable(self.io);
        self.state = .connecting;
        self.mutex.unlock(self.io);
        try check(c.rtcSetLocalDescription(self.id, "offer"));
    }

    /// Verify the SDP identity before setting the remote description.
    pub fn remoteDescription(self: *Peer, sdp: [:0]const u8, kind: enum { offer, answer }) !void {
        const state = self.getState();
        if ((kind == .offer and state != .new) or (kind == .answer and state != .connecting)) return error.InvalidState;
        if (sdp.len == 0 or sdp.len > 1024 * 1024 or std.mem.indexOfScalar(u8, sdp, 0) != null) return error.MalformedSignal;
        try check(c.rtcSetRemoteDescription(self.id, sdp, if (kind == .offer) "offer" else "answer"));
        if (kind == .offer) {
            self.description_kind = .answer;
            self.mutex.lockUncancelable(self.io);
            self.state = .connecting;
            self.mutex.unlock(self.io);
            try check(c.rtcSetLocalDescription(self.id, "answer"));
        }
    }

    pub fn remoteCandidate(self: *Peer, candidate: [:0]const u8) !void {
        if (self.id < 0) return error.ConnectionClosed;
        if (candidate.len > 16384 or std.mem.indexOfScalar(u8, candidate, 0) != null) return error.MalformedSignal;
        try check(c.rtcAddRemoteCandidate(self.id, candidate, "0"));
    }

    pub fn poll(self: *Peer, output: []u8) !?Event {
        return self.pollRestricted(output, false);
    }

    pub fn pollRestricted(self: *Peer, output: []u8, signals_only: bool) !?Event {
        self.mutex.lockUncancelable(self.io);
        if (self.stopping or self.state == .closed or self.state == .failed) {
            self.mutex.unlock(self.io);
            return error.ConnectionClosed;
        }
        const complete = self.gathered;
        self.mutex.unlock(self.io);
        if (self.options.disable_trickle and complete and !self.description_sent) {
            if (output.len > std.math.maxInt(c_int)) return error.InvalidConfiguration;
            const result = c.rtcGetLocalDescription(self.id, output.ptr, @intCast(output.len));
            if (result == c.RTC_ERR_TOO_SMALL) return error.NoSpaceLeft;
            try check(result);
            if (result == 0 or result > output.len) return error.WebRtcFailure;
            self.description_sent = true;
            const data = output[0 .. @as(usize, @intCast(result)) - 1];
            return if (self.description_kind == .offer) .{ .offer = data } else .{ .answer = data };
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (signals_only and self.queue.count != 0 and self.queue.entries[self.queue.head].tag >= 3) return null;
        const entry = try self.queue.pop(output) orelse return null;
        return switch (entry.tag) {
            0 => .{ .offer = entry.data },
            1 => .{ .answer = entry.data },
            2 => .{ .candidate = entry.data },
            3 => .{ .reliable_fragment = entry.data },
            4 => .{ .unreliable_fragment = entry.data },
            else => unreachable,
        };
    }

    /// A partial native send closes the peer so later frames cannot be corrupted.
    pub fn send(self: *Peer, data: []const u8, reliability: framing.Reliability, scratch: []u8) !void {
        var encoder = try framing.Encoder.init(data, reliability, self.options.maximum_message_size);
        if (!self.ready()) return error.InvalidState;
        const channel = self.channels[@intFromEnum(reliability)];
        const buffered = c.rtcGetBufferedAmount(channel);
        try check(buffered);
        const count = if (data.len == 0) 0 else (data.len - 1) / framing.maximum_segment_payload + 1;
        const amount = data.len + count;
        if (@as(usize, @intCast(buffered)) > self.options.maximum_buffered_send or amount > self.options.maximum_buffered_send - @as(usize, @intCast(buffered))) return error.Backpressure;
        if (scratch.len < @as(usize, @min(data.len, framing.maximum_segment_payload)) + 1 and data.len != 0) return error.NoSpaceLeft;
        while (try encoder.next(scratch)) |fragment| {
            check(c.rtcSendMessage(channel, fragment.ptr, @intCast(fragment.len))) catch |err| {
                self.close();
                return err;
            };
        }
    }

    fn attach(self: *Peer, channel: c_int) !void {
        var transferred = false;
        errdefer if (!transferred) {
            _ = c.rtcDeleteDataChannel(channel);
        };
        var label: [64]u8 = undefined;
        const len = c.rtcGetDataChannelLabel(channel, &label, label.len);
        try check(len);
        if (len < 1 or len > label.len) return error.InvalidChannel;
        const name = label[0 .. @as(usize, @intCast(len)) - 1];
        const index: usize = if (std.mem.eql(u8, name, "ReliableDataChannel")) 0 else if (std.mem.eql(u8, name, "UnreliableDataChannel")) 1 else return error.InvalidChannel;
        self.mutex.lockUncancelable(self.io);
        if (self.stopping or self.channels[index] >= 0) {
            self.mutex.unlock(self.io);
            return error.InvalidChannel;
        }
        self.channels[index] = channel;
        transferred = true;
        self.mutex.unlock(self.io);
        // The peer owns this channel from this point on.
        c.rtcSetUserPointer(channel, self);
        try check(c.rtcSetMessageCallback(channel, onMessage));
        try check(c.rtcSetClosedCallback(channel, onClosed));
        try check(c.rtcSetErrorCallback(channel, onError));
    }

    fn from(ptr: ?*anyopaque) *Peer {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn enqueue(self: *Peer, tag: u8, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.stopping or self.state == .failed) return;
        self.queue.push(tag, bytes) catch {
            self.state = .failed;
        };
    }

    fn onDescription(_: c_int, sdp: [*c]const u8, kind: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self = from(ptr);
        if (!self.options.disable_trickle) self.enqueue(if (std.mem.eql(u8, std.mem.span(kind), "offer")) 0 else 1, std.mem.span(sdp));
    }

    fn onCandidate(_: c_int, value: [*c]const u8, _: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self = from(ptr);
        if (!self.options.disable_trickle) self.enqueue(2, std.mem.span(value));
    }

    fn onState(_: c_int, state: c.rtcState, ptr: ?*anyopaque) callconv(.c) void {
        const self = from(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.stopping and self.state != .failed) self.state = switch (state) {
            c.RTC_NEW => .new,
            c.RTC_CONNECTING => .connecting,
            c.RTC_CONNECTED => .connected,
            c.RTC_DISCONNECTED => .disconnected,
            c.RTC_FAILED => .failed,
            else => .closed,
        };
    }

    fn onGathered(_: c_int, state: c.rtcGatheringState, ptr: ?*anyopaque) callconv(.c) void {
        const self = from(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.gathered = state == c.RTC_GATHERING_COMPLETE;
    }

    fn onChannel(_: c_int, channel: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = from(ptr);
        self.attach(channel) catch {
            onClosed(channel, ptr);
        };
    }

    fn onMessage(channel: c_int, data: [*c]const u8, size: c_int, ptr: ?*anyopaque) callconv(.c) void {
        if (size < 0) return;
        const self = from(ptr);
        self.mutex.lockUncancelable(self.io);
        const reliable = self.channels[0] == channel;
        self.mutex.unlock(self.io);
        self.enqueue(if (reliable) 3 else 4, data[0..@intCast(size)]);
    }

    fn onClosed(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = from(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.stopping) self.state = .failed;
    }

    fn onError(id: c_int, _: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        onClosed(id, ptr);
    }
};

fn check(result: c_int) error{WebRtcFailure}!void {
    if (result < 0) return error.WebRtcFailure;
}

test "native callback queue exhaustion fails closed with bounded storage" {
    const value = try Peer.create(std.testing.allocator, std.testing.io, .{ .queue_entries = 2, .queue_bytes = framing.maximum_segment_payload + 1 });
    defer value.destroy();

    value.enqueue(3, "a");
    value.enqueue(3, "b");
    value.enqueue(3, "c");
    try std.testing.expectEqual(State.failed, value.getState());
    try std.testing.expectEqual(@as(usize, 2), value.queue.count);
    var output: [16]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, value.poll(&output));
}
