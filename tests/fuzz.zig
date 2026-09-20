const std = @import("std");
const build_options = @import("build_options");
const core = @import("nethernet_core");
const discovery = core.discovery_codec;
const framing = core.framing;
const Signal = core.Signal;
const ServerData = core.ServerData;
const identity = core.identity;
const sdp_identity = core.sdp_identity;
const identity_file = core.identity_file;

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

    const allocator = std.testing.allocator;
    if (identity.decode64(allocator, input)) |decoded| {
        allocator.free(decoded);
    } else |_| {}

    if (identity.parse(allocator, input)) |parsed| {
        parsed.deinit();
    } else |_| {}

    if (sdp_identity.fingerprintPayload(allocator, input)) |payload| {
        allocator.free(payload);
    } else |_| {}

    _ = identity_file.decode(input) catch {};
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
