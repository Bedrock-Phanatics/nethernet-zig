const std = @import("std");
const nethernet = @import("nethernet");
pub fn main(init: std.process.Init) !void {
    const listener = try nethernet.EndpointListener.listen(init.gpa, init.io, try std.Io.net.IpAddress.parseLiteral("127.0.0.1:18750"), .{ .connection = .{ .allow_anonymous = true } });
    defer listener.destroy();
    std.debug.print("Echo listener on http://127.0.0.1:18750\n", .{});
    const connection = try listener.accept();
    defer connection.destroy();
    const message = try connection.receive();
    try connection.send(message.data, message.reliability);
    try std.Io.sleep(init.io, .fromMilliseconds(100), .awake);
}
