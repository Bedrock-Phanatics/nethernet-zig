const std = @import("std");
const discovery = @import("discovery_codec");
const framing = @import("framing");
const Queue = @import("queue").Queue;

const payload_size = 512 * 1024;
const codec_buffer_size = discovery.maximum_datagram;
const default_iterations = 10_000;
const queue_iterations = 100_000;
const queue_payload_size = 128;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const payload = try allocator.alloc(u8, payload_size);
    defer allocator.free(payload);

    @memset(payload, 42);

    const scratch = try allocator.alloc(u8, codec_buffer_size);
    defer allocator.free(scratch);

    const output = try allocator.alloc(u8, codec_buffer_size);
    defer allocator.free(output);

    const frame = try allocator.alloc(u8, framing.maximum_segment_payload + 1);
    defer allocator.free(frame);

    const storage = try allocator.alloc(u8, payload.len);
    defer allocator.free(storage);

    var checksum: usize = 0;
    std.debug.print("operation,bytes,iterations,ns_per_op,MiB_per_s,receive_bytes_copied_per_op,hot_path_allocations,dropped_unreliable,peer_failures\n", .{});

    const codec = discovery.Codec.init();
    for ([_]usize{ 32, 64, 128, 256, 512, 1024, 1400, 8192 }) |size| {
        var start = std.Io.Clock.awake.now(io);
        for (0..default_iterations) |_| {
            const data = try codec.encode(.{ .response = payload[0..size] }, 7, scratch, output);
            std.mem.doNotOptimizeAway(data);
            checksum +%= data.len;
        }
        report(io, start, "discovery_encode", size, default_iterations, 0);

        const wire = try codec.encode(.{ .response = payload[0..size] }, 7, scratch, output);
        const preflight = try codec.decode(wire, scratch);
        if (preflight.sender_id != 7 or
            !std.mem.eql(u8, preflight.packet.response, payload[0..size]))
        {
            return error.BenchmarkPreflightFailed;
        }
        start = std.Io.Clock.awake.now(io);
        for (0..default_iterations) |_| {
            const decoded = try codec.decode(wire, scratch);
            checksum +%= decoded.packet.response.len;
            std.mem.doNotOptimizeAway(scratch.ptr);
        }
        report(io, start, "discovery_decode", size, default_iterations, 0);
    }

    for ([_]usize{ 32, 64, 128, 256, 512, 1024, 1400, 8192, 262143, 262144, payload_size }) |size| {
        const iterations: usize = if (size > 8192) 1000 else default_iterations;
        try validateFraming(payload[0..size], frame, storage);
        const start = std.Io.Clock.awake.now(io);
        for (0..iterations) |_| {
            var encoder = try framing.Encoder.init(payload[0..size], .reliable, payload.len);
            var decoder = framing.Reassembler.init(storage, .reliable);
            while (try encoder.next(frame)) |part| {
                if (try decoder.push(part)) |message| {
                    checksum +%= message.len;
                    std.mem.doNotOptimizeAway(message.ptr);
                }
            }
        }
        report(io, start, "frame_reassemble", size, iterations, if (size <= framing.maximum_segment_payload) 0 else size);
    }

    // Receive-only measurements use preframed input so encoder copies are not timed.
    for ([_]usize{ 32, 64, 128, 256, 512, 1024, 1400, 8192 }) |size| {
        frame[0] = 0;
        @memcpy(frame[1..][0..size], payload[0..size]);
        const start = std.Io.Clock.awake.now(io);
        for (0..default_iterations) |_| {
            const message = (try framing.singleFragmentPayload(frame[0 .. size + 1], .reliable)).?;
            checksum +%= message.len;
            std.mem.doNotOptimizeAway(message.ptr);
        }
        report(io, start, "receive_single_fragment", size, default_iterations, 0);
    }

    const wire = try allocator.alloc(u8, payload_size + 3);
    defer allocator.free(wire);
    for ([_]usize{ framing.maximum_segment_payload + 1, payload_size }) |size| {
        var encoder = try framing.Encoder.init(payload[0..size], .reliable, payload.len);
        var offsets: [3]usize = undefined;
        var lengths: [3]usize = undefined;
        var count: usize = 0;
        var wire_used: usize = 0;
        while (try encoder.next(frame)) |part| {
            offsets[count] = wire_used;
            lengths[count] = part.len;
            @memcpy(wire[wire_used..][0..part.len], part);
            wire_used += part.len;
            count += 1;
        }

        const iterations: usize = 1000;
        const start = std.Io.Clock.awake.now(io);
        for (0..iterations) |_| {
            var decoder = framing.Reassembler.init(storage, .reliable);
            for (offsets[0..count], lengths[0..count]) |offset, length| {
                if (try decoder.push(wire[offset..][0..length])) |message| {
                    checksum +%= message.len;
                    std.mem.doNotOptimizeAway(message.ptr);
                }
            }
        }
        report(io, start, "receive_fragmented", size, iterations, size);
    }
    var entries: [256]Queue.Entry = undefined;
    var queue = try Queue.init(storage, &entries);
    try queue.push(0, payload[0..queue_payload_size]);
    const queued = (try queue.pop(frame)).?;
    if (queued.tag != 0 or !std.mem.eql(u8, queued.data, payload[0..queue_payload_size]))
        return error.BenchmarkPreflightFailed;
    const start = std.Io.Clock.awake.now(io);
    for (0..queue_iterations) |_| {
        try queue.push(0, payload[0..queue_payload_size]);
        checksum +%= (try queue.pop(frame)).?.data.len;
    }
    report(io, start, "queue_roundtrip", queue_payload_size, queue_iterations, queue_payload_size);

    try pressureBenchmark(io, false);
    try pressureBenchmark(io, true);
    std.mem.doNotOptimizeAway(checksum);
}

fn validateFraming(payload: []const u8, frame: []u8, storage: []u8) !void {
    var encoder = try framing.Encoder.init(payload, .reliable, storage.len);
    var decoder = framing.Reassembler.init(storage, .reliable);
    var result: ?[]const u8 = null;
    while (try encoder.next(frame)) |part| result = try decoder.push(part);
    if (result == null or !std.mem.eql(u8, result.?, payload))
        return error.BenchmarkPreflightFailed;
}

fn report(io: std.Io, start: std.Io.Timestamp, operation: []const u8, bytes: usize, count: usize, copied: usize) void {
    const elapsed: f64 = @floatFromInt(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    const nanoseconds_per_operation = elapsed / @as(f64, @floatFromInt(count));
    const mebibytes_per_second = @as(f64, @floatFromInt(bytes)) / nanoseconds_per_operation * 1e9 / (1024 * 1024);
    std.debug.print("{s},{d},{d},{d:.1},{d:.1},{d},0,0,0\n", .{ operation, bytes, count, nanoseconds_per_operation, mebibytes_per_second, copied });
}

fn pressureBenchmark(io: std.Io, drop_unreliable: bool) !void {
    const iterations = 10_000;
    const payload = [_]u8{0} ++ [_]u8{42} ** 511;
    var bytes: [4096]u8 = undefined;
    var entries: [16]Queue.Entry = undefined;
    var output: [512]u8 = undefined;
    var dropped: usize = 0;
    var failures: usize = 0;
    var checksum: usize = 0;

    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        var queue = try Queue.init(&bytes, &entries);
        for (0..16) |_| {
            if (drop_unreliable) {
                queue.pushWithReserve(4, &payload, 1024, 2) catch {
                    dropped += 1;
                };
            } else {
                queue.push(4, &payload) catch {
                    failures += 1;
                    break;
                };
            }
        }
        if (drop_unreliable) {
            queue.push(3, &payload) catch {
                failures += 1;
            };
        }
        while (try queue.pop(&output)) |event| {
            checksum +%= event.data[1];
            std.mem.doNotOptimizeAway(event.data.ptr);
        }
    }
    std.mem.doNotOptimizeAway(checksum);

    const elapsed: f64 = @floatFromInt(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    const ns = elapsed / iterations;
    const mib_s = 512.0 / ns * 1e9 / (1024 * 1024);
    std.debug.print("queue_pressure_{s},512,{d},{d:.1},{d:.1},512,0,{d},{d}\n", .{
        if (drop_unreliable) "drop_unreliable" else "fail_closed",
        iterations,
        ns,
        mib_s,
        dropped,
        failures,
    });
}
