const std = @import("std");

pub const Signal = struct {
    kind: []const u8,
    connection_id: u64,
    data: []const u8 = "",
    network_id: []const u8 = "",

    pub const offer = "CONNECTREQUEST";
    pub const answer = "CONNECTRESPONSE";
    pub const candidate = "CANDIDATEADD";
    pub const failure = "CONNECTERROR";

    pub fn known(kind: []const u8) bool {
        for ([_][]const u8{ offer, answer, candidate, failure }) |value| {
            if (std.mem.eql(u8, kind, value)) return true;
        }
        return false;
    }

    pub fn parse(text: []const u8) error{MalformedSignal}!Signal {
        const first = std.mem.indexOfScalar(u8, text, ' ') orelse
            return error.MalformedSignal;
        if (first == 0) return error.MalformedSignal;
        const second = std.mem.indexOfScalarPos(u8, text, first + 1, ' ') orelse
            return error.MalformedSignal;

        const kind = text[0..first];
        if (!known(kind)) return error.MalformedSignal;

        const connection_id = std.fmt.parseInt(
            u64,
            decimalPrefix(text[first + 1 .. second], false),
            10,
        ) catch return error.MalformedSignal;

        const data = text[second + 1 ..];
        if (std.mem.eql(u8, kind, failure)) _ = try parseErrorCode(data);

        return .{
            .kind = kind,
            .connection_id = connection_id,
            .data = data,
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

pub fn parseErrorCode(data: []const u8) error{MalformedSignal}!i32 {
    return std.fmt.parseInt(i32, decimalPrefix(data, true), 10) catch
        error.MalformedSignal;
}

fn decimalPrefix(text: []const u8, signed: bool) []const u8 {
    var end: usize = 0;
    if (signed and text.len != 0 and text[0] == '-') end += 1;
    while (end < text.len and text[end] >= '0' and text[end] <= '9') end += 1;
    return text[0..end];
}

test "signal preserves whitespace and UInt64 boundaries" {
    const source =
        "CONNECTREQUEST 18446744073709551615 " ++
        "v=0\r\na=candidate: hello world";

    const signal = try Signal.parse(source);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(source, try signal.encode(&buffer));

    const malformed = [_][]const u8{
        "",
        "CONNECTREQUEST 1",
        "CONNECTREQUEST -1 x",
        "CONNECTREQUEST +1 x",
        "CONNECTREQUEST 18446744073709551616 x",
        "CONNECTREQUEST  x",
        " 1 payload",
        "A 1 x",
        "connectrequest 1 x",
        "CONNECTREQUESTX 1 x",
        "CONNECTERROR 1 x",
        "CONNECTERROR 1 ",
        "CONNECTERROR 1 2147483648",
        "CONNECTERROR 1 -2147483649",
        "CONNECTERROR 1 +1",
    };

    for (malformed) |text| {
        try std.testing.expectError(
            error.MalformedSignal,
            Signal.parse(text),
        );
    }
}

test "numeric fields accept a decimal prefix as vanilla does" {
    const Case = struct {
        text: []const u8,
        connection_id: u64,
        data: []const u8,
    };

    for ([_]Case{
        .{ .text = "CONNECTREQUEST 42junk offer", .connection_id = 42, .data = "offer" },
        .{ .text = "CONNECTRESPONSE 42junk answer", .connection_id = 42, .data = "answer" },
        .{ .text = "CANDIDATEADD 42junk candidate", .connection_id = 42, .data = "candidate" },
        .{ .text = "CONNECTERROR 42junk -12suffix", .connection_id = 42, .data = "-12suffix" },
        .{ .text = "CONNECTERROR 0x10 0x10", .connection_id = 0, .data = "0x10" },
    }) |case| {
        const signal = try Signal.parse(case.text);
        try std.testing.expectEqual(case.connection_id, signal.connection_id);
        try std.testing.expectEqualStrings(case.data, signal.data);
    }

    try std.testing.expectEqual(@as(i32, -12), try parseErrorCode("-12suffix"));
    try std.testing.expectEqual(@as(i32, 0), try parseErrorCode("0x10"));
    try std.testing.expectEqual(
        @as(i32, std.math.minInt(i32)),
        try parseErrorCode("-2147483648"),
    );
    try std.testing.expectEqual(
        @as(i32, std.math.maxInt(i32)),
        try parseErrorCode("2147483647"),
    );
}
