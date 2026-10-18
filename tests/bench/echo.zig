const std = @import("std");
const nethernet = @import("nethernet");

const Connection = nethernet.Connection;

const Accepted = struct {
    mutex: std.Io.Mutex = .init,
    connections: std.ArrayList(*Connection) = .empty,
    wakeup: nethernet.Wakeup = .{},

    fn run(self: *Accepted, io: std.Io, allocator: std.mem.Allocator, listener: *nethernet.EndpointListener) std.Io.Cancelable!void {
        while (true) {
            const connection = listener.accept() catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            connection.peer.subscribe(&self.wakeup);
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.connections.append(allocator, connection) catch connection.destroy();
            self.wakeup.signal(io);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var address_text: []const u8 = "127.0.0.1:18760";
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
        } else {
            address_text = argument;
        }
    }

    const listener = try nethernet.EndpointListener.listen(allocator, io, try std.Io.net.IpAddress.parseLiteral(address_text), options);
    defer listener.destroy();

    var accepted: Accepted = .{};
    var acceptor = try io.concurrent(Accepted.run, .{ &accepted, io, allocator, listener });
    defer acceptor.cancel(io) catch {};

    var active: std.ArrayList(*Connection) = .empty;
    defer {
        for (active.items) |connection| connection.destroy();
        active.deinit(allocator);
    }

    while (true) {
        const token = accepted.wakeup.prepare();
        {
            accepted.mutex.lockUncancelable(io);
            defer accepted.mutex.unlock(io);
            try active.appendSlice(allocator, accepted.connections.items);
            accepted.connections.clearRetainingCapacity();
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

        if (!progress) try accepted.wakeup.wait(io, token, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    }
}
