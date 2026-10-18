const std = @import("std");

pub const Queue = struct {
    pub const Entry = struct {
        len: u32,
        tag: u8,
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
        if (bytes.len == 0 or entries.len == 0 or bytes.len > std.math.maxInt(u32)) {
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

        const start = wrap(self.read_byte + self.used_bytes, self.bytes.len);
        const first_len = @min(data.len, self.bytes.len - start);
        @memcpy(self.bytes[start..][0..first_len], data[0..first_len]);
        @memcpy(self.bytes[0 .. data.len - first_len], data[first_len..]);

        self.entries[wrap(self.head + self.count, self.entries.len)] = .{
            .tag = tag,
            .len = @intCast(data.len),
        };

        self.used_bytes += data.len;
        self.count += 1;
        self.high_water_bytes = @max(self.high_water_bytes, self.used_bytes);
        self.high_water_entries = @max(self.high_water_entries, self.count);
    }

    pub fn pop(self: *Queue, output: []u8) !?Popped {
        if (self.count == 0) return null;

        const entry = self.entries[self.head];
        if (output.len < entry.len) return error.NoSpaceLeft;
        self.copyOut(self.read_byte, output[0..entry.len]);

        self.used_bytes -= entry.len;
        self.count -= 1;
        if (self.count == 0) {
            self.read_byte = 0;
            self.head = 0;
        } else {
            self.read_byte = wrap(self.read_byte + entry.len, self.bytes.len);
            self.head = wrap(self.head + 1, self.entries.len);
        }

        return .{ .tag = entry.tag, .data = output[0..entry.len] };
    }

    pub fn popFirstTagBelow(self: *Queue, limit: u8, output: []u8) !?Popped {
        var byte_offset: usize = 0;
        var index = self.head;
        for (0..self.count) |offset| {
            const entry = self.entries[index];
            if (entry.tag >= limit) {
                byte_offset += entry.len;
                index = wrap(index + 1, self.entries.len);
                continue;
            }
            if (offset == 0) return self.pop(output);
            if (output.len < entry.len) return error.NoSpaceLeft;

            const start = wrap(self.read_byte + byte_offset, self.bytes.len);
            self.copyOut(start, output[0..entry.len]);
            self.moveDown(start, wrap(start + entry.len, self.bytes.len), self.used_bytes - byte_offset - entry.len);

            for (offset + 1..self.count) |_| {
                const next = wrap(index + 1, self.entries.len);
                self.entries[index] = self.entries[next];
                index = next;
            }

            self.used_bytes -= entry.len;
            self.count -= 1;
            return .{ .tag = entry.tag, .data = output[0..entry.len] };
        }
        return null;
    }

    fn copyOut(self: *const Queue, start: usize, output: []u8) void {
        const first_len = @min(output.len, self.bytes.len - start);
        @memcpy(output[0..first_len], self.bytes[start..][0..first_len]);
        @memcpy(output[first_len..], self.bytes[0 .. output.len - first_len]);
    }

    fn moveDown(self: *Queue, destination: usize, source: usize, len: usize) void {
        var to = destination;
        var from = source;
        var remaining = len;
        while (remaining != 0) {
            const chunk = @min(remaining, self.bytes.len - to, self.bytes.len - from);
            std.mem.copyForwards(u8, self.bytes[to..][0..chunk], self.bytes[from..][0..chunk]);
            to = wrap(to + chunk, self.bytes.len);
            from = wrap(from + chunk, self.bytes.len);
            remaining -= chunk;
        }
    }

    inline fn wrap(index: usize, len: usize) usize {
        return if (index >= len) index - len else index;
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
    try std.testing.expectEqualStrings("signal", (try queue.popFirstTagBelow(3, &output)).?.data);
    try std.testing.expect((try queue.popFirstTagBelow(3, &output)) == null);
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

test "draining restarts the ring at the front" {
    var bytes: [16]u8 = undefined;
    var entries: [4]Queue.Entry = undefined;
    var output: [16]u8 = undefined;
    var queue = try Queue.init(&bytes, &entries);
    for (0..10) |_| {
        try queue.push(3, "abcdefghij");
        _ = (try queue.pop(&output)).?;
        try std.testing.expectEqual(@as(usize, 0), queue.read_byte);
        try std.testing.expectEqual(@as(usize, 0), queue.head);
    }
    try queue.push(3, "abcdefghij");
    try queue.push(2, "klm");
    try std.testing.expectEqualStrings("klm", (try queue.popFirstTagBelow(3, &output)).?.data);
    try std.testing.expectEqualStrings("abcdefghij", (try queue.pop(&output)).?.data);
    try std.testing.expectEqual(@as(usize, 0), queue.read_byte);
}

test "random operations match a simple model across wraparound" {
    const allocator = std.testing.allocator;
    const Message = struct { tag: u8, data: []u8 };

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    for ([_]usize{ 1, 7, 16, 61 }) |byte_capacity| {
        for ([_]usize{ 1, 2, 5 }) |entry_capacity| {
            const bytes = try allocator.alloc(u8, byte_capacity);
            defer allocator.free(bytes);
            const entries = try allocator.alloc(Queue.Entry, entry_capacity);
            defer allocator.free(entries);
            var queue = try Queue.init(bytes, entries);

            var model: std.ArrayList(Message) = .empty;
            defer {
                for (model.items) |message| allocator.free(message.data);
                model.deinit(allocator);
            }
            var model_bytes: usize = 0;
            var input: [64]u8 = undefined;
            var output: [64]u8 = undefined;

            for (0..20_000) |_| {
                switch (random.uintLessThan(u8, 4)) {
                    0, 1 => {
                        const tag = random.uintLessThan(u8, 5);
                        const len = random.uintAtMost(usize, @min(byte_capacity, input.len));
                        random.bytes(input[0..len]);
                        const reserve_bytes = if (random.boolean()) random.uintAtMost(usize, byte_capacity) else 0;
                        const reserve_entries = if (random.boolean()) random.uintAtMost(usize, entry_capacity) else 0;
                        const fits = model.items.len < entry_capacity - reserve_entries and
                            model_bytes + len <= byte_capacity - reserve_bytes;
                        if (queue.pushWithReserve(tag, input[0..len], reserve_bytes, reserve_entries)) {
                            try std.testing.expect(fits);
                            try model.append(allocator, .{ .tag = tag, .data = try allocator.dupe(u8, input[0..len]) });
                            model_bytes += len;
                        } else |err| {
                            try std.testing.expectEqual(error.QueueFull, err);
                            try std.testing.expect(!fits);
                        }
                    },
                    2 => {
                        const popped = try queue.pop(&output);
                        if (model.items.len == 0) {
                            try std.testing.expect(popped == null);
                            continue;
                        }
                        const expected = model.orderedRemove(0);
                        defer allocator.free(expected.data);
                        model_bytes -= expected.data.len;
                        try std.testing.expectEqual(expected.tag, popped.?.tag);
                        try std.testing.expectEqualSlices(u8, expected.data, popped.?.data);
                    },
                    else => {
                        const limit = random.uintAtMost(u8, 5);
                        const popped = try queue.popFirstTagBelow(limit, &output);
                        const position = for (model.items, 0..) |message, i| {
                            if (message.tag < limit) break i;
                        } else null;
                        try std.testing.expectEqual(position != null, popped != null);
                        if (position) |i| {
                            const expected = model.orderedRemove(i);
                            defer allocator.free(expected.data);
                            model_bytes -= expected.data.len;
                            try std.testing.expectEqual(expected.tag, popped.?.tag);
                            try std.testing.expectEqualSlices(u8, expected.data, popped.?.data);
                        } else {
                            try std.testing.expect(popped == null);
                        }
                    },
                }
                try std.testing.expectEqual(model.items.len, queue.count);
                try std.testing.expectEqual(model_bytes, queue.used_bytes);
            }
        }
    }
}
