const std = @import("std");

/// A single owner uses this ring with storage provided by the caller.
pub const Queue = struct {
    pub const Entry = struct {
        tag: u8,
        len: usize,
    };

    bytes: []u8,
    entries: []Entry,

    read_byte: usize = 0,
    used_bytes: usize = 0,
    head: usize = 0,
    count: usize = 0,

    pub fn init(bytes: []u8, entries: []Entry) !Queue {
        if (bytes.len == 0 or entries.len == 0) {
            return error.InvalidConfiguration;
        }

        return .{
            .bytes = bytes,
            .entries = entries,
        };
    }

    pub fn push(self: *Queue, tag: u8, data: []const u8) !void {
        if (self.count == self.entries.len or
            data.len > self.bytes.len - self.used_bytes)
        {
            return error.QueueFull;
        }

        const start = (self.read_byte + self.used_bytes) % self.bytes.len;
        const first_len = @min(data.len, self.bytes.len - start);

        @memcpy(self.bytes[start..][0..first_len], data[0..first_len]);
        @memcpy(self.bytes[0 .. data.len - first_len], data[first_len..]);

        const entry_index = (self.head + self.count) % self.entries.len;
        self.entries[entry_index] = .{
            .tag = tag,
            .len = data.len,
        };

        self.used_bytes += data.len;
        self.count += 1;
    }

    pub fn pop(
        self: *Queue,
        output: []u8,
    ) !?struct { tag: u8, data: []const u8 } {
        if (self.count == 0) return null;

        const entry = self.entries[self.head];
        if (output.len < entry.len) return error.NoSpaceLeft;

        const first_len = @min(
            entry.len,
            self.bytes.len - self.read_byte,
        );

        @memcpy(
            output[0..first_len],
            self.bytes[self.read_byte..][0..first_len],
        );
        @memcpy(
            output[first_len..entry.len],
            self.bytes[0 .. entry.len - first_len],
        );

        self.read_byte = (self.read_byte + entry.len) % self.bytes.len;
        self.used_bytes -= entry.len;
        self.head = (self.head + 1) % self.entries.len;
        self.count -= 1;

        return .{
            .tag = entry.tag,
            .data = output[0..entry.len],
        };
    }
};

test "byte and entry limits, wraparound, failed reads preserve messages" {
    var bytes: [7]u8 = undefined;
    var entries: [2]Queue.Entry = undefined;
    var output: [7]u8 = undefined;

    var queue = try Queue.init(&bytes, &entries);

    try queue.push(1, "abcd");
    try queue.push(2, "efg");

    try std.testing.expectError(error.QueueFull, queue.push(3, "h"));
    try std.testing.expectError(error.NoSpaceLeft, queue.pop(output[0..1]));

    try std.testing.expectEqualStrings(
        "abcd",
        (try queue.pop(&output)).?.data,
    );

    try queue.push(3, "hijk");

    try std.testing.expectEqualStrings(
        "efg",
        (try queue.pop(&output)).?.data,
    );

    const last = (try queue.pop(&output)).?;

    try std.testing.expectEqualStrings("hijk", last.data);
    try std.testing.expectEqual(@as(u8, 3), last.tag);
    try std.testing.expectEqual(@as(usize, 0), queue.used_bytes);
    try std.testing.expect((try queue.pop(&output)) == null);
}
