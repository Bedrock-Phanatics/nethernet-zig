const std = @import("std");
const build_options = @import("build_options");
const discovery = @import("../src/discovery_codec.zig");
const framing = @import("../src/framing.zig");
const Signal = @import("../src/signal.zig").Signal;
const ServerData = @import("../src/server_data.zig").ServerData;

pub fn exercise(input: []u8) void {
    var scratch: [4096]u8 = undefined;
    const codec = discovery.Codec.init();
    _ = codec.decode(input, &scratch) catch {};
    _ = Signal.parse(input) catch {};
    _ = ServerData.decode(input) catch {};
    var decoder = framing.Reassembler.init(&scratch, .reliable);
    var offset: usize = 0;
    while (offset < input.len) {
        const len: usize = @min(@as(usize, input[offset]) + 1, input.len - offset);
        _ = decoder.push(input[offset..][0..len]) catch {};
        offset += len;
    }
    _ = discovery.decodePayload(input) catch {};
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4096]u8 = undefined;
    const len = smith.sliceWithHash(&bytes, 0x74129);
    exercise(bytes[0..len]);
}

test "fuzz protocol parsers and fragment state transitions" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{ "", "CONNECTREQUEST 7 v=0\r\n", &.{ 1, 2, 0, 3 } } });
}

test "deterministic malformed input campaign" {
    var random = std.Random.DefaultPrng.init(0xBEdBEd);
    var bytes: [4096]u8 = undefined;
    for (0..build_options.fuzz_iterations) |i| {
        const len = i % (bytes.len + 1);
        random.random().bytes(bytes[0..len]);
        exercise(bytes[0..len]);
    }
}
