const std = @import("std");
const framing = @import("framing");

const maximum_signal_size = 1024 * 1024;
const connection_struct_overhead = 0;

pub fn main(_: std.process.Init) !void {
    const packet_buffer = framing.maximum_segment_payload + 1;
    const queue_entries = 512 * @sizeOf(@import("queue").Queue.Entry);
    const negotiating = 2 * (framing.maximum_segment_payload + 1) + queue_entries + 2 * packet_buffer + maximum_signal_size + 1;
    const established = negotiating - (maximum_signal_size + 1);

    std.debug.print("connections,negotiating_bytes,established_bytes,negotiating_MiB,established_MiB\n", .{});
    for ([_]usize{ 1, 100, 500, 1000 }) |count| {
        std.debug.print("{d},{d},{d},{d:.2},{d:.2}\n", .{
            count,
            count * negotiating,
            count * established,
            @as(f64, @floatFromInt(count * negotiating)) / (1024 * 1024),
            @as(f64, @floatFromInt(count * established)) / (1024 * 1024),
        });
    }
}