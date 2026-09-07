const std = @import("std");
const discovery = @import("discovery_codec.zig");
const framing = @import("framing.zig");
const Queue = @import("queue.zig").Queue;

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const codec = discovery.Codec.init();
    const payload = try a.alloc(u8, 524288);
    defer a.free(payload);
    @memset(payload, 42);
    const scratch = try a.alloc(u8, 65568);
    defer a.free(scratch);
    const output = try a.alloc(u8, 65568);
    defer a.free(output);
    const frame = try a.alloc(u8, framing.maximum_segment_payload + 1);
    defer a.free(frame);
    const storage = try a.alloc(u8, payload.len);
    defer a.free(storage);
    const iterations = 10000;
    var checksum: usize = 0;
    std.debug.print("operation,bytes,iterations,ns_per_op,MiB_per_s,hot_path_allocations\n", .{});
    for ([_]usize{ 32, 64, 128, 256, 512, 1024, 1400, 8192 }) |size| {
        var start = std.Io.Clock.awake.now(io);
        for (0..iterations) |_| {
            const data = try codec.encode(.{ .response = payload[0..size] }, 7, scratch, output);
            std.mem.doNotOptimizeAway(data);
            checksum +%= data.len;
        }
        report(io, start, "discovery_encode", size, iterations);
        const wire = try codec.encode(.{ .response = payload[0..size] }, 7, scratch, output);
        start = std.Io.Clock.awake.now(io);
        for (0..iterations) |_| {
            const decoded = try codec.decode(wire, scratch);
            checksum +%= decoded.packet.response.len;
            std.mem.doNotOptimizeAway(scratch.ptr);
        }
        report(io, start, "discovery_decode", size, iterations);
    }
    for ([_]usize{ 32, 64, 128, 256, 512, 1024, 1400, 8192, 262143, 262144, 524288 }) |size| {
        const count: usize = if (size > 8192) 1000 else iterations;
        const start = std.Io.Clock.awake.now(io);
        for (0..count) |_| {
            var encoder = try framing.Encoder.init(payload[0..size], .reliable, payload.len);
            var decoder = framing.Reassembler.init(storage, .reliable);
            while (try encoder.next(frame)) |part| if (try decoder.push(part)) |message| {
                checksum +%= message.len;
                std.mem.doNotOptimizeAway(message.ptr);
            };
        }
        report(io, start, "frame_reassemble", size, count);
    }
    var entries: [256]Queue.Entry = undefined;
    var queue = try Queue.init(storage, &entries);
    const start = std.Io.Clock.awake.now(io);
    for (0..100000) |_| {
        try queue.push(0, payload[0..128]);
        checksum +%= (try queue.pop(frame)).?.data.len;
    }
    report(io, start, "queue_roundtrip", 128, 100000);
    std.mem.doNotOptimizeAway(checksum);
}
fn report(io: std.Io, start: std.Io.Timestamp, operation: []const u8, bytes: usize, count: usize) void {
    const elapsed: f64 = @floatFromInt(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    const ns = elapsed / @as(f64, @floatFromInt(count));
    const throughput = @as(f64, @floatFromInt(bytes)) / ns * 1e9 / (1024 * 1024);
    std.debug.print("{s},{d},{d},{d:.1},{d:.1},0\n", .{ operation, bytes, count, ns, throughput });
}
