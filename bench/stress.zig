const std = @import("std");
const builtin = @import("builtin");
const nethernet = @import("nethernet");
const Connection = nethernet.Connection;
const Reliability = nethernet.Reliability;

const Config = struct {
    connections: usize = 2,
    duration_ms: u64 = 3_000,
    message_limit: u64 = 0,
    payload_size: usize = 512,
    rate: u64 = 0,
    burst: usize = 1,
    churn_messages: u64 = 0,
    reliability: enum { reliable, unreliable, mixed } = .mixed,
    profile: enum { fixed, bedrock, rollover } = .bedrock,
    timeout_ms: u32 = 20_000,
};

const Pair = struct {
    client: *Connection,
    server: *Connection,

    fn destroy(self: Pair) void {
        self.client.destroy();
        self.server.destroy();
    }
};

const Metrics = struct {
    messages: u64 = 0,
    bytes: u64 = 0,
    reconnects: u64 = 0,
    failures: u64 = 0,
    corruptions: u64 = 0,
    dropped_unreliable: u64 = 0,
    queue_high_water_bytes: usize = 0,
    latencies_ns: std.ArrayList(u64) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const config = try parseArgs(init.minimal.args, allocator);
    if (config.connections == 0 or config.payload_size < 16 or config.burst == 0)
        return error.InvalidConfiguration;

    var pairs = try allocator.alloc(Pair, config.connections);
    defer allocator.free(pairs);
    var connected: usize = 0;
    defer for (pairs[0..connected]) |pair| pair.destroy();

    const rss_process_start = residentBytes();
    const setup_started = std.Io.Clock.awake.now(io);
    while (connected < pairs.len) : (connected += 1)
        pairs[connected] = try connect(allocator, io, connected, config.timeout_ms);
    const setup_ns = setup_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    const rss_start = residentBytes();

    const maximum_payload = @max(config.payload_size, 8192);
    const payload = try allocator.alloc(u8, maximum_payload);
    defer allocator.free(payload);
    const sample_capacity = @min(@as(usize, 1_000_000), @max(@as(usize, 4096), config.connections * 4096));
    var metrics: Metrics = .{};
    try metrics.latencies_ns.ensureTotalCapacityPrecise(allocator, sample_capacity);
    defer metrics.latencies_ns.deinit(allocator);

    const wall_started = std.Io.Clock.awake.now(io);
    const cpu_started = std.Io.Clock.cpu_process.now(io);
    const deadline_ns = config.duration_ms * std.time.ns_per_ms;
    var sequence: u64 = 0;
    var stop = false;
    while (!stop) {
        for (pairs, 0..) |*pair, pair_index| {
            if ((config.duration_ms != 0 and wall_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds >= deadline_ns) or
                (config.message_limit != 0 and metrics.messages >= config.message_limit))
            {
                stop = true;
                break;
            }
            sequence +%= 1;
            const size = payloadSize(config, sequence);
            const reliability = reliabilityFor(config, sequence);
            writePayload(payload[0..size], sequence);
            const sent = std.Io.Clock.awake.now(io);
            for (0..config.burst) |_| {
                pair.client.send(payload[0..size], reliability) catch |err| {
                    metrics.failures += 1;
                    std.debug.print("transport failure on pair {d}: {s}\n", .{ pair_index, @errorName(err) });
                    return err;
                };
            }
            for (0..config.burst) |_| {
                const received = try receiveDeadline(pair.server, sent, config.timeout_ms);
                if (!validPayload(received.data, sequence, size)) metrics.corruptions += 1;
                try pair.server.send(received.data, received.reliability);
            }
            for (0..config.burst) |_| {
                const echoed = try receiveDeadline(pair.client, sent, config.timeout_ms);
                if (!validPayload(echoed.data, sequence, size)) metrics.corruptions += 1;
                metrics.messages += 1;
                metrics.bytes += @as(u64, @intCast(size)) * 2;
                if (metrics.latencies_ns.items.len < sample_capacity)
                    metrics.latencies_ns.appendAssumeCapacity(@intCast(sent.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
            }
            const client_stats = pair.client.callbackStats();
            const server_stats = pair.server.callbackStats();
            metrics.dropped_unreliable += client_stats.dropped_unreliable_packets + server_stats.dropped_unreliable_packets;
            metrics.queue_high_water_bytes = @max(metrics.queue_high_water_bytes, @max(client_stats.queue_high_water_bytes, server_stats.queue_high_water_bytes));

            if (config.churn_messages != 0 and metrics.messages % config.churn_messages == 0) {
                metrics.dropped_unreliable += client_stats.dropped_unreliable_packets + server_stats.dropped_unreliable_packets;
                pair.destroy();
                pair.* = try connect(allocator, io, pair_index, config.timeout_ms);
                metrics.reconnects += 1;
            }
            if (config.rate != 0) {
                const delay_ns = std.time.ns_per_s / config.rate;
                std.Io.sleep(io, .fromNanoseconds(delay_ns), .awake) catch {};
            }
        }
    }

    for (pairs) |pair| {
        const client_stats = pair.client.callbackStats();
        const server_stats = pair.server.callbackStats();
        metrics.dropped_unreliable += client_stats.dropped_unreliable_packets + server_stats.dropped_unreliable_packets;
        metrics.queue_high_water_bytes = @max(metrics.queue_high_water_bytes, @max(client_stats.queue_high_water_bytes, server_stats.queue_high_water_bytes));
    }
    const elapsed_ns = wall_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    const cpu_ns = cpu_started.durationTo(std.Io.Clock.cpu_process.now(io)).nanoseconds;
    const rss_end = residentBytes();
    std.mem.sort(u64, metrics.latencies_ns.items, {}, std.sort.asc(u64));
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const cpu_percent = @as(f64, @floatFromInt(cpu_ns)) / @as(f64, @floatFromInt(elapsed_ns)) * 100;
    std.debug.print(
        "{{\"os\":\"{s}\",\"arch\":\"{s}\",\"zig\":\"{s}\",\"mode\":\"{s}\",\"connections\":{d},\"duration_ms\":{d},\"message_limit\":{d},\"payload_size\":{d},\"rate\":{d},\"burst\":{d},\"profile\":\"{s}\",\"reliability\":\"{s}\",\"setup_ms\":{d:.1},\"messages\":{d},\"bytes\":{d},\"messages_per_second\":{d:.1},\"mib_per_second\":{d:.2},\"latency_p50_us\":{d:.1},\"latency_p95_us\":{d:.1},\"latency_p99_us\":{d:.1},\"cpu_percent\":{d:.1},\"rss_process_start_bytes\":{d},\"rss_start_bytes\":{d},\"rss_end_bytes\":{d},\"rss_growth_bytes\":{d},\"reconnects\":{d},\"failures\":{d},\"corruptions\":{d},\"dropped_unreliable\":{d},\"queue_high_water_bytes\":{d}}}\n",
        .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), builtin.zig_version_string, @tagName(builtin.mode), config.connections, config.duration_ms, config.message_limit, config.payload_size, config.rate, config.burst, @tagName(config.profile), @tagName(config.reliability), @as(f64, @floatFromInt(setup_ns)) / std.time.ns_per_ms, metrics.messages, metrics.bytes, @as(f64, @floatFromInt(metrics.messages)) / seconds, @as(f64, @floatFromInt(metrics.bytes)) / seconds / (1024 * 1024), percentile(metrics.latencies_ns.items, 50), percentile(metrics.latencies_ns.items, 95), percentile(metrics.latencies_ns.items, 99), cpu_percent, rss_process_start, rss_start, rss_end, @as(i128, @intCast(rss_end)) - @as(i128, @intCast(rss_start)), metrics.reconnects, metrics.failures, metrics.corruptions, metrics.dropped_unreliable, metrics.queue_high_water_bytes },
    );
    if (metrics.failures != 0 or metrics.corruptions != 0) return error.StressFailure;
}

fn parseArgs(args: std.process.Args, allocator: std.mem.Allocator) !Config {
    var result: Config = .{};
    var duration_set = false;
    var messages_set = false;
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--connections")) {
            result.connections = try parse(usize, it.next());
        } else if (std.mem.eql(u8, arg, "--duration-ms")) {
            result.duration_ms = try parse(u64, it.next());
            duration_set = true;
        } else if (std.mem.eql(u8, arg, "--messages")) {
            result.message_limit = try parse(u64, it.next());
            messages_set = true;
        } else if (std.mem.eql(u8, arg, "--payload-size")) {
            result.payload_size = try parse(usize, it.next());
        } else if (std.mem.eql(u8, arg, "--rate")) {
            result.rate = try parse(u64, it.next());
        } else if (std.mem.eql(u8, arg, "--burst")) {
            result.burst = try parse(usize, it.next());
        } else if (std.mem.eql(u8, arg, "--churn-messages")) {
            result.churn_messages = try parse(u64, it.next());
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            result.timeout_ms = try parse(u32, it.next());
        } else if (std.mem.eql(u8, arg, "--reliability")) {
            result.reliability = std.meta.stringToEnum(@TypeOf(result.reliability), it.next() orelse return error.MissingArgument) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            result.profile = std.meta.stringToEnum(@TypeOf(result.profile), it.next() orelse return error.MissingArgument) orelse return error.InvalidArgument;
        } else return error.InvalidArgument;
    }
    if (result.profile == .rollover) {
        result.connections = 1;
        result.reliability = .reliable;
        result.payload_size = 16;
        result.burst = @max(result.burst, 256);
        if (!duration_set and !messages_set) {
            result.duration_ms = 0;
            result.message_limit = @as(u64, 1) << 32;
        }
    }
    return result;
}
fn parse(comptime T: type, value: ?[:0]const u8) !T {
    return std.fmt.parseInt(T, value orelse return error.MissingArgument, 10);
}

fn connect(allocator: std.mem.Allocator, io: std.Io, index: usize, timeout_ms: u32) !Pair {
    const options: nethernet.ConnectionOptions = .{ .native = .{ .disable_trickle = true }, .allow_anonymous = true, .negotiation_timeout_ms = timeout_ms, .connection_timeout_ms = timeout_ms };
    const client = try Connection.create(allocator, io, .client, @intCast(index + 1), "server", options);
    errdefer client.destroy();
    const server = try Connection.create(allocator, io, .server, @intCast(index + 1), "client", options);
    errdefer server.destroy();
    try client.start();
    const started = std.Io.Clock.awake.now(io);
    while (!client.ready() or !server.ready()) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= timeout_ms) return error.Timeout;
        for ([_]*Connection{ client, server }, [_]*Connection{ server, client }, [_][]const u8{ "client", "server" }) |source, dest, name| {
            if (try source.pollNegotiation()) |event| switch (event) {
                .signal => |signal| {
                    var routed = signal;
                    routed.network_id = name;
                    try dest.applySignal(routed);
                },
                .message => return error.UnexpectedMessage,
            };
        }
        if (!client.ready() or !server.ready()) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return .{ .client = client, .server = server };
}

fn receiveDeadline(connection: *Connection, started: std.Io.Timestamp, timeout_ms: u32) !nethernet.Message {
    while (true) {
        connection.prepareWait();
        if (try connection.poll()) |event| switch (event) {
            .message => |message| return message,
            .signal => {},
        };
        if (started.durationTo(std.Io.Clock.awake.now(connection.io)).toMilliseconds() >= timeout_ms) return error.Timeout;
        if (!connection.peer.hasPending(false)) try std.Io.sleep(connection.io, .fromMilliseconds(1), .awake);
    }
}

fn payloadSize(config: Config, sequence: u64) usize {
    if (config.profile != .bedrock) return config.payload_size;
    const sizes = [_]usize{ 32, 64, 96, 128, 256, 512, 1400, 8192 };
    return @min(config.payload_size, sizes[@intCast(sequence % sizes.len)]);
}

fn reliabilityFor(config: Config, sequence: u64) Reliability {
    return switch (config.reliability) {
        .reliable => .reliable,
        .unreliable => .unreliable,
        .mixed => if (sequence % 10 == 0) .unreliable else .reliable,
    };
}

fn writePayload(data: []u8, sequence: u64) void {
    std.mem.writeInt(u64, data[0..8], sequence, .little);
    std.mem.writeInt(u64, data[8..16], ~sequence, .little);
    for (data[16..], 16..) |*byte, i| byte.* = @truncate(sequence +% i);
}

fn validPayload(data: []const u8, sequence: u64, size: usize) bool {
    if (data.len != size or std.mem.readInt(u64, data[0..8], .little) != sequence or std.mem.readInt(u64, data[8..16], .little) != ~sequence) return false;
    for (data[16..], 16..) |byte, i| if (byte != @as(u8, @truncate(sequence +% i))) return false;
    return true;
}

fn percentile(values: []const u64, percent: usize) f64 {
    if (values.len == 0) return 0;
    const index = @min(values.len - 1, (values.len * percent + 99) / 100 - 1);
    return @as(f64, @floatFromInt(values[index])) / std.time.ns_per_us;
}

fn residentBytes() u64 {
    if (builtin.os.tag == .windows) return windowsResidentBytes();
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const usage = std.posix.getrusage(std.posix.rusage.SELF);
        const value: u64 = @intCast(usage.maxrss);
        return if (builtin.os.tag == .macos) value else value * 1024;
    }
    return 0;
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

fn windowsResidentBytes() u64 {
    if (builtin.os.tag != .windows) return 0;
    var counters: ProcessMemoryCounters = undefined;
    counters.cb = @sizeOf(ProcessMemoryCounters);
    if (GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0) return 0;
    return @intCast(counters.working_set_size);
}
