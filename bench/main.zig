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
    std.debug.print("operation,bytes,iterations,ns_per_op,MiB_per_s,hot_path_allocations\n", .{});

    const codec = discovery.Codec.init();
    for ([_]usize{ 32, 64, 128, 256, 512, 1024, 1400, 8192 }) |size| {
        var start = std.Io.Clock.awake.now(io);
        for (0..default_iterations) |_| {
            const data = try codec.encode(.{ .response = payload[0..size] }, 7, scratch, output);
            std.mem.doNotOptimizeAway(data);
            checksum +%= data.len;
        }
        report(io, start, "discovery_encode", size, default_iterations);

        const wire = try codec.encode(.{ .response = payload[0..size] }, 7, scratch, output);
        start = std.Io.Clock.awake.now(io);
        for (0..default_iterations) |_| {
            const decoded = try codec.decode(wire, scratch);
            checksum +%= decoded.packet.response.len;
            std.mem.doNotOptimizeAway(scratch.ptr);
        }
        report(io, start, "discovery_decode", size, default_iterations);
    }

    for ([_]usize{ 32, 64, 128, 256, 512, 1024, 1400, 8192, 262143, 262144, payload_size }) |size| {
        const iterations: usize = if (size > 8192) 1000 else default_iterations;
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
        report(io, start, "frame_reassemble", size, iterations);
    }

    var entries: [256]Queue.Entry = undefined;
    var queue = try Queue.init(storage, &entries);
    const start = std.Io.Clock.awake.now(io);
    for (0..queue_iterations) |_| {
        try queue.push(0, payload[0..queue_payload_size]);
        checksum +%= (try queue.pop(frame)).?.data.len;
    }
    report(io, start, "queue_roundtrip", queue_payload_size, queue_iterations);
    std.mem.doNotOptimizeAway(checksum);
}

fn report(io: std.Io, start: std.Io.Timestamp, operation: []const u8, bytes: usize, count: usize) void {
    const elapsed: f64 = @floatFromInt(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    const nanoseconds_per_operation = elapsed / @as(f64, @floatFromInt(count));
    const mebibytes_per_second = @as(f64, @floatFromInt(bytes)) / nanoseconds_per_operation * 1e9 / (1024 * 1024);
    std.debug.print("{s},{d},{d},{d:.1},{d:.1},0\n", .{ operation, bytes, count, nanoseconds_per_operation, mebibytes_per_second });
}
