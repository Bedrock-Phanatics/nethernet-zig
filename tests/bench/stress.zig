const std = @import("std");
const builtin = @import("builtin");
const nethernet = @import("nethernet");

const Connection = nethernet.Connection;
const Reliability = nethernet.Reliability;

const Config = struct {
    connections: usize = 100,
    duration_ms: u64 = 30_000,
    message_limit: u64 = 0,
    payload_size: usize = 8192,
    rate: u64 = 20,
    burst: usize = 4,
    max_in_flight: usize = 64,
    poll_budget: usize = 128,
    churn_messages: u64 = 0,
    reliability: enum { reliable, unreliable, mixed } = .mixed,
    profile: enum { fixed, bedrock, rollover } = .bedrock,
    timeout_ms: u32 = 5_000,
    drain_timeout_ms: u32 = 5_000,
};

const Pair = struct {
    client: *Connection,
    server: *Connection,

    fn destroy(self: Pair) void {
        self.client.destroy();
        self.server.destroy();
    }
};

const Phase = enum {
    active,
    negotiating,
    dead,
};

const Pending = struct {
    active: bool = false,
    sequence: u64 = 0,
    sent_ns: i96 = 0,
    size: usize = 0,
    reliability: Reliability = .reliable,
};

const RuntimeState = struct {
    phase: Phase = .active,
    sequence: u64 = 0,
    next_send_ns: i96 = 0,
    negotiation_started_ns: i96 = 0,
    pending: []Pending,
    pending_count: usize = 0,
    completed_since_churn: u64 = 0,
    churn_due: bool = false,
};

const Metrics = struct {
    sent: u64 = 0,
    completed: u64 = 0,
    bytes: u64 = 0,

    in_flight: u64 = 0,
    peak_in_flight: u64 = 0,

    reconnects: u64 = 0,
    failures: u64 = 0,
    send_failures: u64 = 0,
    poll_failures: u64 = 0,
    negotiation_failures: u64 = 0,

    reliable_timeouts: u64 = 0,
    unreliable_timeouts: u64 = 0,

    corruptions: u64 = 0,
    unmatched_messages: u64 = 0,

    native_dropped_unreliable: u64 = 0,

    queue_high_water_bytes: usize = 0,
    buffered_high_water_bytes: usize = 0,

    max_loop_gap_ns: u64 = 0,
};

const LatencyHistogram = struct {
    const bucket_width_ns: u64 = 10_000;
    const bucket_count: usize = 200_001;

    buckets: []u64,
    count: u64 = 0,
    overflow: u64 = 0,
    max_ns: u64 = 0,

    fn init(allocator: std.mem.Allocator) !LatencyHistogram {
        const buckets = try allocator.alloc(u64, bucket_count);
        @memset(buckets, 0);

        return .{
            .buckets = buckets,
        };
    }

    fn deinit(self: *LatencyHistogram, allocator: std.mem.Allocator) void {
        allocator.free(self.buckets);
    }

    fn record(self: *LatencyHistogram, latency_ns: u64) void {
        self.count += 1;
        self.max_ns = @max(self.max_ns, latency_ns);

        const raw_index = latency_ns / bucket_width_ns;

        if (raw_index >= self.buckets.len) {
            self.overflow += 1;
            return;
        }

        self.buckets[@intCast(raw_index)] += 1;
    }

    fn percentileUs(self: LatencyHistogram, percent: u64) f64 {
        if (self.count == 0) return 0;

        const target = (self.count * percent + 99) / 100;

        var accumulated: u64 = 0;

        for (self.buckets, 0..) |count, index| {
            accumulated += count;

            if (accumulated >= target) {
                const ns = @as(u64, @intCast(index)) * bucket_width_ns;
                return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
            }
        }

        const ns =
            @as(u64, @intCast(self.buckets.len)) *
            bucket_width_ns;

        return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
    }

    fn maxUs(self: LatencyHistogram) f64 {
        return @as(f64, @floatFromInt(self.max_ns)) /
            std.time.ns_per_us;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var config = try parseArgs(init.minimal.args, allocator);

    if (config.connections == 0 or
        config.payload_size < 16 or
        config.burst == 0 or
        config.max_in_flight == 0 or
        config.poll_budget == 0)
    {
        return error.InvalidConfiguration;
    }

    if (config.profile == .rollover) {
        config.max_in_flight = @max(config.max_in_flight, 1024);
    }

    const rss_process_start = residentBytes(io);

    const pairs = try allocator.alloc(Pair, config.connections);
    defer allocator.free(pairs);

    var created: usize = 0;
    defer {
        for (pairs[0..created]) |pair| {
            pair.destroy();
        }
    }

    while (created < pairs.len) : (created += 1) {
        pairs[created] = try createPair(
            allocator,
            io,
            created,
            config.timeout_ms,
        );
    }

    const setup_started = std.Io.Clock.awake.now(io);

    for (pairs) |pair| {
        try pair.client.start();
    }

    try negotiateAll(
        pairs,
        io,
        config.timeout_ms,
    );

    const setup_ns =
        setup_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;

    const slot_count = std.math.mul(
        usize,
        config.connections,
        config.max_in_flight,
    ) catch return error.InvalidConfiguration;

    const pending_storage = try allocator.alloc(Pending, slot_count);
    defer allocator.free(pending_storage);

    for (pending_storage) |*pending| {
        pending.* = .{};
    }

    const states = try allocator.alloc(RuntimeState, config.connections);
    defer allocator.free(states);

    const interval_ns: i96 = if (config.rate == 0)
        0
    else
        @intCast(std.time.ns_per_s / config.rate);

    for (states, 0..) |*state, index| {
        const start = index * config.max_in_flight;
        const end = start + config.max_in_flight;

        var phase_offset: i96 = 0;

        if (config.rate != 0 and config.connections > 1) {
            phase_offset =
                interval_ns *
                @as(i96, @intCast(index)) /
                @as(i96, @intCast(config.connections));
        }

        state.* = .{
            .pending = pending_storage[start..end],
            .next_send_ns = phase_offset,
        };
    }

    const maximum_payload = @max(config.payload_size, 8192);

    const payload = try allocator.alloc(u8, maximum_payload);
    defer allocator.free(payload);

    var histogram = try LatencyHistogram.init(allocator);
    defer histogram.deinit(allocator);

    const rss_start = residentBytes(io);

    var metrics: Metrics = .{};

    const run_started = std.Io.Clock.awake.now(io);
    const cpu_started = std.Io.Clock.cpu_process.now(io);

    const deadline_ns: i96 =
        @as(i96, @intCast(config.duration_ms)) *
        std.time.ns_per_ms;

    const timeout_ns: i96 =
        @as(i96, @intCast(config.timeout_ms)) *
        std.time.ns_per_ms;

    const drain_timeout_ns: i96 =
        @as(i96, @intCast(config.drain_timeout_ms)) *
        std.time.ns_per_ms;

    var generating = true;
    var drain_started_ns: ?i96 = null;

    var next_timeout_sweep_ns: i96 = 0;
    var next_stats_sample_ns: i96 = 0;
    var previous_loop_ns: i96 = 0;

    while (true) {
        const now =
            std.Io.Clock.awake.now(io);

        const now_ns =
            run_started.durationTo(now).nanoseconds;

        if (previous_loop_ns != 0 and now_ns >= previous_loop_ns) {
            const gap: u64 =
                @intCast(now_ns - previous_loop_ns);

            metrics.max_loop_gap_ns =
                @max(metrics.max_loop_gap_ns, gap);
        }

        previous_loop_ns = now_ns;

        if (generating) {
            if ((config.duration_ms != 0 and now_ns >= deadline_ns) or
                (config.message_limit != 0 and
                    metrics.completed >= config.message_limit))
            {
                generating = false;
                drain_started_ns = now_ns;
            }
        }

        var progress = false;

        for (pairs, states, 0..) |*pair, *state, index| {
            if (state.phase != .negotiating) continue;

            const negotiation_progress =
                pumpNegotiation(pair, config.poll_budget) catch {
                    metrics.negotiation_failures += 1;
                    metrics.failures += 1;
                    state.phase = .dead;
                    continue;
                };

            progress = progress or negotiation_progress;

            if (pair.client.ready() and pair.server.ready()) {
                state.phase = .active;
                state.next_send_ns = now_ns;
                state.completed_since_churn = 0;
                metrics.reconnects += 1;
                progress = true;
                continue;
            }

            if (now_ns - state.negotiation_started_ns >= timeout_ns) {
                _ = index;
                metrics.negotiation_failures += 1;
                metrics.failures += 1;
                state.phase = .dead;
            }
        }

        for (pairs, states) |*pair, *state| {
            if (state.phase != .active) continue;

            const server_progress = pumpServer(
                pair,
                state,
                &metrics,
                config.poll_budget,
            ) catch {
                metrics.poll_failures += 1;
                metrics.failures += 1;
                state.phase = .dead;
                false
            };

            progress = progress or server_progress;
        }

        for (pairs, states) |*pair, *state| {
            if (state.phase != .active) continue;

            const client_progress = pumpClient(
                io,
                run_started,
                pair,
                state,
                &metrics,
                &histogram,
                config,
            ) catch {
                metrics.poll_failures += 1;
                metrics.failures += 1;
                state.phase = .dead;
                false
            };

            progress = progress or client_progress;
        }

        if (now_ns >= next_timeout_sweep_ns) {
            for (states) |*state| {
                expirePending(
                    state,
                    &metrics,
                    now_ns,
                    timeout_ns,
                );
            }

            next_timeout_sweep_ns =
                now_ns + 10 * std.time.ns_per_ms;
        }

        if (generating) {
            for (pairs, states, 0..) |*pair, *state, index| {
                if (state.phase != .active) continue;

                if (state.churn_due and state.pending_count == 0) {
                    const started = beginReconnect(
                        allocator,
                        io,
                        pair,
                        state,
                        index,
                        config,
                        &metrics,
                        now_ns,
                    );

                    progress = progress or started;
                    continue;
                }

                if (state.churn_due) continue;

                const sent = sendDue(
                    pair,
                    state,
                    &metrics,
                    payload,
                    config,
                    now_ns,
                );

                progress = progress or sent;
            }
        }

        if (now_ns >= next_stats_sample_ns) {
            for (pairs) |pair| {
                updateHighWater(&metrics, pair);
            }

            next_stats_sample_ns =
                now_ns + 100 * std.time.ns_per_ms;
        }

        if (!generating) {
            if (metrics.in_flight == 0) {
                break;
            }

            const drain_start = drain_started_ns orelse now_ns;

            if (now_ns - drain_start >= drain_timeout_ns) {
                for (states) |*state| {
                    expireAllPending(state, &metrics);
                }

                break;
            }
        }

        if (!progress) {
            try std.Io.sleep(
                io,
                .fromMilliseconds(1),
                .awake,
            );
        }
    }

    for (pairs) |pair| {
        recordFinalStats(&metrics, pair);
    }

    const elapsed_ns =
        run_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;

    const cpu_ns =
        cpu_started.durationTo(std.Io.Clock.cpu_process.now(io)).nanoseconds;

    const rss_end = residentBytes(io);

    for (pairs[0..created]) |pair| {
        pair.destroy();
    }

    created = 0;

    const rss_after_close = residentBytes(io);

    printReport(
        config,
        states,
        metrics,
        histogram,
        setup_ns,
        elapsed_ns,
        cpu_ns,
        rss_process_start,
        rss_start,
        rss_end,
        rss_after_close,
    );

    if (metrics.failures != 0 or metrics.corruptions != 0) {
        return error.StressFailure;
    }
}

fn createPair(
    allocator: std.mem.Allocator,
    io: std.Io,
    index: usize,
    timeout_ms: u32,
) !Pair {
    const options: nethernet.ConnectionOptions = .{
        .native = .{
            .disable_trickle = true,
        },
        .allow_anonymous = true,
        .negotiation_timeout_ms = timeout_ms,
        .connection_timeout_ms = timeout_ms,
    };

    const id: u64 = @intCast(index + 1);

    const client = try Connection.create(
        allocator,
        io,
        .client,
        id,
        "server",
        options,
    );

    errdefer client.destroy();

    const server = try Connection.create(
        allocator,
        io,
        .server,
        id,
        "client",
        options,
    );

    errdefer server.destroy();

    return .{
        .client = client,
        .server = server,
    };
}

fn negotiateAll(
    pairs: []Pair,
    io: std.Io,
    timeout_ms: u32,
) !void {
    const started = std.Io.Clock.awake.now(io);

    while (true) {
        var ready_count: usize = 0;
        var progress = false;

        for (pairs) |*pair| {
            if (pair.client.ready() and pair.server.ready()) {
                ready_count += 1;
                continue;
            }

            progress =
                (try pumpNegotiation(pair, 64)) or
                progress;

            if (pair.client.ready() and pair.server.ready()) {
                ready_count += 1;
            }
        }

        if (ready_count == pairs.len) {
            return;
        }

        if (started
            .durationTo(std.Io.Clock.awake.now(io))
            .toMilliseconds() >= timeout_ms)
        {
            return error.Timeout;
        }

        if (!progress) {
            try std.Io.sleep(
                io,
                .fromMilliseconds(1),
                .awake,
            );
        }
    }
}

fn pumpNegotiation(
    pair: *Pair,
    budget: usize,
) !bool {
    var progress = false;

    for (
        [_]*Connection{
            pair.client,
            pair.server,
        },
        [_]*Connection{
            pair.server,
            pair.client,
        },
        [_][]const u8{
            "client",
            "server",
        },
    ) |source, destination, name| {
        var processed: usize = 0;

        while (processed < budget) : (processed += 1) {
            const event =
                try source.pollNegotiation() orelse break;

            progress = true;

            switch (event) {
                .signal => |signal| {
                    var routed = signal;
                    routed.network_id = name;

                    try destination.applySignal(routed);
                },
                .message => {
                    return error.UnexpectedMessage;
                },
            }
        }
    }

    return progress;
}

fn sendDue(
    pair: *Pair,
    state: *RuntimeState,
    metrics: *Metrics,
    payload: []u8,
    config: Config,
    now_ns: i96,
) bool {
    if (state.pending_count >= state.pending.len) {
        return false;
    }

    var sent_any = false;
    var budget = config.burst;

    while (budget != 0 and
        state.pending_count < state.pending.len)
    {
        if (config.rate != 0 and now_ns < state.next_send_ns) {
            break;
        }

        const sequence = state.sequence +% 1;

        const slot_index: usize = @intCast(
            sequence %
                @as(u64, @intCast(state.pending.len)),
        );

        const pending = &state.pending[slot_index];

        if (pending.active) {
            break;
        }

        const size = payloadSize(config, sequence);
        const reliability = reliabilityFor(config, sequence);

        writePayload(
            payload[0..size],
            sequence,
        );

        pair.client.send(
            payload[0..size],
            reliability,
        ) catch {
            metrics.send_failures += 1;
            metrics.failures += 1;
            break;
        };

        pending.* = .{
            .active = true,
            .sequence = sequence,
            .sent_ns = now_ns,
            .size = size,
            .reliability = reliability,
        };

        state.sequence = sequence;
        state.pending_count += 1;

        metrics.sent += 1;
        metrics.in_flight += 1;
        metrics.peak_in_flight =
            @max(
                metrics.peak_in_flight,
                metrics.in_flight,
            );

        sent_any = true;
        budget -= 1;

        if (config.rate != 0) {
            const interval_ns: i96 =
                @intCast(std.time.ns_per_s / config.rate);

            state.next_send_ns += interval_ns;

            const max_catchup =
                interval_ns *
                @as(i96, @intCast(config.burst));

            if (now_ns > state.next_send_ns and
                now_ns - state.next_send_ns > max_catchup)
            {
                state.next_send_ns =
                    now_ns + interval_ns;
            }
        }
    }

    return sent_any;
}

fn pumpServer(
    pair: *Pair,
    state: *RuntimeState,
    metrics: *Metrics,
    budget: usize,
) !bool {
    _ = state;

    var progress = false;
    var processed: usize = 0;

    while (processed < budget) : (processed += 1) {
        pair.server.prepareWait();

        const event =
            try pair.server.poll() orelse break;

        progress = true;

        switch (event) {
            .message => |message| {
                const sequence =
                    readSequence(message.data) orelse {
                        metrics.corruptions += 1;
                        continue;
                    };

                if (!validPayload(
                    message.data,
                    sequence,
                    message.data.len,
                )) {
                    metrics.corruptions += 1;
                }

                pair.server.send(
                    message.data,
                    message.reliability,
                ) catch {
                    metrics.send_failures += 1;
                    metrics.failures += 1;
                };
            },
            .signal => {},
        }
    }

    return progress;
}

fn pumpClient(
    io: std.Io,
    run_started: std.Io.Timestamp,
    pair: *Pair,
    state: *RuntimeState,
    metrics: *Metrics,
    histogram: *LatencyHistogram,
    config: Config,
) !bool {
    var progress = false;
    var processed: usize = 0;

    while (processed < config.poll_budget) : (processed += 1) {
        pair.client.prepareWait();

        const event =
            try pair.client.poll() orelse break;

        progress = true;

        switch (event) {
            .message => |message| {
                const sequence =
                    readSequence(message.data) orelse {
                        metrics.corruptions += 1;
                        continue;
                    };

                const slot_index: usize = @intCast(
                    sequence %
                        @as(u64, @intCast(state.pending.len)),
                );

                const pending = &state.pending[slot_index];

                if (!pending.active or
                    pending.sequence != sequence)
                {
                    metrics.unmatched_messages += 1;
                    continue;
                }

                if (!validPayload(
                    message.data,
                    sequence,
                    pending.size,
                )) {
                    metrics.corruptions += 1;
                }

                if (message.reliability != pending.reliability) {
                    metrics.corruptions += 1;
                }

                const completed_ns =
                    run_started
                    .durationTo(std.Io.Clock.awake.now(io))
                    .nanoseconds;

                if (completed_ns >= pending.sent_ns) {
                    histogram.record(
                        @intCast(
                            completed_ns -
                                pending.sent_ns,
                        ),
                    );
                }

                metrics.completed += 1;
                metrics.bytes +=
                    @as(u64, @intCast(pending.size)) * 2;

                metrics.in_flight -= 1;

                pending.active = false;
                state.pending_count -= 1;

                state.completed_since_churn += 1;

                if (config.churn_messages != 0 and
                    state.completed_since_churn >=
                        config.churn_messages)
                {
                    state.churn_due = true;
                }
            },
            .signal => {},
        }
    }

    return progress;
}

fn expirePending(
    state: *RuntimeState,
    metrics: *Metrics,
    now_ns: i96,
    timeout_ns: i96,
) void {
    if (state.pending_count == 0) return;

    for (state.pending) |*pending| {
        if (!pending.active) continue;

        if (now_ns - pending.sent_ns < timeout_ns) {
            continue;
        }

        expireOne(
            state,
            metrics,
            pending,
        );
    }
}

fn expireAllPending(
    state: *RuntimeState,
    metrics: *Metrics,
) void {
    for (state.pending) |*pending| {
        if (!pending.active) continue;

        expireOne(
            state,
            metrics,
            pending,
        );
    }
}

fn expireOne(
    state: *RuntimeState,
    metrics: *Metrics,
    pending: *Pending,
) void {
    switch (pending.reliability) {
        .reliable => {
            metrics.reliable_timeouts += 1;
            metrics.failures += 1;
        },
        .unreliable => {
            metrics.unreliable_timeouts += 1;
        },
    }

    pending.active = false;

    state.pending_count -= 1;
    metrics.in_flight -= 1;
}

fn beginReconnect(
    allocator: std.mem.Allocator,
    io: std.Io,
    pair: *Pair,
    state: *RuntimeState,
    index: usize,
    config: Config,
    metrics: *Metrics,
    now_ns: i96,
) bool {
    const replacement = createPair(
        allocator,
        io,
        index,
        config.timeout_ms,
    ) catch {
        metrics.negotiation_failures += 1;
        metrics.failures += 1;
        state.churn_due = false;
        state.completed_since_churn = 0;
        return false;
    };

    replacement.client.start() catch {
        replacement.destroy();

        metrics.negotiation_failures += 1;
        metrics.failures += 1;

        state.churn_due = false;
        state.completed_since_churn = 0;

        return false;
    };

    recordFinalStats(metrics, pair.*);

    pair.destroy();
    pair.* = replacement;

    state.phase = .negotiating;
    state.negotiation_started_ns = now_ns;
    state.churn_due = false;
    state.completed_since_churn = 0;

    return true;
}

fn updateHighWater(
    metrics: *Metrics,
    pair: Pair,
) void {
    const client = pair.client.callbackStats();
    const server = pair.server.callbackStats();

    metrics.buffered_high_water_bytes = @max(
        metrics.buffered_high_water_bytes,
        @max(
            pair.client
                .diagnostics()
                .bufferedOutgoingBytes(),
            pair.server
                .diagnostics()
                .bufferedOutgoingBytes(),
        ),
    );

    metrics.queue_high_water_bytes = @max(
        metrics.queue_high_water_bytes,
        @max(
            client.queue_high_water_bytes,
            server.queue_high_water_bytes,
        ),
    );
}

fn recordFinalStats(
    metrics: *Metrics,
    pair: Pair,
) void {
    const client = pair.client.callbackStats();
    const server = pair.server.callbackStats();

    metrics.native_dropped_unreliable +=
        client.dropped_unreliable_packets +
        server.dropped_unreliable_packets;

    updateHighWater(
        metrics,
        pair,
    );
}

fn payloadSize(
    config: Config,
    sequence: u64,
) usize {
    if (config.profile != .bedrock) {
        return config.payload_size;
    }

    const selector = sequence % 100;

    const selected: usize =
        if (selector < 35)
            32
        else if (selector < 60)
            64
        else if (selector < 75)
            96
        else if (selector < 85)
            128
        else if (selector < 92)
            256
        else if (selector < 96)
            512
        else if (selector < 99)
            1400
        else
            8192;

    return @min(
        config.payload_size,
        selected,
    );
}

fn reliabilityFor(
    config: Config,
    sequence: u64,
) Reliability {
    return switch (config.reliability) {
        .reliable => .reliable,
        .unreliable => .unreliable,
        .mixed =>
            if (sequence % 10 == 0)
                .unreliable
            else
                .reliable,
    };
}

fn writePayload(
    data: []u8,
    sequence: u64,
) void {
    std.mem.writeInt(
        u64,
        data[0..8],
        sequence,
        .little,
    );

    std.mem.writeInt(
        u64,
        data[8..16],
        ~sequence,
        .little,
    );

    for (data[16..], 16..) |*byte, index| {
        byte.* =
            @truncate(sequence +% index);
    }
}

fn readSequence(
    data: []const u8,
) ?u64 {
    if (data.len < 16) return null;

    return std.mem.readInt(
        u64,
        data[0..8],
        .little,
    );
}

fn validPayload(
    data: []const u8,
    sequence: u64,
    expected_size: usize,
) bool {
    if (data.len != expected_size) {
        return false;
    }

    if (data.len < 16) {
        return false;
    }

    if (std.mem.readInt(
        u64,
        data[0..8],
        .little,
    ) != sequence) {
        return false;
    }

    if (std.mem.readInt(
        u64,
        data[8..16],
        .little,
    ) != ~sequence) {
        return false;
    }

    for (data[16..], 16..) |byte, index| {
        if (byte !=
            @as(
                u8,
                @truncate(sequence +% index),
            ))
        {
            return false;
        }
    }

    return true;
}

fn parseArgs(
    args: std.process.Args,
    allocator: std.mem.Allocator,
) !Config {
    var result: Config = .{};

    var duration_set = false;
    var messages_set = false;

    var iterator =
        try std.process.Args.Iterator.initAllocator(
            args,
            allocator,
        );

    defer iterator.deinit();

    _ = iterator.next();

    while (iterator.next()) |argument| {
        if (std.mem.eql(
            u8,
            argument,
            "--connections",
        )) {
            result.connections =
                try parse(
                    usize,
                    iterator.next(),
                );
        } else if (std.mem.eql(
            u8,
            argument,
            "--duration-ms",
        )) {
            result.duration_ms =
                try parse(
                    u64,
                    iterator.next(),
                );

            duration_set = true;
        } else if (std.mem.eql(
            u8,
            argument,
            "--messages",
        )) {
            result.message_limit =
                try parse(
                    u64,
                    iterator.next(),
                );

            messages_set = true;
        } else if (std.mem.eql(
            u8,
            argument,
            "--payload-size",
        )) {
            result.payload_size =
                try parse(
                    usize,
                    iterator.next(),
                );
        } else if (std.mem.eql(
            u8,
            argument,
            "--rate",
        )) {
            result.rate =
                try parse(
                    u64,
                    iterator.next(),
                );
        } else if (std.mem.eql(
            u8,
            argument,
            "--burst",
        )) {
            result.burst =
                try parse(
                    usize,
                    iterator.next(),
                );
        } else if (std.mem.eql(
            u8,
            argument,
            "--max-in-flight",
        )) {
            result.max_in_flight =
                try parse(
                    usize,
                    iterator.next(),
                );
        } else if (std.mem.eql(
            u8,
            argument,
            "--poll-budget",
        )) {
            result.poll_budget =
                try parse(
                    usize,
                    iterator.next(),
                );
        } else if (std.mem.eql(
            u8,
            argument,
            "--churn-messages",
        )) {
            result.churn_messages =
                try parse(
                    u64,
                    iterator.next(),
                );
        } else if (std.mem.eql(
            u8,
            argument,
            "--timeout-ms",
        )) {
            result.timeout_ms =
                try parse(
                    u32,
                    iterator.next(),
                );
        } else if (std.mem.eql(
            u8,
            argument,
            "--drain-timeout-ms",
        )) {
            result.drain_timeout_ms =
                try parse(
                    u32,
                    iterator.next(),
                );
        } else if (std.mem.eql(
            u8,
            argument,
            "--reliability",
        )) {
            const value =
                iterator.next() orelse
                return error.MissingArgument;

            result.reliability =
                std.meta.stringToEnum(
                    @TypeOf(result.reliability),
                    value,
                ) orelse
                return error.InvalidArgument;
        } else if (std.mem.eql(
            u8,
            argument,
            "--profile",
        )) {
            const value =
                iterator.next() orelse
                return error.MissingArgument;

            result.profile =
                std.meta.stringToEnum(
                    @TypeOf(result.profile),
                    value,
                ) orelse
                return error.InvalidArgument;
        } else {
            return error.InvalidArgument;
        }
    }

    if (result.profile == .rollover) {
        result.connections = 1;
        result.reliability = .reliable;
        result.payload_size = 16;
        result.rate = 0;
        result.burst = @max(
            result.burst,
            256,
        );
        result.max_in_flight = @max(
            result.max_in_flight,
            1024,
        );

        if (!duration_set and !messages_set) {
            result.duration_ms = 0;
            result.message_limit =
                @as(u64, 1) << 32;
        }
    }

    return result;
}

fn parse(
    comptime T: type,
    value: ?[:0]const u8,
) !T {
    return std.fmt.parseInt(
        T,
        value orelse
            return error.MissingArgument,
        10,
    );
}

fn countStates(
    states: []RuntimeState,
    phase: Phase,
) usize {
    var count: usize = 0;

    for (states) |state| {
        if (state.phase == phase) {
            count += 1;
        }
    }

    return count;
}

fn printReport(
    config: Config,
    states: []RuntimeState,
    metrics: Metrics,
    histogram: LatencyHistogram,
    setup_ns: i96,
    elapsed_ns: i96,
    cpu_ns: i96,
    rss_process_start: Memory,
    rss_start: Memory,
    rss_end: Memory,
    rss_after_close: Memory,
) void {
    const seconds =
        @as(f64, @floatFromInt(elapsed_ns)) /
        std.time.ns_per_s;

    const safe_seconds =
        if (seconds > 0)
            seconds
        else
            0.000001;

    const cpu_percent =
        @as(f64, @floatFromInt(cpu_ns)) /
        @as(f64, @floatFromInt(elapsed_ns)) *
        100;

    const completion_percent =
        if (metrics.sent == 0)
            0
        else
            @as(f64, @floatFromInt(metrics.completed)) /
                @as(f64, @floatFromInt(metrics.sent)) *
                100;

    const rss_growth: ?i128 =
        if (rss_end.current != null and
            rss_start.current != null)
        @as(i128, rss_end.current.?) -
            @as(i128, rss_start.current.?)
    else
        null;

    const active_connections =
        countStates(
            states,
            .active,
        );

    const negotiating_connections =
        countStates(
            states,
            .negotiating,
        );

    const dead_connections =
        countStates(
            states,
            .dead,
        );

    std.debug.print(
        "{{" ++
            "\"os\":\"{s}\"," ++
            "\"arch\":\"{s}\"," ++
            "\"zig\":\"{s}\"," ++
            "\"mode\":\"{s}\"," ++
            "\"connections\":{d}," ++
            "\"active_connections\":{d}," ++
            "\"negotiating_connections\":{d}," ++
            "\"dead_connections\":{d}," ++
            "\"duration_ms\":{d}," ++
            "\"message_limit\":{d}," ++
            "\"payload_size\":{d}," ++
            "\"rate_per_connection\":{d}," ++
            "\"burst\":{d}," ++
            "\"max_in_flight_per_connection\":{d}," ++
            "\"poll_budget\":{d}," ++
            "\"profile\":\"{s}\"," ++
            "\"reliability\":\"{s}\"," ++
            "\"setup_ms\":{d:.2}," ++
            "\"sent\":{d}," ++
            "\"completed\":{d}," ++
            "\"completion_percent\":{d:.3}," ++
            "\"in_flight\":{d}," ++
            "\"peak_in_flight\":{d}," ++
            "\"messages_per_second\":{d:.1}," ++
            "\"sent_per_second\":{d:.1}," ++
            "\"bytes\":{d}," ++
            "\"mib_per_second\":{d:.2},",
        .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            builtin.zig_version_string,
            @tagName(builtin.mode),

            config.connections,

            active_connections,
            negotiating_connections,
            dead_connections,

            config.duration_ms,
            config.message_limit,
            config.payload_size,
            config.rate,
            config.burst,
            config.max_in_flight,
            config.poll_budget,

            @tagName(config.profile),
            @tagName(config.reliability),

            @as(f64, @floatFromInt(setup_ns)) /
                std.time.ns_per_ms,

            metrics.sent,
            metrics.completed,
            completion_percent,

            metrics.in_flight,
            metrics.peak_in_flight,

            @as(f64, @floatFromInt(metrics.completed)) /
                safe_seconds,

            @as(f64, @floatFromInt(metrics.sent)) /
                safe_seconds,

            metrics.bytes,

            @as(f64, @floatFromInt(metrics.bytes)) /
                safe_seconds /
                (1024 * 1024),
        },
    );

    std.debug.print(
        "\"latency_p50_us\":{d:.1}," ++
            "\"latency_p95_us\":{d:.1}," ++
            "\"latency_p99_us\":{d:.1}," ++
            "\"latency_max_us\":{d:.1}," ++
            "\"latency_samples\":{d}," ++
            "\"latency_overflow_samples\":{d}," ++
            "\"max_loop_gap_us\":{d:.1}," ++
            "\"cpu_percent\":{d:.1}," ++
            "\"reconnects\":{d}," ++
            "\"failures\":{d}," ++
            "\"send_failures\":{d}," ++
            "\"poll_failures\":{d}," ++
            "\"negotiation_failures\":{d}," ++
            "\"reliable_timeouts\":{d}," ++
            "\"unreliable_timeouts\":{d}," ++
            "\"corruptions\":{d}," ++
            "\"unmatched_messages\":{d}," ++
            "\"native_dropped_unreliable\":{d}," ++
            "\"queue_high_water_bytes\":{d}," ++
            "\"buffered_high_water_bytes\":{d}," ++
            "\"rss_process_start_bytes\":{?d}," ++
            "\"rss_start_bytes\":{?d}," ++
            "\"rss_end_bytes\":{?d}," ++
            "\"rss_growth_bytes\":{?d}," ++
            "\"rss_peak_bytes\":{?d}," ++
            "\"rss_after_close_bytes\":{?d}" ++
            "}}\n",
        .{
            histogram.percentileUs(50),
            histogram.percentileUs(95),
            histogram.percentileUs(99),
            histogram.maxUs(),
            histogram.count,
            histogram.overflow,

            @as(f64, @floatFromInt(metrics.max_loop_gap_ns)) /
                std.time.ns_per_us,

            cpu_percent,

            metrics.reconnects,
            metrics.failures,
            metrics.send_failures,
            metrics.poll_failures,
            metrics.negotiation_failures,

            metrics.reliable_timeouts,
            metrics.unreliable_timeouts,

            metrics.corruptions,
            metrics.unmatched_messages,
            metrics.native_dropped_unreliable,

            metrics.queue_high_water_bytes,
            metrics.buffered_high_water_bytes,

            rss_process_start.current,
            rss_start.current,
            rss_end.current,
            rss_growth,
            rss_after_close.peak,
            rss_after_close.current,
        },
    );
}

const Memory = struct {
    current: ?u64 = null,
    peak: ?u64 = null,
};

fn residentBytes(io: std.Io) Memory {
    if (builtin.os.tag == .windows) {
        return windowsResidentBytes();
    }

    if (builtin.os.tag == .linux or
        builtin.os.tag == .macos)
    {
        const usage =
            std.posix.getrusage(
                std.posix.rusage.SELF,
            );

        const value: u64 =
            @intCast(usage.maxrss);

        var memory: Memory = .{
            .peak =
                if (builtin.os.tag == .macos)
                    value
                else
                    value * 1024,
        };

        if (builtin.os.tag == .linux) {
            var buffer: [8192]u8 = undefined;

            const status =
                std.Io.Dir.cwd().readFile(
                    io,
                    "/proc/self/status",
                    &buffer,
                ) catch
                    return memory;

            memory.current =
                parseResidentBytes(status);
        }

        return memory;
    }

    return .{};
}

fn parseResidentBytes(
    status: []const u8,
) ?u64 {
    var lines =
        std.mem.splitScalar(
            u8,
            status,
            '\n',
        );

    while (lines.next()) |line| {
        if (!std.mem.startsWith(
            u8,
            line,
            "VmRSS:",
        )) {
            continue;
        }

        var fields =
            std.mem.tokenizeAny(
                u8,
                line[6..],
                " \t",
            );

        const kib =
            std.fmt.parseInt(
                u64,
                fields.next() orelse
                    return null,
                10,
            ) catch
                return null;

        if (!std.mem.eql(
            u8,
            fields.next() orelse
                return null,
            "kB",
        )) {
            return null;
        }

        return std.math.mul(
            u64,
            kib,
            1024,
        ) catch
            null;
    }

    return null;
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

extern "kernel32" fn GetCurrentProcess()
    callconv(.winapi) *anyopaque;

extern "psapi" fn GetProcessMemoryInfo(
    *anyopaque,
    *ProcessMemoryCounters,
    u32,
) callconv(.winapi) i32;

fn windowsResidentBytes() Memory {
    if (builtin.os.tag != .windows) {
        return .{};
    }

    var counters: ProcessMemoryCounters =
        undefined;

    counters.cb =
        @sizeOf(ProcessMemoryCounters);

    if (GetProcessMemoryInfo(
        GetCurrentProcess(),
        &counters,
        counters.cb,
    ) == 0) {
        return .{};
    }

    return .{
        .current = counters.working_set_size,
        .peak = counters.peak_working_set_size,
    };
}

test "latency histogram records whole run" {
    var histogram =
        try LatencyHistogram.init(
            std.testing.allocator,
        );

    defer histogram.deinit(
        std.testing.allocator,
    );

    histogram.record(10_000);
    histogram.record(20_000);
    histogram.record(30_000);
    histogram.record(40_000);

    try std.testing.expectEqual(
        @as(u64, 4),
        histogram.count,
    );

    try std.testing.expect(
        histogram.percentileUs(50) >= 20,
    );

    try std.testing.expect(
        histogram.percentileUs(99) >= 40,
    );
}

test "benchmark RSS distinguishes current usage from peak" {
    try std.testing.expectEqual(
        @as(?u64, 4096),
        parseResidentBytes(
            "VmHWM: 99 kB\nVmRSS:\t4 kB\n",
        ),
    );

    for ([_][]const u8{
        "",
        "VmHWM: 99 kB\n",
        "VmRSS: x kB",
        "VmRSS: 4 MB",
        "VmRSS: 18446744073709551615 kB",
    }) |invalid| {
        try std.testing.expectEqual(
            @as(?u64, null),
            parseResidentBytes(invalid),
        );
    }
}
