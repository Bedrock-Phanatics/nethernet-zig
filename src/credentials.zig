const std = @import("std");
pub const IceServer = struct {
    username: []const u8 = "",
    password: []const u8 = "",
    urls: []const []const u8,
};
pub const Credentials = struct { expiration_in_seconds: u32 = 0, ice_servers: []const IceServer = &.{} };

/// Owns a flattened, percent-encoded URL array accepted by libdatachannel.
/// Keep alive through Peer.create; native configuration copies the strings.
pub const Urls = struct {
    allocator: std.mem.Allocator,
    values: [][*:0]const u8,
    pub fn init(a: std.mem.Allocator, credentials: Credentials) !Urls {
        var count: usize = 0;
        for (credentials.ice_servers) |server| {
            if (server.urls.len > 64 - count) return error.TooManyIceServers;
            count += server.urls.len;
        }
        const values = try a.alloc([*:0]const u8, count);
        errdefer a.free(values);
        var filled: usize = 0;
        errdefer for (values[0..filled]) |value| a.free(std.mem.span(value));
        for (credentials.ice_servers) |server| for (server.urls) |url| {
            if (url.len > 16384 or server.username.len > 4096 or server.password.len > 4096 or std.mem.indexOfScalar(u8, url, 0) != null) return error.InvalidIceServer;
            const colon = std.mem.indexOfScalar(u8, url, ':') orelse return error.InvalidIceServer;
            const scheme = url[0..colon];
            if (!std.ascii.eqlIgnoreCase(scheme, "stun") and !std.ascii.eqlIgnoreCase(scheme, "turn") and !std.ascii.eqlIgnoreCase(scheme, "turns")) return error.InvalidIceServer;
            const owned = if (std.ascii.eqlIgnoreCase(scheme, "stun") or (server.username.len == 0 and server.password.len == 0)) try a.dupeZ(u8, url) else blk: {
                const username = try escape(a, server.username);
                defer a.free(username);
                const password = try escape(a, server.password);
                defer a.free(password);
                const authority = std.mem.trimStart(u8, url[colon + 1 ..], "/");
                if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidIceServer;
                break :blk try std.fmt.allocPrintSentinel(a, "{s}:{s}:{s}@{s}", .{ scheme, username, password, authority }, 0);
            };
            values[filled] = owned.ptr;
            filled += 1;
        };
        return .{ .allocator = a, .values = values };
    }
    pub fn deinit(self: Urls) void {
        for (self.values) |value| self.allocator.free(std.mem.span(value));
        self.allocator.free(self.values);
    }
};
fn escape(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const hex = "0123456789ABCDEF";
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) try out.append(a, byte) else try out.appendSlice(a, &.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
    return out.toOwnedSlice(a);
}
test "TURN credentials escape delimiters and flatten URLs" {
    const urls = try Urls.init(std.testing.allocator, .{ .ice_servers = &.{.{ .username = "user:@", .password = "p@ss", .urls = &.{ "turn:relay.example:3478?transport=udp", "stun:stun.example:3478" } }} });
    defer urls.deinit();
    try std.testing.expectEqualStrings("turn:user%3A%40:p%40ss@relay.example:3478?transport=udp", std.mem.span(urls.values[0]));
    try std.testing.expectEqualStrings("stun:stun.example:3478", std.mem.span(urls.values[1]));
}

fn credentialsFailureScenario(a: std.mem.Allocator) !void {
    const urls = try Urls.init(a, .{ .ice_servers = &.{.{ .username = "user:@", .password = "secret@", .urls = &.{ "turn:localhost:3478", "turns:localhost:5349" } }} });
    defer urls.deinit();
}
test "credential construction allocation failures release prior URLs" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, credentialsFailureScenario, .{});
}
