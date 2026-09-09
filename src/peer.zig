const std = @import("std");

const framing = @import("framing.zig");
const wake = @import("wakeup.zig");
const Wakeup = wake.Wakeup;
const Queue = @import("queue.zig").Queue;

const c = @cImport({
    @cDefine("RTC_ENABLE_MEDIA", "0");
    @cDefine("RTC_ENABLE_WEBSOCKET", "0");
    @cInclude("rtc/rtc.h");
});

pub const maximum_signal_size = 1024 * 1024;

pub const CallbackStats = struct {
    dropped_unreliable_packets: u64,
    queue_high_water_bytes: usize,
    queue_high_water_entries: usize,
};

pub const State = enum(u8) {
    new,
    connecting,
    connected,
    disconnected,
    failed,
    closed,
};

pub const IceState = enum(u8) {
    new,
    checking,
    connected,
    completed,
    failed,
    disconnected,
    closed,
};

pub const GatheringState = enum(u8) {
    new,
    in_progress,
    complete,
};

pub const ChannelState = enum(u8) {
    unavailable,
    connecting,
    open,
    closed,
};

pub const ChannelDiagnostics = struct {
    state: ChannelState,
    buffered_outgoing_bytes: ?usize,
};

pub const Diagnostics = struct {
    ice_state: IceState,
    gathering_state: GatheringState,
    reliable: ChannelDiagnostics,
    unreliable: ChannelDiagnostics,

    pub fn bufferedOutgoingBytes(self: Diagnostics) usize {
        return (self.reliable.buffered_outgoing_bytes orelse 0) +|
            (self.unreliable.buffered_outgoing_bytes orelse 0);
    }
};

pub const SelectedIceAddresses = struct {
    /// Slices borrow the caller-provided buffers until those buffers are reused.
    local: []const u8,
    remote: []const u8,
};

pub const Event = union(enum) {
    offer: []const u8,
    answer: []const u8,
    candidate: []const u8,
    reliable_fragment: []const u8,
    unreliable_fragment: []const u8,
};

pub const Options = struct {
    /// Aggregate callback storage for two maximum-sized fragments.
    queue_bytes: usize = maximum_signal_size,
    queue_entries: usize = 512,
    maximum_buffered_send: usize = 16 * 1024 * 1024 + 255,
    maximum_message_size: usize = framing.default_maximum_message_size,
    ice_servers: []const [*:0]const u8 = &.{},
    disable_trickle: bool = false,
    /// Opt-in until queue-pressure benchmarks justify changing the default.
    drop_unreliable_on_pressure: bool = false,
    unreliable_reserve_bytes: usize = framing.maximum_segment_payload + 1,
    unreliable_reserve_entries: usize = 1,
};

/// Use the WebRTC peer from one owner. Callbacks write to a bounded queue.
/// The allocator and I/O context must outlive it.
pub const Peer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    id: c_int = -1,
    channels: [2]c_int = .{ -1, -1 },
    mutex: std.Io.Mutex = .init,

    wakeup: Wakeup = .{},
    subscriber: ?*Wakeup = null,

    state: State = .new,
    stopping: bool = false,
    send_stopped: bool = false,
    gathered: bool = false,
    ice_state: IceState = .new,
    gathering_state: GatheringState = .new,
    description_sent: bool = false,
    description_kind: enum { offer, answer } = .offer,

    options: Options,
    queue: Queue,
    dropped_unreliable_packets: u64 = 0,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Peer {
        if (options.queue_bytes < framing.maximum_segment_payload + 1 or
            options.queue_entries < 2 or
            options.maximum_buffered_send == 0 or
            options.ice_servers.len > 64 or
            (options.drop_unreliable_on_pressure and
                (options.unreliable_reserve_bytes > options.queue_bytes or
                    options.unreliable_reserve_entries >= options.queue_entries)))
        {
            return error.InvalidConfiguration;
        }

        const self = try allocator.create(Peer);
        errdefer allocator.destroy(self);

        const queue_bytes = try allocator.alloc(u8, options.queue_bytes);
        errdefer allocator.free(queue_bytes);

        const queue_entries = try allocator.alloc(
            Queue.Entry,
            options.queue_entries,
        );
        errdefer allocator.free(queue_entries);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .queue = try Queue.init(queue_bytes, queue_entries),
        };

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
        try check(c.rtcSetIceStateChangeCallback(self.id, onIceState));
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
        self.send_stopped = true;
        self.state = .closed;
        const id = self.id;
        const channels = self.channels;
        self.id = -1;
        self.channels = .{ -1, -1 };
        self.notify();
        self.mutex.unlock(self.io);

        // Never wait for native callbacks while holding their mutex.
        if (id >= 0) _ = c.rtcDeletePeerConnection(id);
        for (channels) |channel| {
            if (channel >= 0) _ = c.rtcDeleteDataChannel(channel);
        }
    }

    pub fn closeGracefully(self: *Peer, timeout_ms: u32) !void {
        if (timeout_ms == 0) return error.InvalidConfiguration;
        return gracefulDrain(Peer, self, self.io, timeout_ms);
    }

    fn stopSends(self: *Peer) void {
        self.mutex.lockUncancelable(self.io);
        self.send_stopped = true;
        self.notify();
        self.mutex.unlock(self.io);
    }

    fn drainStatus(self: *Peer) enum { open, closed, failed } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.state == .closed) return .closed;
        if (self.state == .failed or self.state == .disconnected) return .failed;
        return .open;
    }

    fn bufferedAmount(self: *Peer) !usize {
        self.mutex.lockUncancelable(self.io);
        const channels = self.channels;
        self.mutex.unlock(self.io);

        var total: usize = 0;
        for (channels) |channel| {
            if (channel < 0) continue;
            const amount = c.rtcGetBufferedAmount(channel);
            try check(amount);
            total +|= @intCast(amount);
        }
        return total;
    }

    fn forceClose(self: *Peer) void {
        self.close();
    }
    /// Call this once when the owner is finished with the peer.
    pub fn destroy(self: *Peer) void {
        self.close();

        const allocator = self.allocator;
        allocator.free(self.queue.bytes);
        allocator.free(self.queue.entries);
        allocator.destroy(self);
    }

    /// Owner only. Detach before freeing the wakeup.
    pub fn subscribe(self: *Peer, wakeup: ?*Wakeup) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.subscriber = wakeup;
        self.notify();
    }

    // Caller holds the mutex.
    fn notify(self: *Peer) void {
        self.wakeup.signal(self.io);
        if (self.subscriber) |wakeup| wakeup.signal(self.io);
    }

    pub fn hasPending(self: *Peer, signals_only: bool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (signals_only) self.queue.hasTagBelow(3) else self.queue.count != 0;
    }

    /// Whether the next poll can produce negotiation data larger than a packet.
    pub fn needsNegotiationBuffer(self: *Peer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.gathered) return true;
        if (self.options.disable_trickle and !self.description_sent) return true;
        return self.queue.hasTagBelow(3);
    }

    pub fn callbackStats(self: *Peer) CallbackStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .dropped_unreliable_packets = self.dropped_unreliable_packets,
            .queue_high_water_bytes = self.queue.high_water_bytes,
            .queue_high_water_entries = self.queue.high_water_entries,
        };
    }

    pub fn diagnostics(self: *Peer) Diagnostics {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return .{
            .ice_state = self.ice_state,
            .gathering_state = self.gathering_state,
            .reliable = channelDiagnostics(self.channels[0]),
            .unreliable = channelDiagnostics(self.channels[1]),
        };
    }

    fn channelDiagnostics(channel: c_int) ChannelDiagnostics {
        if (channel < 0) return .{
            .state = .unavailable,
            .buffered_outgoing_bytes = null,
        };

        const buffered = c.rtcGetBufferedAmount(channel);
        return .{
            .state = if (c.rtcIsOpen(channel))
                .open
            else if (c.rtcIsClosed(channel))
                .closed
            else
                .connecting,
            .buffered_outgoing_bytes = if (buffered < 0)
                null
            else
                @intCast(buffered),
        };
    }

    /// Copies the selected ICE addresses into caller-owned buffers.
    pub fn selectedIceAddresses(
        self: *Peer,
        local_buffer: []u8,
        remote_buffer: []u8,
    ) !?SelectedIceAddresses {
        if (local_buffer.len == 0 or remote_buffer.len == 0 or
            local_buffer.len > std.math.maxInt(c_int) or
            remote_buffer.len > std.math.maxInt(c_int))
        {
            return error.InvalidConfiguration;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.id < 0) return null;

        const local_length = c.rtcGetLocalAddress(
            self.id,
            local_buffer.ptr,
            @intCast(local_buffer.len),
        );
        if (local_length == c.RTC_ERR_NOT_AVAIL) return null;
        if (local_length == c.RTC_ERR_TOO_SMALL) return error.NoSpaceLeft;
        try check(local_length);

        const remote_length = c.rtcGetRemoteAddress(
            self.id,
            remote_buffer.ptr,
            @intCast(remote_buffer.len),
        );
        if (remote_length == c.RTC_ERR_NOT_AVAIL) return null;
        if (remote_length == c.RTC_ERR_TOO_SMALL) return error.NoSpaceLeft;
        try check(remote_length);

        if (local_length < 1 or remote_length < 1 or
            local_length > local_buffer.len or
            remote_length > remote_buffer.len)
        {
            return error.WebRtcFailure;
        }

        return .{
            .local = local_buffer[0 .. @as(usize, @intCast(local_length)) - 1],
            .remote = remote_buffer[0 .. @as(usize, @intCast(remote_length)) - 1],
        };
    }

    pub fn getState(self: *Peer) State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.state;
    }

    pub fn ready(self: *Peer) bool {
        self.mutex.lockUncancelable(self.io);

        const channels = self.channels;
        const connected = self.state == .connected and !self.stopping and !self.send_stopped;

        self.mutex.unlock(self.io);

        return connected and
            channels[0] >= 0 and
            channels[1] >= 0 and
            c.rtcIsOpen(channels[0]) and
            c.rtcIsOpen(channels[1]);
    }

    pub fn offer(self: *Peer) !void {
        if (self.getState() != .new) return error.InvalidState;

        for ([_][:0]const u8{
            "ReliableDataChannel",
            "UnreliableDataChannel",
        }, 0..) |label, index| {
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
        self.notify();
        self.mutex.unlock(self.io);

        try check(c.rtcSetLocalDescription(self.id, "offer"));
    }

    /// Verify the SDP identity before setting the remote description.
    pub fn remoteDescription(
        self: *Peer,
        sdp: [:0]const u8,
        kind: enum { offer, answer },
    ) !void {
        const state = self.getState();

        if ((kind == .offer and state != .new) or
            (kind == .answer and state != .connecting))
        {
            return error.InvalidState;
        }

        if (sdp.len == 0 or
            sdp.len > maximum_signal_size or
            std.mem.indexOfScalar(u8, sdp, 0) != null)
        {
            return error.MalformedSignal;
        }

        try check(c.rtcSetRemoteDescription(
            self.id,
            sdp,
            if (kind == .offer) "offer" else "answer",
        ));

        if (kind == .offer) {
            self.description_kind = .answer;

            self.mutex.lockUncancelable(self.io);
            self.state = .connecting;
            self.notify();
            self.mutex.unlock(self.io);

            try check(c.rtcSetLocalDescription(self.id, "answer"));
        }
    }

    pub fn remoteCandidate(self: *Peer, candidate: [:0]const u8) !void {
        if (self.id < 0) return error.ConnectionClosed;

        if (candidate.len > 16384 or
            std.mem.indexOfScalar(u8, candidate, 0) != null)
        {
            return error.MalformedSignal;
        }

        try check(c.rtcAddRemoteCandidate(self.id, candidate, "0"));
    }

    pub fn poll(self: *Peer, output: []u8) !?Event {
        return self.pollRestricted(output, false);
    }

    pub fn pollRestricted(
        self: *Peer,
        output: []u8,
        signals_only: bool,
    ) !?Event {
        self.mutex.lockUncancelable(self.io);

        if (self.stopping or self.state == .closed or self.state == .failed or self.state == .disconnected) {
            self.mutex.unlock(self.io);
            return error.ConnectionClosed;
        }

        const gathered = self.gathered;
        self.mutex.unlock(self.io);

        if (self.options.disable_trickle and
            gathered and
            !self.description_sent)
        {
            if (output.len > std.math.maxInt(c_int)) {
                return error.InvalidConfiguration;
            }

            const result = c.rtcGetLocalDescription(
                self.id,
                output.ptr,
                @intCast(output.len),
            );

            if (result == c.RTC_ERR_TOO_SMALL) return error.NoSpaceLeft;

            try check(result);

            if (result == 0 or result > output.len) {
                return error.WebRtcFailure;
            }

            self.description_sent = true;

            const data = output[0 .. @as(usize, @intCast(result)) - 1];

            return if (self.description_kind == .offer)
                .{ .offer = data }
            else
                .{ .answer = data };
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const entry = (if (signals_only)
            try self.queue.popFirstTagBelow(3, output)
        else
            try self.queue.pop(output)) orelse return null;

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
    pub fn send(
        self: *Peer,
        data: []const u8,
        reliability: framing.Reliability,
        scratch: []u8,
    ) !void {
        var encoder = try framing.Encoder.init(
            data,
            reliability,
            self.options.maximum_message_size,
        );

        if (!self.ready()) return error.InvalidState;

        const channel = self.channels[@intFromEnum(reliability)];
        const buffered = c.rtcGetBufferedAmount(channel);
        try check(buffered);

        const fragment_count = if (data.len == 0)
            0
        else
            (data.len - 1) / framing.maximum_segment_payload + 1;

        const send_size = data.len + fragment_count;
        const buffered_size: usize = @intCast(buffered);

        if (buffered_size > self.options.maximum_buffered_send or
            send_size > self.options.maximum_buffered_send - buffered_size)
        {
            return error.Backpressure;
        }

        if (data.len != 0 and
            scratch.len < @as(usize, @min(data.len, framing.maximum_segment_payload)) + 1)
        {
            return error.NoSpaceLeft;
        }

        while (try encoder.next(scratch)) |fragment| {
            check(c.rtcSendMessage(
                channel,
                fragment.ptr,
                @intCast(fragment.len),
            )) catch |err| {
                self.close();
                return err;
            };
        }
    }

    // Reject channels as soon as libdatachannel exposes them. Only the two
    // protocol channels are kept; everything else is deleted below.
    fn attach(self: *Peer, channel: c_int) !void {
        var transferred = false;
        errdefer if (!transferred) {
            _ = c.rtcDeleteDataChannel(channel);
        };

        var label_buffer: [64]u8 = undefined;
        const length = c.rtcGetDataChannelLabel(
            channel,
            &label_buffer,
            label_buffer.len,
        );

        try check(length);

        if (length < 1 or length > label_buffer.len) {
            return error.InvalidChannel;
        }

        const label = label_buffer[0 .. @as(usize, @intCast(length)) - 1];

        const index: usize =
            if (std.mem.eql(u8, label, "ReliableDataChannel"))
                0
            else if (std.mem.eql(u8, label, "UnreliableDataChannel"))
                1
            else
                return error.InvalidChannel;

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

        try check(c.rtcSetOpenCallback(channel, onOpen));
        try check(c.rtcSetMessageCallback(channel, onMessage));
        try check(c.rtcSetClosedCallback(channel, onClosed));
        try check(c.rtcSetErrorCallback(channel, onError));
        try check(c.rtcSetBufferedAmountLowThreshold(channel, 0));
        try check(c.rtcSetBufferedAmountLowCallback(channel, onBufferedAmountLow));
        // onOpen is not called for channels that are already open.
        self.mutex.lockUncancelable(self.io);
        self.notify();
        self.mutex.unlock(self.io);
    }

    fn from(ptr: ?*anyopaque) *Peer {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn enqueue(self: *Peer, tag: u8, data: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.stopping or self.state == .failed) return;

        if (tag == 4 and self.options.drop_unreliable_on_pressure and
            data.len >= 2 and data[0] == 0)
        {
            self.queue.pushWithReserve(
                tag,
                data,
                self.options.unreliable_reserve_bytes,
                self.options.unreliable_reserve_entries,
            ) catch {
                self.dropped_unreliable_packets +|= 1;
            };
        } else {
            self.queue.push(tag, data) catch {
                self.state = .failed;
            };
        }
        self.notify();
    }

    fn onDescription(
        _: c_int,
        sdp: [*c]const u8,
        kind: [*c]const u8,
        ptr: ?*anyopaque,
    ) callconv(.c) void {
        const self = from(ptr);

        if (!self.options.disable_trickle) {
            self.enqueue(
                if (std.mem.eql(u8, std.mem.span(kind), "offer")) 0 else 1,
                std.mem.span(sdp),
            );
        }
    }

    fn onCandidate(
        _: c_int,
        value: [*c]const u8,
        _: [*c]const u8,
        ptr: ?*anyopaque,
    ) callconv(.c) void {
        const self = from(ptr);

        if (!self.options.disable_trickle) {
            self.enqueue(2, std.mem.span(value));
        }
    }

    fn onState(
        _: c_int,
        state: c.rtcState,
        ptr: ?*anyopaque,
    ) callconv(.c) void {
        const self = from(ptr);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.stopping and self.state != .failed) {
            self.state = switch (state) {
                c.RTC_NEW => .new,
                c.RTC_CONNECTING => .connecting,
                c.RTC_CONNECTED => .connected,
                c.RTC_DISCONNECTED => .disconnected,
                c.RTC_FAILED => .failed,
                else => .closed,
            };
            self.notify();
        }
    }

    fn onIceState(
        _: c_int,
        state: c.rtcIceState,
        ptr: ?*anyopaque,
    ) callconv(.c) void {
        const self = from(ptr);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.ice_state = switch (state) {
            c.RTC_ICE_NEW => .new,
            c.RTC_ICE_CHECKING => .checking,
            c.RTC_ICE_CONNECTED => .connected,
            c.RTC_ICE_COMPLETED => .completed,
            c.RTC_ICE_FAILED => .failed,
            c.RTC_ICE_DISCONNECTED => .disconnected,
            else => .closed,
        };
        self.notify();
    }

    fn onGathered(
        _: c_int,
        state: c.rtcGatheringState,
        ptr: ?*anyopaque,
    ) callconv(.c) void {
        const self = from(ptr);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.gathered = state == c.RTC_GATHERING_COMPLETE;
        self.gathering_state = switch (state) {
            c.RTC_GATHERING_NEW => .new,
            c.RTC_GATHERING_INPROGRESS => .in_progress,
            else => .complete,
        };
        self.notify();
    }

    fn onChannel(
        _: c_int,
        channel: c_int,
        ptr: ?*anyopaque,
    ) callconv(.c) void {
        const self = from(ptr);

        self.attach(channel) catch {
            onClosed(channel, ptr);
        };
    }

    fn onMessage(
        channel: c_int,
        data: [*c]const u8,
        size: c_int,
        ptr: ?*anyopaque,
    ) callconv(.c) void {
        if (size < 0) return;

        const self = from(ptr);

        self.mutex.lockUncancelable(self.io);
        const reliable = self.channels[0] == channel;
        self.mutex.unlock(self.io);

        self.enqueue(
            if (reliable) 3 else 4,
            data[0..@intCast(size)],
        );
    }

    fn onBufferedAmountLow(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = from(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.notify();
    }
    fn onOpen(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = from(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.notify();
    }

    fn onClosed(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = from(ptr);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.stopping) {
            self.state = .failed;
            self.notify();
        }
    }

    fn onError(
        id: c_int,
        _: [*c]const u8,
        ptr: ?*anyopaque,
    ) callconv(.c) void {
        onClosed(id, ptr);
    }
};

fn gracefulDrain(
    comptime T: type,
    target: *T,
    io: std.Io,
    timeout_ms: u32,
) !void {
    target.stopSends();
    errdefer target.forceClose();

    const started = std.Io.Clock.awake.now(io);
    const timeout = wake.deadline(started, timeout_ms);
    while (true) {
        target.wakeup.prepare();
        switch (target.drainStatus()) {
            .open => {},
            .closed => return,
            .failed => return error.ConnectionClosed,
        }
        if (try target.bufferedAmount() == 0) {
            target.forceClose();
            return;
        }
        if (std.Io.Clock.awake.now(io).nanoseconds >= timeout.deadline.raw.nanoseconds)
            return error.Timeout;
        try target.wakeup.wait(io, timeout);
    }
}
fn check(result: c_int) error{WebRtcFailure}!void {
    if (result < 0) return error.WebRtcFailure;
}

const DrainHarness = struct {
    io: std.Io,
    wakeup: Wakeup = .{},
    observed: std.Io.Event = .unset,
    buffered: std.atomic.Value(usize) = .init(0),
    status: std.atomic.Value(u8) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    sends_stopped: std.atomic.Value(bool) = .init(false),

    fn stopSends(self: *DrainHarness) void {
        self.sends_stopped.store(true, .release);
        self.wakeup.signal(self.io);
    }

    fn drainStatus(self: *DrainHarness) enum { open, closed, failed } {
        if (self.closed.load(.acquire)) return .closed;
        return if (self.status.load(.acquire) == 0) .open else .failed;
    }

    fn bufferedAmount(self: *DrainHarness) !usize {
        self.observed.set(self.io);
        return self.buffered.load(.acquire);
    }

    fn forceClose(self: *DrainHarness) void {
        self.closed.store(true, .release);
        self.wakeup.signal(self.io);
    }

    fn drain(self: *DrainHarness, timeout_ms: u32) !void {
        try gracefulDrain(DrainHarness, self, self.io, timeout_ms);
    }

    fn release(self: *DrainHarness) !void {
        try self.observed.wait(self.io);
        self.buffered.store(0, .release);
        self.wakeup.signal(self.io);
    }

    fn fail(self: *DrainHarness) !void {
        try self.observed.wait(self.io);
        self.status.store(1, .release);
        self.wakeup.signal(self.io);
    }
};

test "graceful drain closes empty buffers and is repeatable" {
    var harness: DrainHarness = .{ .io = std.testing.io };
    try harness.drain(100);
    try harness.drain(100);
    try std.testing.expect(harness.sends_stopped.load(.acquire));
    try std.testing.expect(harness.closed.load(.acquire));
}

test "graceful drain waits for buffered-low wakeup" {
    const io = std.testing.io;
    var harness: DrainHarness = .{ .io = io };
    harness.buffered.store(1, .release);
    var release = try io.concurrent(DrainHarness.release, .{&harness});
    defer release.cancel(io) catch {};
    try harness.drain(1000);
    try release.await(io);
    try std.testing.expect(harness.closed.load(.acquire));
}

test "graceful drain force closes on timeout" {
    var harness: DrainHarness = .{ .io = std.testing.io };
    harness.buffered.store(1, .release);
    try std.testing.expectError(error.Timeout, harness.drain(1));
    try std.testing.expect(harness.closed.load(.acquire));
}

test "graceful drain force closes on cancellation" {
    const io = std.testing.io;
    var harness: DrainHarness = .{ .io = io };
    harness.buffered.store(1, .release);
    var draining = try io.concurrent(DrainHarness.drain, .{ &harness, @as(u32, 1000) });
    try harness.observed.wait(io);
    try std.testing.expectError(error.Canceled, draining.cancel(io));
    try std.testing.expect(harness.closed.load(.acquire));
}

test "graceful drain force closes on native failure" {
    const io = std.testing.io;
    var harness: DrainHarness = .{ .io = io };
    harness.buffered.store(1, .release);
    var failure = try io.concurrent(DrainHarness.fail, .{&harness});
    defer failure.cancel(io) catch {};
    try std.testing.expectError(error.ConnectionClosed, harness.drain(1000));
    try failure.await(io);
    try std.testing.expect(harness.closed.load(.acquire));
}
test "graceful close handles an empty native buffer and repeated close" {
    const peer = try Peer.create(std.testing.allocator, std.testing.io, .{});
    defer peer.destroy();
    try peer.closeGracefully(100);
    try peer.closeGracefully(100);
    peer.close();
    peer.close();
    try std.testing.expectEqual(State.closed, peer.getState());
}
fn testDataChannel(peer: *Peer, label: [:0]const u8) !c_int {
    const channel = c.rtcCreateDataChannel(peer.id, label);
    try check(channel);
    return channel;
}

fn expectChannelDeleted(channel: c_int) !void {
    var label: [64]u8 = undefined;
    try std.testing.expect(c.rtcGetDataChannelLabel(channel, &label, label.len) < 0);
}

test "unknown remote data channel is deleted and fails the peer" {
    const peer = try Peer.create(std.testing.allocator, std.testing.io, .{});
    defer peer.destroy();
    const channel = try testDataChannel(peer, "UnknownDataChannel");
    Peer.onChannel(peer.id, channel, peer);
    try expectChannelDeleted(channel);
    try std.testing.expectEqual(State.failed, peer.getState());
    try std.testing.expectEqualSlices(c_int, &.{ -1, -1 }, &peer.channels);
}

test "duplicate remote data channel is deleted and fails the peer" {
    const peer = try Peer.create(std.testing.allocator, std.testing.io, .{});
    defer peer.destroy();
    const accepted = try testDataChannel(peer, "ReliableDataChannel");
    try peer.attach(accepted);
    const duplicate = try testDataChannel(peer, "ReliableDataChannel");
    Peer.onChannel(peer.id, duplicate, peer);
    try expectChannelDeleted(duplicate);
    try std.testing.expectEqual(State.failed, peer.getState());
    try std.testing.expectEqual(accepted, peer.channels[0]);
    try std.testing.expectEqual(@as(c_int, -1), peer.channels[1]);
}

test "remote data channel flood retains no rejected C API handles" {
    const peer = try Peer.create(std.testing.allocator, std.testing.io, .{});
    defer peer.destroy();
    for (0..256) |_| {
        const channel = try testDataChannel(peer, "FloodDataChannel");
        Peer.onChannel(peer.id, channel, peer);
        try expectChannelDeleted(channel);
    }
    try std.testing.expectEqual(State.failed, peer.getState());
    try std.testing.expectEqualSlices(c_int, &.{ -1, -1 }, &peer.channels);
}
test "native callback queue exhaustion fails closed with bounded storage" {
    const peer = try Peer.create(
        std.testing.allocator,
        std.testing.io,
        .{
            .queue_entries = 2,
            .queue_bytes = framing.maximum_segment_payload + 1,
        },
    );
    defer peer.destroy();

    peer.enqueue(3, "a");
    peer.enqueue(3, "b");
    peer.wakeup.prepare();
    peer.enqueue(3, "c");
    try std.testing.expect(peer.wakeup.event.isSet());

    try std.testing.expectEqual(State.failed, peer.getState());
    try std.testing.expectEqual(@as(usize, 2), peer.queue.count);

    var output: [16]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, peer.poll(&output));
}

test "state changes and errors wake subscribers" {
    const io = std.testing.io;
    const peer = try Peer.create(std.testing.allocator, io, .{});
    defer peer.destroy();
    var wakeup: Wakeup = .{};
    peer.subscribe(&wakeup);
    defer peer.subscribe(null);
    wakeup.prepare();
    Peer.onGathered(0, c.RTC_GATHERING_COMPLETE, peer);
    try std.testing.expect(wakeup.event.isSet());
    wakeup.prepare();
    Peer.onState(0, c.RTC_CONNECTING, peer);
    try std.testing.expect(wakeup.event.isSet());
    wakeup.prepare();
    Peer.onOpen(0, peer);
    try std.testing.expect(wakeup.event.isSet());
    wakeup.prepare();
    Peer.onBufferedAmountLow(0, peer);
    try std.testing.expect(wakeup.event.isSet());
    wakeup.prepare();
    Peer.onError(0, null, peer);
    try std.testing.expect(wakeup.event.isSet());
    try std.testing.expectEqual(State.failed, peer.getState());
    wakeup.prepare();
    peer.close();
    try std.testing.expect(wakeup.event.isSet());
}

test "opt-in unreliable drops preserve capacity for reliable traffic" {
    const peer = try Peer.create(std.testing.allocator, std.testing.io, .{
        .queue_bytes = framing.maximum_segment_payload + 1,
        .queue_entries = 3,
        .drop_unreliable_on_pressure = true,
        .unreliable_reserve_bytes = 8,
        .unreliable_reserve_entries = 1,
    });
    defer peer.destroy();

    const unreliable = [_]u8{0} ++ [_]u8{42} ** (framing.maximum_segment_payload - 8);
    peer.enqueue(4, &unreliable);
    peer.enqueue(4, &.{ 0, 1 });
    peer.enqueue(3, "reliable");

    try std.testing.expectEqual(State.new, peer.getState());
    const stats = peer.callbackStats();
    try std.testing.expectEqual(@as(u64, 1), stats.dropped_unreliable_packets);
    try std.testing.expectEqual(framing.maximum_segment_payload + 1, stats.queue_high_water_bytes);
    try std.testing.expectEqual(@as(usize, 2), stats.queue_high_water_entries);

    peer.enqueue(3, "x");
    try std.testing.expectEqual(State.failed, peer.getState());
}

test "default callback queue accepts a maximum-sized signaling event" {
    const peer = try Peer.create(std.testing.allocator, std.testing.io, .{});
    defer peer.destroy();

    const signal = try std.testing.allocator.alloc(u8, maximum_signal_size);
    defer std.testing.allocator.free(signal);
    @memset(signal, 's');

    peer.enqueue(0, signal);
    try std.testing.expectEqual(State.new, peer.getState());
    try std.testing.expectEqual(maximum_signal_size, peer.queue.used_bytes);
}
