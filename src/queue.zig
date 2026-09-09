const std = @import("std");

/// A single owner uses this ring with storage provided by the caller.
pub const Queue = struct {
    pub const Entry = struct {
        tag: u8,
        len: usize,
    };

    pub const Popped = struct {
        tag: u8,
        data: []const u8,
    };

    bytes: []u8,
    entries: []Entry,

    read_byte: usize = 0,
    used_bytes: usize = 0,
    head: usize = 0,
    count: usize = 0,
    high_water_bytes: usize = 0,
    high_water_entries: usize = 0,

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
        return self.pushWithReserve(tag, data, 0, 0);
    }

    pub fn pushWithReserve(
        self: *Queue,
        tag: u8,
        data: []const u8,
        reserve_bytes: usize,
        reserve_entries: usize,
    ) !void {
        if (reserve_bytes > self.bytes.len or reserve_entries > self.entries.len) {
            return error.InvalidConfiguration;
        }
        const byte_limit = self.bytes.len - reserve_bytes;
        const entry_limit = self.entries.len - reserve_entries;
        if (self.count >= entry_limit or
            self.used_bytes > byte_limit or
            data.len > byte_limit - self.used_bytes)
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
        self.high_water_bytes = @max(self.high_water_bytes, self.used_bytes);
        self.high_water_entries = @max(self.high_water_entries, self.count);
    }

    pub fn pop(
        self: *Queue,
        output: []u8,
    ) !?Popped {
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

    pub fn hasTagBelow(self: *const Queue, limit: u8) bool {
        for (0..self.count) |offset| {
            const index = (self.head + offset) % self.entries.len;
            if (self.entries[index].tag < limit) return true;
        }
        return false;
    }

    /// Removes the first matching entry while preserving all other entry order.
    pub fn popFirstTagBelow(
        self: *Queue,
        limit: u8,
        output: []u8,
    ) !?Popped {
        var byte_offset: usize = 0;
        var entry_offset: usize = 0;
        while (entry_offset < self.count) : (entry_offset += 1) {
            const index = (self.head + entry_offset) % self.entries.len;
            const entry = self.entries[index];
            if (entry.tag < limit) {
                if (output.len < entry.len) return error.NoSpaceLeft;

                for (0..entry.len) |i| {
                    output[i] = self.bytes[(self.read_byte + byte_offset + i) % self.bytes.len];
                }

                const trailing = self.used_bytes - byte_offset - entry.len;
                for (0..trailing) |i| {
                    const destination = (self.read_byte + byte_offset + i) % self.bytes.len;
                    const source = (self.read_byte + byte_offset + entry.len + i) % self.bytes.len;
                    self.bytes[destination] = self.bytes[source];
                }

                var shift = entry_offset;
                while (shift + 1 < self.count) : (shift += 1) {
                    const destination = (self.head + shift) % self.entries.len;
                    const source = (self.head + shift + 1) % self.entries.len;
                    self.entries[destination] = self.entries[source];
                }

                self.used_bytes -= entry.len;
                self.count -= 1;
                return .{ .tag = entry.tag, .data = output[0..entry.len] };
            }
            byte_offset += entry.len;
        }
        return null;
    }
};

test "priority pop bypasses data and preserves class order" {
    var bytes: [32]u8 = undefined;
    var entries: [4]Queue.Entry = undefined;
    var output: [32]u8 = undefined;
    var queue = try Queue.init(&bytes, &entries);
    try queue.push(3, "data-a");
    try queue.push(2, "signal");
    try queue.push(4, "data-b");
    try std.testing.expect(queue.hasTagBelow(3));
    try std.testing.expectEqualStrings("signal", (try queue.popFirstTagBelow(3, &output)).?.data);
    try std.testing.expect(!queue.hasTagBelow(3));
    try std.testing.expectEqualStrings("data-a", (try queue.pop(&output)).?.data);
    try std.testing.expectEqualStrings("data-b", (try queue.pop(&output)).?.data);
}

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
    try std.testing.expectEqual(@as(usize, 7), queue.high_water_bytes);
    try std.testing.expectEqual(@as(usize, 2), queue.high_water_entries);
    try std.testing.expectEqual(@as(usize, 0), queue.used_bytes);
    try std.testing.expect((try queue.pop(&output)) == null);
}
