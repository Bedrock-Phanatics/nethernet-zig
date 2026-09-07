const std = @import("std");
const nethernet = @import("nethernet");
pub fn main(init: std.process.Init) !void {
    const connection = try nethernet.dialEndpoint(init.gpa, init.io, "http://127.0.0.1:18750", 123, .{});
    defer connection.destroy();
    try connection.send("hello", .reliable);
    const message = try connection.receive();
    std.debug.print("received {s}\n", .{message.data});
}
