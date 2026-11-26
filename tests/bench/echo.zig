const std = @import("std");
const nethernet = @import("nethernet");

const Connection = nethernet.Connection;

/// Connections one thread echoes, each shard waiting on its own wakeup.
const Shard = struct {
    mutex: std.Io.Mutex = .init,
    accepted: std.ArrayList(*Connection) = .empty,
    wakeup: nethernet.Wakeup = .{},

    fn add(self: *Shard, io: std.Io, allocator: std.mem.Allocator, connection: *Connection) void {
        connection.peer.subscribe(&self.wakeup);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.accepted.append(allocator, connection) catch connection.destroy();
        self.wakeup.signal(io);
    }

    fn run(self: *Shard, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
        var active: std.ArrayList(*Connection) = .empty;
        defer {
            for (active.items) |connection| connection.destroy();
            active.deinit(allocator);
        }

        while (true) {
            const token = self.wakeup.prepare();
            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                try active.appendSlice(allocator, self.accepted.items);
                self.accepted.clearRetainingCapacity();
            }

            var progress = false;
            var index: usize = 0;
            while (index < active.items.len) {
                const connection = active.items[index];
                const alive = for (0..64) |_| {
                    const event = connection.poll() catch break false;
                    const message = switch (event orelse break true) {
                        .message => |message| message,
                        .signal => continue,
                    };
                    progress = true;
                    connection.send(message.data, message.reliability) catch |err| switch (err) {
                        error.Backpressure => {},
                        else => break false,
                    };
                } else true;
                if (alive) {
                    index += 1;
                } else {
                    connection.destroy();
                    _ = active.swapRemove(index);
                }
            }

            if (!progress) try self.wakeup.wait(io, token, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var address_text: []const u8 = "127.0.0.1:18760";
    var thread_count: usize = 1;
    var options: nethernet.EndpointListenerOptions = .{
        .connection = .{ .allow_anonymous = true },
        .maximum_negotiations = 64,
        .maximum_pending_accepts = 1024,
    };
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iterator.deinit();
    _ = iterator.next();
    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, "--ice-udp-mux")) {
            options.connection.native.enable_ice_udp_mux = true;
        } else if (std.mem.eql(u8, argument, "--rtc-threads")) {
            try nethernet.Peer.setNativeThreadPoolSize(try std.fmt.parseInt(u32, iterator.next() orelse return error.MissingArgument, 10));
        } else if (std.mem.eql(u8, argument, "--threads")) {
            thread_count = try std.fmt.parseInt(usize, iterator.next() orelse return error.MissingArgument, 10);
            if (thread_count == 0) return error.InvalidArgument;
        } else {
            address_text = argument;
        }
    }

    const listener = try nethernet.EndpointListener.listen(allocator, io, try std.Io.net.IpAddress.parseLiteral(address_text), options);
    defer listener.destroy();

    const shards = try allocator.alloc(Shard, thread_count);
    defer allocator.free(shards);
    @memset(shards, .{});
    const workers = try allocator.alloc(std.Io.Future(anyerror!void), thread_count);
    defer allocator.free(workers);
    for (shards, workers) |*shard, *worker| worker.* = try io.concurrent(Shard.run, .{ shard, io, allocator });
    defer for (workers) |*worker| worker.cancel(io) catch {};

    var next: usize = 0;
    while (true) : (next = (next + 1) % shards.len) {
        const connection = listener.accept() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        shards[next].add(io, allocator, connection);
    }
}
