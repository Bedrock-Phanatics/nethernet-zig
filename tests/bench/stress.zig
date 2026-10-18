const std = @import("std");
const builtin = @import("builtin");
const nethernet = @import("nethernet");

const Connection = nethernet.Connection;
const Reliability = nethernet.Reliability;
const ns_per_ms = std.time.ns_per_ms;

// Zig links TSan statically, so it has to start before libstdc++ constructors take their first lock.
extern fn __tsan_init() callconv(.c) void;
const tsan_preinit = [1]*const fn () callconv(.c) void{&__tsan_init};
comptime {
    if (builtin.sanitize_thread) @export(&tsan_preinit, .{ .name = "nethernet_tsan_preinit", .section = ".preinit_array" });
}

const Config = struct {
    connections: usize = 100,
    duration_ms: u64 = 30_000,
    payload_size: usize = 8192,
    rate: u64 = 20,
    burst: usize = 4,
    max_in_flight: usize = 64,
    poll_budget: usize = 128,
    churn_messages: u64 = 0,
    reliability: enum { reliable, unreliable, mixed } = .mixed,
    profile: enum { fixed, bedrock } = .bedrock,
    timeout_ms: u32 = 5_000,
    drain_timeout_ms: u32 = 5_000,
    idle: bool = false,
    ice_udp_mux: bool = false,
    rtc_threads: u32 = 0,
    slow_server_ms: u32 = 0,
    disconnect_at_ms: u64 = 0,
};

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    live_bytes: std.atomic.Value(usize) = .init(0),
    allocations: std.atomic.Value(u64) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.allocations.fetchAdd(1, .monotonic);
        _ = self.live_bytes.fetchAdd(len, .monotonic);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.track(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        _ = self.allocations.fetchAdd(1, .monotonic);
        self.track(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, ret_addr);
        _ = self.live_bytes.fetchSub(memory.len, .monotonic);
    }

    fn track(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            _ = self.live_bytes.fetchAdd(new_len - old_len, .monotonic);
        } else {
            _ = self.live_bytes.fetchSub(old_len - new_len, .monotonic);
        }
    }
};

const Pair = struct {
    client: *Connection,
    server: *Connection,

    fn destroy(self: Pair) void {
        self.client.destroy();
        self.server.destroy();
    }

    fn ready(self: Pair) bool {
        return self.client.ready() and self.server.ready();
    }
};

const Pending = struct {
    active: bool = false,
    sequence: u64 = 0,
    sent_ns: i96 = 0,
    size: usize = 0,
    reliability: Reliability = .reliable,
};

const State = struct {
    phase: enum { active, negotiating, closing, dead } = .active,
    sequence: u64 = 0,
    next_send_ns: i96 = 0,
    negotiation_started_ns: i96 = 0,
    pending: []Pending,
    pending_count: usize = 0,
    completed_since_churn: u64 = 0,
    churn_due: bool = false,
    last_reliable_sent: u64 = 0,
    last_reliable_echo: u64 = 0,
};

const Metrics = struct {
    sent: u64 = 0,
    completed: u64 = 0,
    bytes: u64 = 0,
    in_flight: u64 = 0,
    reconnects: u64 = 0,
    reconnect_ns: u64 = 0,
    failures: u64 = 0,
    send_failures: u64 = 0,
    poll_failures: u64 = 0,
    negotiation_failures: u64 = 0,
    reliable_timeouts: u64 = 0,
    unreliable_timeouts: u64 = 0,
    corruptions: u64 = 0,
    unmatched_messages: u64 = 0,
    reliable_order_violations: u64 = 0,
    native_dropped_unreliable: u64 = 0,
    backpressure: u64 = 0,
    queue_high_water_bytes: usize = 0,
    queue_high_water_entries: usize = 0,
    buffered_high_water_bytes: usize = 0,
    disconnects: u64 = 0,
    disconnects_detected: u64 = 0,
    disconnect_detect_ns: u64 = 0,
    disconnect_detect_max_ns: u64 = 0,
};

const Histogram = struct {
    buckets: []u64,
    count: u64 = 0,
    max_ns: u64 = 0,

    fn init(allocator: std.mem.Allocator) !Histogram {
        const buckets = try allocator.alloc(u64, 2_000_001);
        @memset(buckets, 0);
        return .{ .buckets = buckets };
    }

    fn record(self: *Histogram, latency_ns: u64) void {
        self.count += 1;
        self.max_ns = @max(self.max_ns, latency_ns);
        self.buckets[@min(latency_ns / std.time.ns_per_us, self.buckets.len - 1)] += 1;
    }

    fn percentileUs(self: Histogram, percent: u64) u64 {
        const target = (self.count * percent + 99) / 100;
        var accumulated: u64 = 0;
        for (self.buckets, 0..) |count, index| {
            accumulated += count;
            if (accumulated >= target and self.count != 0) return index;
        }
        return 0;
    }
};

fn nanos(milliseconds: anytype) i96 {
    return @as(i96, @intCast(milliseconds)) * ns_per_ms;
}

fn round(value: f64) f64 {
    return @round(value * 100) / 100;
}

fn ratio(numerator: anytype, denominator: anytype) f64 {
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(@max(denominator, 1)));
}

fn timeoutIn(ns: i96) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromNanoseconds(@max(ns, 0)), .clock = .awake } };
}

pub fn main(init: std.process.Init) !void {
    var counting: CountingAllocator = .{ .parent = init.gpa };
    const allocator = counting.allocator();
    const io = init.io;

    const config = try parseArgs(init.minimal.args, allocator);
    if (config.connections == 0 or config.payload_size < 16 or config.burst == 0 or
        config.max_in_flight == 0 or config.poll_budget == 0) return error.InvalidConfiguration;
    if (config.rtc_threads != 0) try nethernet.Peer.setNativeThreadPoolSize(config.rtc_threads);

    var wakeup: nethernet.Wakeup = .{};
    const rss_process_start = residentBytes(io);

    const pairs = try allocator.alloc(Pair, config.connections);
    defer allocator.free(pairs);
    var created: usize = 0;
    defer for (pairs[0..created]) |pair| pair.destroy();

    const heap_before_pairs = counting.live_bytes.load(.monotonic);
    const create_started = std.Io.Clock.awake.now(io);
    while (created < pairs.len) : (created += 1) {
        pairs[created] = try createPair(allocator, io, created, config, &wakeup);
    }
    const setup_started = std.Io.Clock.awake.now(io);
    for (pairs) |pair| try pair.client.start();
    try negotiateAll(pairs, io, config.timeout_ms, &wakeup);
    const setup_finished = std.Io.Clock.awake.now(io);
    const rss_after_setup = residentBytes(io);
    const heap_after_setup = counting.live_bytes.load(.monotonic);

    const slots = std.math.mul(usize, config.connections, config.max_in_flight) catch return error.InvalidConfiguration;
    const pending = try allocator.alloc(Pending, slots);
    defer allocator.free(pending);
    @memset(pending, .{});
    const states = try allocator.alloc(State, config.connections);
    defer allocator.free(states);
    const interval_ns: i96 = if (config.rate == 0) 0 else @intCast(std.time.ns_per_s / config.rate);
    for (states, 0..) |*state, index| state.* = .{
        .pending = pending[index * config.max_in_flight ..][0..config.max_in_flight],
        .next_send_ns = @divTrunc(interval_ns * @as(i96, @intCast(index)), @as(i96, @intCast(config.connections))),
    };

    const payload = try allocator.alloc(u8, @max(config.payload_size, 8192));
    defer allocator.free(payload);
    var histogram = try Histogram.init(allocator);
    defer allocator.free(histogram.buckets);

    const rss_start = residentBytes(io);
    var metrics: Metrics = .{};
    const run_started = std.Io.Clock.awake.now(io);
    const cpu_started = std.Io.Clock.cpu_process.now(io);
    const thread_cpu_started = std.Io.Clock.cpu_thread.now(io);
    const harness_bytes = counting.live_bytes.load(.monotonic) -| heap_after_setup;
    const allocations_started = counting.allocations.load(.monotonic);

    const deadline_ns = nanos(config.duration_ms);
    const timeout_ns = nanos(config.timeout_ms);
    const drain_timeout_ns = nanos(config.drain_timeout_ms);
    const disconnect_at_ns = nanos(config.disconnect_at_ms);
    var generating = true;
    var drain_started_ns: i96 = 0;
    var next_sweep_ns: i96 = 0;
    var next_sample_ns: i96 = 0;
    var next_server_pump_ns: i96 = 0;
    var disconnect_ns: ?i96 = null;

    while (true) {
        const token = wakeup.prepare();
        const now_ns = run_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        if (generating and config.duration_ms != 0 and now_ns >= deadline_ns) {
            generating = false;
            drain_started_ns = now_ns;
        }

        var progress = false;

        if (config.disconnect_at_ms != 0 and disconnect_ns == null and now_ns >= disconnect_at_ns) {
            disconnect_ns = now_ns;
            for (pairs, states, 0..) |pair, *state, index| {
                if (index % 2 != 0 or state.phase != .active) continue;
                pair.server.close();
                state.phase = .closing;
                metrics.disconnects += 1;
            }
            progress = true;
        }

        for (pairs, states) |*pair, *state| {
            if (state.phase != .closing) continue;
            progress = (pumpClient(io, run_started, pair, state, &metrics, &histogram, config) catch {
                const detect_ns: u64 = @intCast(now_ns - disconnect_ns.?);
                metrics.disconnects_detected += 1;
                metrics.disconnect_detect_ns += detect_ns;
                metrics.disconnect_detect_max_ns = @max(metrics.disconnect_detect_max_ns, detect_ns);
                abortPending(state, &metrics);
                state.phase = .dead;
                continue;
            }) or progress;
        }

        for (pairs, states) |*pair, *state| {
            if (state.phase != .negotiating) continue;
            progress = (pumpNegotiation(pair, config.poll_budget) catch {
                fail(state, &metrics, &metrics.negotiation_failures);
                continue;
            }) or progress;
            if (pair.ready()) {
                metrics.reconnect_ns += @intCast(now_ns - state.negotiation_started_ns);
                metrics.reconnects += 1;
                state.phase = .active;
                state.next_send_ns = now_ns;
                state.completed_since_churn = 0;
                progress = true;
            } else if (now_ns - state.negotiation_started_ns >= timeout_ns) {
                fail(state, &metrics, &metrics.negotiation_failures);
            }
        }

        const pump_servers = config.slow_server_ms == 0 or now_ns >= next_server_pump_ns;
        if (pump_servers and config.slow_server_ms != 0) next_server_pump_ns = now_ns + nanos(config.slow_server_ms);
        for (pairs, states) |*pair, *state| {
            if (state.phase != .active or !pump_servers) continue;
            progress = (pumpServer(pair, state, &metrics, config.poll_budget) catch {
                fail(state, &metrics, &metrics.poll_failures);
                continue;
            }) or progress;
        }

        for (pairs, states) |*pair, *state| {
            if (state.phase != .active) continue;
            progress = (pumpClient(io, run_started, pair, state, &metrics, &histogram, config) catch {
                fail(state, &metrics, &metrics.poll_failures);
                continue;
            }) or progress;
        }

        if (now_ns >= next_sweep_ns) {
            for (states) |*state| expirePending(state, &metrics, now_ns, timeout_ns);
            next_sweep_ns = now_ns + 10 * ns_per_ms;
        }

        if (generating and !config.idle) {
            for (pairs, states, 0..) |*pair, *state, index| {
                if (state.phase != .active) continue;
                if (state.churn_due) {
                    if (state.pending_count == 0)
                        progress = beginReconnect(allocator, io, pair, state, index, config, &metrics, now_ns, &wakeup) or progress;
                    continue;
                }
                progress = sendDue(io, run_started, pair, state, &metrics, payload, config, now_ns) or progress;
            }
        }

        if (!config.idle and now_ns >= next_sample_ns) {
            for (pairs) |pair| updateHighWater(&metrics, pair);
            next_sample_ns = now_ns + 100 * ns_per_ms;
        }

        if (!generating) {
            if (metrics.in_flight == 0) break;
            if (now_ns - drain_started_ns >= drain_timeout_ns) {
                for (states) |*state| {
                    for (state.pending) |*slot| {
                        if (slot.active) expireOne(state, &metrics, slot);
                    }
                }
                break;
            }
        }

        if (!progress) {
            var idle_ns: i96 = if (config.duration_ms == 0) 100 * ns_per_ms else if (generating) deadline_ns - now_ns else drain_timeout_ns;
            if (metrics.in_flight != 0) idle_ns = @min(idle_ns, next_sweep_ns - now_ns);
            if (!config.idle) idle_ns = @min(idle_ns, next_sample_ns - now_ns);
            if (config.slow_server_ms != 0) idle_ns = @min(idle_ns, next_server_pump_ns - now_ns);
            if (config.disconnect_at_ms != 0 and disconnect_ns == null) idle_ns = @min(idle_ns, disconnect_at_ns - now_ns);
            if (generating and !config.idle and config.rate != 0) {
                for (states) |state| {
                    if (state.phase == .active and !state.churn_due) idle_ns = @min(idle_ns, state.next_send_ns - now_ns);
                }
            }
            try wakeup.wait(io, token, timeoutIn(idle_ns));
        }
    }

    for (pairs) |pair| {
        metrics.native_dropped_unreliable += pair.client.callbackStats().dropped_unreliable_packets +
            pair.server.callbackStats().dropped_unreliable_packets;
        updateHighWater(&metrics, pair);
    }

    const elapsed_ns = run_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    const cpu_ns = cpu_started.durationTo(std.Io.Clock.cpu_process.now(io)).nanoseconds;
    const thread_cpu_ns = thread_cpu_started.durationTo(std.Io.Clock.cpu_thread.now(io)).nanoseconds;
    const run_allocations = counting.allocations.load(.monotonic) - allocations_started;
    const rss_end = residentBytes(io);

    const teardown_started = std.Io.Clock.awake.now(io);
    for (pairs) |pair| pair.destroy();
    created = 0;
    const teardown_ns = teardown_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    const heap_retained = counting.live_bytes.load(.monotonic) -| (heap_before_pairs + harness_bytes);
    const rss_peak = residentBytes(io).peak;

    var dead: usize = 0;
    for (states) |state| dead += @intFromBool(state.phase == .dead);

    const report = .{
        .os = @tagName(builtin.os.tag),
        .mode = @tagName(builtin.mode),
        .connections = config.connections,
        .dead_connections = dead,
        .profile = @tagName(config.profile),
        .reliability = @tagName(config.reliability),
        .ice_udp_mux = config.ice_udp_mux,
        .create_ms = round(ratio(create_started.durationTo(setup_started).nanoseconds, ns_per_ms)),
        .setup_ms = round(ratio(setup_started.durationTo(setup_finished).nanoseconds, ns_per_ms)),
        .teardown_ms = round(ratio(teardown_ns, ns_per_ms)),
        .sent = metrics.sent,
        .completed = metrics.completed,
        .messages_per_second = round(ratio(metrics.completed * std.time.ns_per_s, elapsed_ns)),
        .mib_per_second = round(ratio(metrics.bytes * std.time.ns_per_s, elapsed_ns) / (1024 * 1024)),
        .latency_p50_us = histogram.percentileUs(50),
        .latency_p95_us = histogram.percentileUs(95),
        .latency_p99_us = histogram.percentileUs(99),
        .latency_max_us = histogram.max_ns / std.time.ns_per_us,
        .cpu_percent = round(ratio(cpu_ns * 100, elapsed_ns)),
        .api_thread_cpu_percent = round(ratio(thread_cpu_ns * 100, elapsed_ns)),
        .cpu_ns_per_roundtrip = round(ratio(cpu_ns, metrics.completed)),
        .allocations_per_roundtrip = round(ratio(run_allocations, metrics.completed)),
        .rss_per_pair_bytes = if (rss_after_setup.current != null and rss_process_start.current != null)
            (rss_after_setup.current.? -| rss_process_start.current.?) / config.connections
        else
            null,
        .rss_growth_bytes = if (rss_end.current != null and rss_start.current != null)
            @as(i64, @intCast(rss_end.current.?)) - @as(i64, @intCast(rss_start.current.?))
        else
            null,
        .rss_peak_bytes = rss_peak,
        .zig_heap_bytes_per_pair = (heap_after_setup -| heap_before_pairs) / config.connections,
        .zig_heap_retained_after_close_bytes = heap_retained,
        .reconnects = metrics.reconnects,
        .reconnect_ms_mean = round(ratio(metrics.reconnect_ns, metrics.reconnects) / ns_per_ms),
        .failures = metrics.failures,
        .send_failures = metrics.send_failures,
        .poll_failures = metrics.poll_failures,
        .negotiation_failures = metrics.negotiation_failures,
        .reliable_timeouts = metrics.reliable_timeouts,
        .unreliable_timeouts = metrics.unreliable_timeouts,
        .corruptions = metrics.corruptions,
        .unmatched_messages = metrics.unmatched_messages,
        .reliable_order_violations = metrics.reliable_order_violations,
        .native_dropped_unreliable = metrics.native_dropped_unreliable,
        .backpressure = metrics.backpressure,
        .queue_high_water_entries = metrics.queue_high_water_entries,
        .queue_high_water_bytes = metrics.queue_high_water_bytes,
        .buffered_high_water_bytes = metrics.buffered_high_water_bytes,
        .disconnects = metrics.disconnects,
        .disconnects_detected = metrics.disconnects_detected,
        .disconnect_detect_ms_mean = round(ratio(metrics.disconnect_detect_ns, metrics.disconnects_detected) / ns_per_ms),
        .disconnect_detect_ms_max = round(ratio(metrics.disconnect_detect_max_ns, ns_per_ms)),
    };
    const json = try std.json.Stringify.valueAlloc(allocator, report, .{});
    defer allocator.free(json);
    std.debug.print("{s}\n", .{json});

    if (metrics.failures != 0 or metrics.corruptions != 0 or metrics.reliable_order_violations != 0 or
        metrics.disconnects_detected != metrics.disconnects) return error.StressFailure;
}

fn createPair(allocator: std.mem.Allocator, io: std.Io, index: usize, config: Config, wakeup: *nethernet.Wakeup) !Pair {
    var options: nethernet.ConnectionOptions = .{
        .native = .{ .disable_trickle = true },
        .allow_anonymous = true,
        // The harness gives up first, so a stalled connection can still be inspected.
        .negotiation_timeout_ms = config.timeout_ms + 1000,
        .connection_timeout_ms = config.timeout_ms + 1000,
    };
    const id: u64 = @intCast(index + 1);
    const client = try Connection.create(allocator, io, .client, id, "server", options);
    errdefer client.destroy();
    // Mux on both ends would put every agent in this process on one socket.
    options.native.enable_ice_udp_mux = config.ice_udp_mux;
    const server = try Connection.create(allocator, io, .server, id, "client", options);
    client.peer.subscribe(wakeup);
    server.peer.subscribe(wakeup);
    return .{ .client = client, .server = server };
}

fn negotiateAll(pairs: []Pair, io: std.Io, timeout_ms: u32, wakeup: *nethernet.Wakeup) !void {
    const started = std.Io.Clock.awake.now(io);
    while (true) {
        const token = wakeup.prepare();
        var ready: usize = 0;
        var progress = false;
        for (pairs) |*pair| {
            if (!pair.ready()) progress = (try pumpNegotiation(pair, 64)) or progress;
            ready += @intFromBool(pair.ready());
        }
        if (ready == pairs.len) return;

        const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
        if (elapsed.toMilliseconds() >= timeout_ms) {
            printUnready(pairs);
            return error.Timeout;
        }
        if (!progress) try wakeup.wait(io, token, timeoutIn(nanos(timeout_ms) - elapsed.nanoseconds));
    }
}

fn printUnready(pairs: []Pair) void {
    for (pairs, 0..) |pair, index| {
        if (pair.ready()) continue;
        for ([_]*Connection{ pair.client, pair.server }, [_][]const u8{ "client", "server" }) |connection, role| {
            const diagnostics = connection.diagnostics();
            std.debug.print("pair {d} {s}: state={s} ice={s} reliable={s} unreliable={s}\n", .{
                index,
                role,
                @tagName(connection.state()),
                @tagName(diagnostics.ice_state),
                @tagName(diagnostics.reliable.state),
                @tagName(diagnostics.unreliable.state),
            });
        }
    }
}

fn pumpNegotiation(pair: *Pair, budget: usize) !bool {
    var progress = false;
    for ([_]*Connection{ pair.client, pair.server }, [_]*Connection{ pair.server, pair.client }, [_][]const u8{ "client", "server" }) |source, destination, name| {
        for (0..budget) |_| {
            const event = try source.pollNegotiation() orelse break;
            progress = true;
            switch (event) {
                .signal => |signal| {
                    var routed = signal;
                    routed.network_id = name;
                    try destination.applySignal(routed);
                },
                .message => return error.UnexpectedMessage,
            }
        }
    }
    return progress;
}

fn sendDue(io: std.Io, run_started: std.Io.Timestamp, pair: *Pair, state: *State, metrics: *Metrics, payload: []u8, config: Config, now_ns: i96) bool {
    var sent_any = false;
    var budget = config.burst;
    while (budget != 0 and state.pending_count < state.pending.len) : (budget -= 1) {
        if (config.rate != 0 and now_ns < state.next_send_ns) break;

        const sequence = state.sequence +% 1;
        const pending = &state.pending[@intCast(sequence % state.pending.len)];
        if (pending.active) break;

        const size = payloadSize(config, sequence);
        const reliability: Reliability = switch (config.reliability) {
            .reliable => .reliable,
            .unreliable => .unreliable,
            .mixed => if (sequence % 10 == 0) .unreliable else .reliable,
        };
        writePayload(payload[0..size], sequence);
        const sent_ns = run_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        pair.client.send(payload[0..size], reliability) catch |err| {
            if (err == error.Backpressure) {
                metrics.backpressure += 1;
            } else {
                metrics.send_failures += 1;
                metrics.failures += 1;
            }
            break;
        };

        pending.* = .{ .active = true, .sequence = sequence, .sent_ns = sent_ns, .size = size, .reliability = reliability };
        state.sequence = sequence;
        state.pending_count += 1;
        metrics.sent += 1;
        metrics.in_flight += 1;
        sent_any = true;

        if (config.rate != 0) {
            const interval_ns: i96 = @intCast(std.time.ns_per_s / config.rate);
            state.next_send_ns += interval_ns;
            if (now_ns - state.next_send_ns > interval_ns * @as(i96, @intCast(config.burst)))
                state.next_send_ns = now_ns + interval_ns;
        }
    }
    return sent_any;
}

fn pumpServer(pair: *Pair, state: *State, metrics: *Metrics, budget: usize) !bool {
    var progress = false;
    for (0..budget) |_| {
        const event = try pair.server.poll() orelse break;
        progress = true;
        const message = switch (event) {
            .message => |message| message,
            .signal => continue,
        };
        const sequence = readSequence(message.data) orelse {
            metrics.corruptions += 1;
            continue;
        };
        if (!validPayload(message.data, sequence, message.data.len)) metrics.corruptions += 1;
        checkOrder(&state.last_reliable_sent, message, sequence, metrics);
        pair.server.send(message.data, message.reliability) catch {
            metrics.send_failures += 1;
            metrics.failures += 1;
        };
    }
    return progress;
}

fn pumpClient(io: std.Io, run_started: std.Io.Timestamp, pair: *Pair, state: *State, metrics: *Metrics, histogram: *Histogram, config: Config) !bool {
    var progress = false;
    for (0..config.poll_budget) |_| {
        const event = try pair.client.poll() orelse break;
        progress = true;
        const message = switch (event) {
            .message => |message| message,
            .signal => continue,
        };
        const sequence = readSequence(message.data) orelse {
            metrics.corruptions += 1;
            continue;
        };
        checkOrder(&state.last_reliable_echo, message, sequence, metrics);

        const pending = &state.pending[@intCast(sequence % state.pending.len)];
        if (!pending.active or pending.sequence != sequence) {
            metrics.unmatched_messages += 1;
            continue;
        }
        if (!validPayload(message.data, sequence, pending.size) or message.reliability != pending.reliability)
            metrics.corruptions += 1;

        const completed_ns = run_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        if (completed_ns >= pending.sent_ns) histogram.record(@intCast(completed_ns - pending.sent_ns));
        metrics.completed += 1;
        metrics.bytes += @as(u64, pending.size) * 2;
        metrics.in_flight -= 1;
        pending.active = false;
        state.pending_count -= 1;
        state.completed_since_churn += 1;
        if (config.churn_messages != 0 and state.completed_since_churn >= config.churn_messages) state.churn_due = true;
    }
    return progress;
}

// Every message takes the next sequence, so reliable ones must arrive in increasing order.
fn checkOrder(last: *u64, message: nethernet.Message, sequence: u64, metrics: *Metrics) void {
    if (message.reliability != .reliable) return;
    if (sequence <= last.*) metrics.reliable_order_violations += 1;
    last.* = sequence;
}

fn fail(state: *State, metrics: *Metrics, counter: *u64) void {
    counter.* += 1;
    metrics.failures += 1;
    state.phase = .dead;
}

fn expirePending(state: *State, metrics: *Metrics, now_ns: i96, timeout_ns: i96) void {
    if (state.pending_count == 0) return;
    for (state.pending) |*pending| {
        if (!pending.active) continue;
        // A dropped unreliable message would otherwise hold its slot for the whole timeout.
        const limit_ns = if (pending.reliability == .unreliable) @min(timeout_ns, 2 * std.time.ns_per_s) else timeout_ns;
        if (now_ns - pending.sent_ns >= limit_ns) expireOne(state, metrics, pending);
    }
}

fn abortPending(state: *State, metrics: *Metrics) void {
    for (state.pending) |*pending| {
        if (!pending.active) continue;
        pending.active = false;
        state.pending_count -= 1;
        metrics.in_flight -= 1;
    }
}

fn expireOne(state: *State, metrics: *Metrics, pending: *Pending) void {
    switch (pending.reliability) {
        .reliable => {
            metrics.reliable_timeouts += 1;
            metrics.failures += 1;
        },
        .unreliable => metrics.unreliable_timeouts += 1,
    }
    pending.active = false;
    state.pending_count -= 1;
    metrics.in_flight -= 1;
}

fn beginReconnect(
    allocator: std.mem.Allocator,
    io: std.Io,
    pair: *Pair,
    state: *State,
    index: usize,
    config: Config,
    metrics: *Metrics,
    now_ns: i96,
    wakeup: *nethernet.Wakeup,
) bool {
    state.churn_due = false;
    state.completed_since_churn = 0;
    const replacement = createPair(allocator, io, index, config, wakeup) catch {
        metrics.negotiation_failures += 1;
        metrics.failures += 1;
        return false;
    };
    replacement.client.start() catch {
        replacement.destroy();
        metrics.negotiation_failures += 1;
        metrics.failures += 1;
        return false;
    };
    metrics.native_dropped_unreliable += pair.client.callbackStats().dropped_unreliable_packets +
        pair.server.callbackStats().dropped_unreliable_packets;
    updateHighWater(metrics, pair.*);
    pair.destroy();
    pair.* = replacement;
    state.phase = .negotiating;
    state.negotiation_started_ns = now_ns;
    return true;
}

fn updateHighWater(metrics: *Metrics, pair: Pair) void {
    for ([_]*Connection{ pair.client, pair.server }) |connection| {
        const stats = connection.callbackStats();
        metrics.buffered_high_water_bytes = @max(metrics.buffered_high_water_bytes, connection.diagnostics().bufferedOutgoingBytes());
        metrics.queue_high_water_bytes = @max(metrics.queue_high_water_bytes, stats.queue_high_water_bytes);
        metrics.queue_high_water_entries = @max(metrics.queue_high_water_entries, stats.queue_high_water_entries);
    }
}

fn payloadSize(config: Config, sequence: u64) usize {
    if (config.profile == .fixed) return config.payload_size;
    const selector = sequence % 100;
    const size: usize = if (selector < 35) 32 else if (selector < 60) 64 else if (selector < 75) 96 else if (selector < 85) 128 else if (selector < 92) 256 else if (selector < 96) 512 else if (selector < 99) 1400 else 8192;
    return @min(config.payload_size, size);
}

fn writePayload(data: []u8, sequence: u64) void {
    std.mem.writeInt(u64, data[0..8], sequence, .little);
    std.mem.writeInt(u64, data[8..16], ~sequence, .little);
    for (data[16..], 16..) |*byte, index| byte.* = @truncate(sequence +% index);
}

fn readSequence(data: []const u8) ?u64 {
    if (data.len < 16) return null;
    return std.mem.readInt(u64, data[0..8], .little);
}

fn validPayload(data: []const u8, sequence: u64, expected_size: usize) bool {
    if (data.len != expected_size or data.len < 16) return false;
    if (std.mem.readInt(u64, data[0..8], .little) != sequence or std.mem.readInt(u64, data[8..16], .little) != ~sequence) return false;
    for (data[16..], 16..) |byte, index| {
        if (byte != @as(u8, @truncate(sequence +% index))) return false;
    }
    return true;
}

fn parseArgs(args: std.process.Args, allocator: std.mem.Allocator) !Config {
    var result: Config = .{};
    var iterator = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iterator.deinit();
    _ = iterator.next();
    var buffer: [32]u8 = undefined;
    while (iterator.next()) |argument| {
        if (!std.mem.startsWith(u8, argument, "--") or argument.len - 2 > buffer.len) return error.InvalidArgument;
        const name = buffer[0 .. argument.len - 2];
        @memcpy(name, argument[2..]);
        std.mem.replaceScalar(u8, name, '-', '_');
        inline for (@typeInfo(Config).@"struct".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                @field(result, field.name) = switch (@typeInfo(field.type)) {
                    .bool => true,
                    .int => try std.fmt.parseInt(field.type, iterator.next() orelse return error.MissingArgument, 10),
                    .@"enum" => std.meta.stringToEnum(field.type, iterator.next() orelse return error.MissingArgument) orelse
                        return error.InvalidArgument,
                    else => comptime unreachable,
                };
                break;
            }
        } else return error.InvalidArgument;
    }
    return result;
}

const Memory = struct {
    current: ?u64 = null,
    peak: ?u64 = null,
};

fn residentBytes(io: std.Io) Memory {
    switch (builtin.os.tag) {
        .windows => {
            var counters: ProcessMemoryCounters = undefined;
            counters.cb = @sizeOf(ProcessMemoryCounters);
            if (GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0) return .{};
            return .{ .current = counters.working_set_size, .peak = counters.peak_working_set_size };
        },
        .linux => {
            var memory: Memory = .{ .peak = @as(u64, @intCast(std.posix.getrusage(std.posix.rusage.SELF).maxrss)) * 1024 };
            var buffer: [8192]u8 = undefined;
            const status = std.Io.Dir.cwd().readFile(io, "/proc/self/status", &buffer) catch return memory;
            var lines = std.mem.splitScalar(u8, status, '\n');
            while (lines.next()) |line| {
                if (!std.mem.startsWith(u8, line, "VmRSS:")) continue;
                var fields = std.mem.tokenizeAny(u8, line[6..], " \t");
                const kib = std.fmt.parseInt(u64, fields.next() orelse break, 10) catch break;
                memory.current = kib * 1024;
            }
            return memory;
        },
        else => return .{},
    }
}

const ProcessMemoryCounters = extern struct {
    cb: u32,
    page_fault_count: u32,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "psapi" fn GetProcessMemoryInfo(*anyopaque, *ProcessMemoryCounters, u32) callconv(.winapi) i32;
