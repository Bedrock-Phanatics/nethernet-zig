const std = @import("std");

/// Parsed strings remain tied to the source buffer.
pub const Signal = struct {
    kind: []const u8,
    connection_id: u64,
    data: []const u8 = "",
    network_id: []const u8 = "",

    pub const offer = "CONNECTREQUEST";
    pub const answer = "CONNECTRESPONSE";
    pub const candidate = "CANDIDATEADD";
    pub const failure = "CONNECTERROR";

    pub fn parse(text: []const u8) error{MalformedSignal}!Signal {
        const first = std.mem.indexOfScalar(u8, text, ' ') orelse
            return error.MalformedSignal;
        if (first == 0) return error.MalformedSignal;
        const second = std.mem.indexOfScalarPos(u8, text, first + 1, ' ') orelse
            return error.MalformedSignal;

        const connection_id = text[first + 1 .. second];
        if (connection_id.len == 0) return error.MalformedSignal;

        for (connection_id) |digit| {
            if (digit < '0' or digit > '9') return error.MalformedSignal;
        }

        return .{
            .kind = text[0..first],
            .connection_id = std.fmt.parseInt(u64, connection_id, 10) catch
                return error.MalformedSignal,
            .data = text[second + 1 ..],
        };
    }

    pub fn encode(
        self: Signal,
        output: []u8,
    ) error{NoSpaceLeft}![]const u8 {
        return std.fmt.bufPrint(
            output,
            "{s} {d} {s}",
            .{ self.kind, self.connection_id, self.data },
        );
    }
};

test "signal preserves whitespace and UInt64 boundaries" {
    const source =
        "CONNECTREQUEST 18446744073709551615 " ++
        "v=0\r\na=candidate: hello world";

    const signal = try Signal.parse(source);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(source, try signal.encode(&buffer));

    const malformed = [_][]const u8{
        "",
        "A 1",
        "A -1 x",
        "A +1 x",
        "A 18446744073709551616 x",
        "A  x",
        "A 1_0 x",
        " 1 payload",
    };

    for (malformed) |text| {
        try std.testing.expectError(
            error.MalformedSignal,
            Signal.parse(text),
        );
    }
}
