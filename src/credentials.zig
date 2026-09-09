const std = @import("std");

const maximum_urls = 64;
const maximum_url_length = 16 * 1024;
const maximum_credential_length = 4 * 1024;

pub const IceServer = struct {
    username: []const u8 = "",
    password: []const u8 = "",
    urls: []const []const u8,
};

pub const Credentials = struct {
    expiration_in_seconds: u32 = 0,
    ice_servers: []const IceServer = &.{},
};

/// Stores the encoded ICE URLs passed to libdatachannel.
pub const Urls = struct {
    allocator: std.mem.Allocator,
    values: [][*:0]const u8,

    pub fn init(allocator: std.mem.Allocator, credentials: Credentials) !Urls {
        var count: usize = 0;

        for (credentials.ice_servers) |server| {
            if (server.urls.len > maximum_urls - count) {
                return error.TooManyIceServers;
            }

            count += server.urls.len;
        }

        const values = try allocator.alloc([*:0]const u8, count);
        errdefer allocator.free(values);

        var filled: usize = 0;
        errdefer for (values[0..filled]) |value| {
            allocator.free(std.mem.span(value));
        };

        for (credentials.ice_servers) |server| {
            if (server.username.len > maximum_credential_length or
                server.password.len > maximum_credential_length)
            {
                return error.InvalidIceServer;
            }

            const has_credentials =
                server.username.len != 0 or server.password.len != 0;

            for (server.urls) |url| {
                if (url.len > maximum_url_length or
                    std.mem.indexOfScalar(u8, url, 0) != null)
                {
                    return error.InvalidIceServer;
                }

                const colon = std.mem.indexOfScalar(u8, url, ':') orelse
                    return error.InvalidIceServer;
                const authority = std.mem.trimStart(u8, url[colon + 1 ..], "/");
                if (authority.len == 0 or
                    std.mem.indexOfScalar(u8, authority, '@') != null)
                {
                    return error.InvalidIceServer;
                }
                const scheme = url[0..colon];
                const is_stun = std.ascii.eqlIgnoreCase(scheme, "stun");
                const is_turn =
                    std.ascii.eqlIgnoreCase(scheme, "turn") or
                    std.ascii.eqlIgnoreCase(scheme, "turns");

                if (!is_stun and !is_turn) {
                    return error.InvalidIceServer;
                }

                const owned = if (is_stun or !has_credentials)
                    try allocator.dupeZ(u8, url)
                else
                    try authenticatedUrl(
                        allocator,
                        scheme,
                        url[colon + 1 ..],
                        server.username,
                        server.password,
                    );

                values[filled] = owned.ptr;
                filled += 1;
            }
        }

        return .{
            .allocator = allocator,
            .values = values,
        };
    }

    pub fn deinit(self: Urls) void {
        for (self.values) |value| {
            self.allocator.free(std.mem.span(value));
        }

        self.allocator.free(self.values);
    }
};

fn authenticatedUrl(
    allocator: std.mem.Allocator,
    scheme: []const u8,
    raw_authority: []const u8,
    username: []const u8,
    password: []const u8,
) ![:0]u8 {
    const authority = std.mem.trimStart(u8, raw_authority, "/");

    if (std.mem.indexOfScalar(u8, authority, '@') != null) {
        return error.InvalidIceServer;
    }

    const escaped_username = try escape(allocator, username);
    defer allocator.free(escaped_username);

    const escaped_password = try escape(allocator, password);
    defer allocator.free(escaped_password);

    var final_length = std.math.add(usize, scheme.len, 1) catch return error.InvalidIceServer;
    final_length = std.math.add(usize, final_length, escaped_username.len) catch return error.InvalidIceServer;
    final_length = std.math.add(usize, final_length, 1) catch return error.InvalidIceServer;
    final_length = std.math.add(usize, final_length, escaped_password.len) catch return error.InvalidIceServer;
    final_length = std.math.add(usize, final_length, 1) catch return error.InvalidIceServer;
    final_length = std.math.add(usize, final_length, authority.len) catch return error.InvalidIceServer;
    if (final_length > maximum_url_length) return error.InvalidIceServer;

    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}:{s}:{s}@{s}",
        .{ scheme, escaped_username, escaped_password, authority },
        0,
    );
}

fn escape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (text) |byte| {
        const unreserved =
            std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "-._~", byte) != null;

        if (unreserved) {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(
                allocator,
                &.{ '%', hex[byte >> 4], hex[byte & 15] },
            );
        }
    }

    return output.toOwnedSlice(allocator);
}

test "TURN credentials escape delimiters and flatten URLs" {
    const urls = try Urls.init(std.testing.allocator, .{
        .ice_servers = &.{.{
            .username = "user:@",
            .password = "p@ss",
            .urls = &.{
                "turn:relay.example:3478?transport=udp",
                "stun:stun.example:3478",
            },
        }},
    });
    defer urls.deinit();

    try std.testing.expectEqualStrings(
        "turn:user%3A%40:p%40ss@relay.example:3478?transport=udp",
        std.mem.span(urls.values[0]),
    );
    try std.testing.expectEqualStrings(
        "stun:stun.example:3478",
        std.mem.span(urls.values[1]),
    );
}

test "ICE URL authorities and encoded lengths are bounded" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "stun:", "turn:", "turn:///" }) |url| {
        try std.testing.expectError(error.InvalidIceServer, Urls.init(allocator, .{
            .ice_servers = &.{.{ .urls = &.{url} }},
        }));
    }

    const credential = try allocator.alloc(u8, maximum_credential_length);
    defer allocator.free(credential);
    @memset(credential, '@');
    try std.testing.expectError(error.InvalidIceServer, Urls.init(allocator, .{
        .ice_servers = &.{.{
            .username = credential,
            .password = credential,
            .urls = &.{"turn:relay.example"},
        }},
    }));
}

fn credentialsFailureScenario(allocator: std.mem.Allocator) !void {
    const urls = try Urls.init(allocator, .{
        .ice_servers = &.{.{
            .username = "user:@",
            .password = "secret@",
            .urls = &.{
                "turn:localhost:3478",
                "turns:localhost:5349",
            },
        }},
    });
    defer urls.deinit();
}

test "credential construction allocation failures release prior URLs" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        credentialsFailureScenario,
        .{},
    );
}
