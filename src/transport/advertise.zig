const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

pub const maximum_addresses = 8;
pub const maximum_sdp_size = 256 * 1024;
const maximum_address_length = 45;
const mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

/// Public addresses a server answers with. Only IP literals are taken, so nothing is resolved and
/// no translated port can be configured: the advertised port is always the ICE socket's own.
pub const Addresses = struct {
    buffer: [maximum_addresses]IpAddress = undefined,
    len: usize = 0,

    pub fn parse(texts: []const []const u8) error{InvalidAdvertiseAddress}!Addresses {
        if (texts.len > maximum_addresses) return error.InvalidAdvertiseAddress;
        var result: Addresses = .{};
        for (texts) |text| {
            const address = parseAddress(text) orelse return error.InvalidAdvertiseAddress;
            for (result.slice()) |held| if (sameIp(held, address)) return error.InvalidAdvertiseAddress;
            result.buffer[result.len] = address;
            result.len += 1;
        }
        return result;
    }

    pub fn slice(self: *const Addresses) []const IpAddress {
        return self.buffer[0..self.len];
    }
};

fn parseAddress(text: []const u8) ?IpAddress {
    if (text.len == 0 or text.len > maximum_address_length) return null;
    for (text) |byte| if (byte <= ' ' or byte >= 0x7f) return null;
    const address = IpAddress.parse(text, 0) catch return null;
    return if (reachable(address)) address else null;
}

// Unspecified, multicast, broadcast, link-local and IPv4-mapped addresses can't name a server.
fn reachable(address: IpAddress) bool {
    return switch (address) {
        .ip4 => |ip| ip.bytes[0] != 0 and ip.bytes[0] < 224 and !(ip.bytes[0] == 169 and ip.bytes[1] == 254),
        .ip6 => |ip| !std.mem.allEqual(u8, &ip.bytes, 0) and ip.bytes[0] != 0xff and
            !(ip.bytes[0] == 0xfe and ip.bytes[1] & 0xc0 == 0x80) and
            !std.mem.startsWith(u8, &ip.bytes, &mapped_prefix),
    };
}

fn sameIp(a: IpAddress, b: IpAddress) bool {
    return switch (a) {
        .ip4 => |ip| b == .ip4 and std.mem.eql(u8, &ip.bytes, &b.ip4.bytes),
        .ip6 => |ip| b == .ip6 and std.mem.eql(u8, &ip.bytes, &b.ip6.bytes),
    };
}

fn family(address: IpAddress) usize {
    return @intFromBool(address == .ip6);
}

fn writeIp(writer: *std.Io.Writer, address: IpAddress) !void {
    switch (address) {
        .ip4 => |ip| try writer.print("{d}.{d}.{d}.{d}", .{ ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3] }),
        .ip6 => |ip| try (std.Io.net.Ip6Address.Unresolved{ .bytes = ip.bytes, .interface_name = null }).format(writer),
    }
}

const Candidate = struct {
    address: IpAddress,
    port: u16,
    kind: enum { host, srflx, relay, other },
};

/// Only UDP candidates for the first component that name an IP literal are of use to a peer.
fn parseCandidate(line: []const u8) ?Candidate {
    if (!std.mem.startsWith(u8, line, "a=candidate:")) return null;
    var fields = std.mem.tokenizeScalar(u8, line["a=candidate:".len..], ' ');
    const foundation = fields.next() orelse return null;
    if (foundation.len > 32) return null;
    for (foundation) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '/') return null;
    if (!std.mem.eql(u8, fields.next() orelse return null, "1")) return null;
    if (!std.ascii.eqlIgnoreCase(fields.next() orelse return null, "udp")) return null;
    _ = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    const address = IpAddress.parse(fields.next() orelse return null, 0) catch return null;
    const port = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    if (port == 0 or !std.mem.eql(u8, fields.next() orelse return null, "typ")) return null;
    const kind = fields.next() orelse return null;
    return .{
        .address = address,
        .port = port,
        .kind = std.meta.stringToEnum(@FieldType(Candidate, "kind"), kind) orelse .other,
    };
}

pub const Added = struct {
    sdp: []u8,
    added: usize = 0,
    /// Configured addresses whose family has no gathered socket to forward to.
    unmatched: usize = 0,
};

/// Adds a server-reflexive candidate for each configured address the description doesn't already offer on
/// the forwarded port, which is the port of the host socket of its family. Every gathered candidate and
/// line stays as it was, so direct, private and STUN paths keep working.
pub fn addCandidates(allocator: std.mem.Allocator, sdp: []const u8, addresses: []const IpAddress) !Added {
    if (sdp.len > maximum_sdp_size) return error.MessageTooLarge;
    if (addresses.len == 0 or addresses.len > maximum_addresses) return error.InvalidAdvertiseAddress;

    var base_ports: [2]?u16 = .{ null, null };
    var lines = std.mem.splitScalar(u8, sdp, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        // A peer splitting on a stray CR could read a line out of the middle of another.
        for (line) |byte| if (byte < ' ' or byte == 0x7f) return error.MalformedSdp;
        const candidate = parseCandidate(line) orelse continue;
        if (candidate.kind == .host and base_ports[family(candidate.address)] == null)
            base_ports[family(candidate.address)] = candidate.port;
    }

    // A host candidate means the address is bound locally. A STUN mapping on another port may only answer
    // the STUN server, so it doesn't stand in for the forwarded port.
    var offered: [maximum_addresses]bool = @splat(false);
    lines = std.mem.splitScalar(u8, sdp, '\n');
    while (lines.next()) |raw| {
        const candidate = parseCandidate(std.mem.trimEnd(u8, raw, "\r")) orelse continue;
        if (candidate.kind != .host and candidate.kind != .srflx) continue;
        for (addresses, offered[0..addresses.len]) |address, *present| {
            if (sameIp(address, candidate.address) and
                (candidate.kind == .host or base_ports[family(address)] == candidate.port)) present.* = true;
        }
    }

    var result: Added = .{ .sdp = &.{} };
    for (addresses, offered[0..addresses.len]) |address, present| {
        if (present) continue;
        if (base_ports[family(address)] == null) result.unmatched += 1 else result.added += 1;
    }

    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, sdp.len + result.added * 128);
    errdefer output.deinit();
    const writer = &output.writer;
    var injected = result.added == 0;
    lines = std.mem.splitScalar(u8, sdp, '\n');
    while (lines.next()) |raw| {
        if (!injected and std.mem.startsWith(u8, raw, "a=candidate:")) {
            injected = true;
            const ending = if (std.mem.endsWith(u8, raw, "\r")) "\r\n" else "\n";
            for (addresses, offered[0..addresses.len], 0..) |address, present, index| {
                if (present) continue;
                const port = base_ports[family(address)] orelse continue;
                // Server-reflexive type preference, ranked by configured order below every host candidate.
                try writer.print("a=candidate:adv{d} 1 UDP {d} ", .{ index, (100 << 24) | ((65535 - index) << 8) | 255 });
                try writeIp(writer, address);
                try writer.print(" {d} typ srflx raddr {s} rport 0{s}", .{ port, if (address == .ip4) "0.0.0.0" else "::", ending });
            }
        }
        try writer.print("{s}{s}", .{ raw, if (lines.index != null) "\n" else "" });
    }

    result.sdp = try output.toOwnedSlice();
    return result;
}

fn expectAdded(addresses: []const []const u8, sdp: []const u8, expected: []const u8) !void {
    const parsed = try Addresses.parse(addresses);
    const result = try addCandidates(std.testing.allocator, sdp, parsed.slice());
    defer std.testing.allocator.free(result.sdp);
    try std.testing.expectEqualStrings(expected, result.sdp);
}

const docker_answer =
    "v=0\r\n" ++
    "o=rtc 1 0 IN IP4 127.0.0.1\r\n" ++
    "a=identity:signed\r\n" ++
    "a=fingerprint:sha-256 AB:CD\r\n" ++
    "m=application 19134 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
    "c=IN IP4 172.19.0.2\r\n" ++
    "a=mid:0\r\n" ++
    "a=ice-ufrag:u\r\n" ++
    "a=ice-pwd:p\r\n" ++
    "a=candidate:1 1 UDP 2122317823 172.19.0.2 19134 typ host\r\n" ++
    "a=candidate:2 1 UDP 2122317567 fdba:17c8:6c95::1 19134 typ host\r\n" ++
    "a=end-of-candidates\r\n";

test "forwarded addresses are offered beside every gathered candidate" {
    try expectAdded(&.{ "203.0.113.7", "2001:db8::7" }, docker_answer, "v=0\r\n" ++
        "o=rtc 1 0 IN IP4 127.0.0.1\r\n" ++
        "a=identity:signed\r\n" ++
        "a=fingerprint:sha-256 AB:CD\r\n" ++
        "m=application 19134 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "c=IN IP4 172.19.0.2\r\n" ++
        "a=mid:0\r\n" ++
        "a=ice-ufrag:u\r\n" ++
        "a=ice-pwd:p\r\n" ++
        "a=candidate:adv0 1 UDP 1694498815 203.0.113.7 19134 typ srflx raddr 0.0.0.0 rport 0\r\n" ++
        "a=candidate:adv1 1 UDP 1694498559 2001:db8::7 19134 typ srflx raddr :: rport 0\r\n" ++
        "a=candidate:1 1 UDP 2122317823 172.19.0.2 19134 typ host\r\n" ++
        "a=candidate:2 1 UDP 2122317567 fdba:17c8:6c95::1 19134 typ host\r\n" ++
        "a=end-of-candidates\r\n");
}

test "each family uses its own gathered port" {
    try expectAdded(&.{ "2001:db8::7", "203.0.113.7" }, "a=candidate:1 1 UDP 1 10.0.0.2 40000 typ host\n" ++
        "a=candidate:2 1 UDP 1 fd00::2 40002 typ host\n" ++
        "a=end-of-candidates", "a=candidate:adv0 1 UDP 1694498815 2001:db8::7 40002 typ srflx raddr :: rport 0\n" ++
        "a=candidate:adv1 1 UDP 1694498559 203.0.113.7 40000 typ srflx raddr 0.0.0.0 rport 0\n" ++
        "a=candidate:1 1 UDP 1 10.0.0.2 40000 typ host\n" ++
        "a=candidate:2 1 UDP 1 fd00::2 40002 typ host\n" ++
        "a=end-of-candidates");
}

test "addresses already offered on the forwarded port are not repeated" {
    const sdp = "a=candidate:1 1 UDP 2122317823 10.0.0.2 40000 typ host\r\n" ++
        "a=candidate:2 1 UDP 2122317567 198.51.100.4 40000 typ host\r\n" ++
        "a=candidate:3 1 UDP 1686052607 203.0.113.9 40000 typ srflx raddr 10.0.0.2 rport 40000\r\n" ++
        "a=candidate:4 1 UDP 1686052351 203.0.113.7 61000 typ srflx raddr 10.0.0.2 rport 40000\r\n" ++
        "a=candidate:5 1 UDP 16777215 192.0.2.9 3478 typ relay raddr 0.0.0.0 rport 0\r\n";
    // Bound locally and STUN on the forwarded port are left alone, a mapping on another port is not enough.
    try expectAdded(&.{ "198.51.100.4", "203.0.113.9", "203.0.113.7", "192.0.2.9" }, sdp, "a=candidate:adv2 1 UDP 1694498303 203.0.113.7 40000 typ srflx raddr 0.0.0.0 rport 0\r\n" ++
        "a=candidate:adv3 1 UDP 1694498047 192.0.2.9 40000 typ srflx raddr 0.0.0.0 rport 0\r\n" ++ sdp);
    try expectAdded(&.{ "198.51.100.4", "203.0.113.9" }, sdp, sdp);
}

test "malformed candidates are left alone and never chosen as a base" {
    try expectAdded(&.{"203.0.113.7"}, "a=candidate:2 2 UDP 1 10.0.0.2 40001 typ host\n" ++
        "a=candidate:3 1 TCP 1 10.0.0.2 9 typ host\n" ++
        "a=candidate:4 1 UDP 1 host.local 40002 typ host\n" ++
        "a=candidate:5 1 UDP x 10.0.0.2 40003 typ host\n" ++
        "a=candidate:6 1 UDP 1 fe80::1%eth0 40004 typ host\n" ++
        "a=candidate:a-b 1 UDP 1 10.0.0.2 40005 typ host\n" ++
        "a=candidate:7 1 UDP 1 203.0.113.7 40006 typ prflx\n" ++
        "a=candidate:8\n" ++
        "a=candidate:1 1 UDP 1 10.0.0.2 40000 typ host\n", "a=candidate:adv0 1 UDP 1694498815 203.0.113.7 40000 typ srflx raddr 0.0.0.0 rport 0\n" ++
        "a=candidate:2 2 UDP 1 10.0.0.2 40001 typ host\n" ++
        "a=candidate:3 1 TCP 1 10.0.0.2 9 typ host\n" ++
        "a=candidate:4 1 UDP 1 host.local 40002 typ host\n" ++
        "a=candidate:5 1 UDP x 10.0.0.2 40003 typ host\n" ++
        "a=candidate:6 1 UDP 1 fe80::1%eth0 40004 typ host\n" ++
        "a=candidate:a-b 1 UDP 1 10.0.0.2 40005 typ host\n" ++
        "a=candidate:7 1 UDP 1 203.0.113.7 40006 typ prflx\n" ++
        "a=candidate:8\n" ++
        "a=candidate:1 1 UDP 1 10.0.0.2 40000 typ host\n");

    const parsed = try Addresses.parse(&.{"203.0.113.7"});
    for ([_][]const u8{
        "a=candidate:1 1 UDP 1 10.0.0.2 40000 typ host\na=candidate:\r 1 UDP 1 203.0.113.7 40000 typ host\n",
        "a=candidate:1 1 UDP 1 10.0.0.2 40000 typ host\na=x:y\ra=candidate:9 1 UDP 1 10.0.0.9 1 typ host\r\n",
        "a=candidate:1 1 UDP 1 10.0.0.2 40000 typ host\na=x:\x00\n",
    }) |sdp| try std.testing.expectError(error.MalformedSdp, addCandidates(std.testing.allocator, sdp, parsed.slice()));
}

test "an address family without a gathered socket is never given a guessed port" {
    const parsed = try Addresses.parse(&.{ "203.0.113.7", "2001:db8::7" });
    const sdp = "a=candidate:1 1 UDP 1 fd00::2 40000 typ host\r\n";
    const result = try addCandidates(std.testing.allocator, sdp, parsed.slice());
    defer std.testing.allocator.free(result.sdp);
    try std.testing.expectEqual([2]usize{ 1, 1 }, [2]usize{ result.added, result.unmatched });
    try std.testing.expectEqualStrings("a=candidate:adv1 1 UDP 1694498559 2001:db8::7 40000 typ srflx raddr :: rport 0\r\n" ++ sdp, result.sdp);

    for ([_][]const u8{
        "",
        "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=end-of-candidates\r\n",
        "a=candidate:1 1 UDP 1 192.0.2.1 40000 typ srflx\r\n",
    }) |unchanged| try expectAdded(&.{"203.0.113.7"}, unchanged, unchanged);
}

test "adding candidates is bounded and releases memory on every failure" {
    const parsed = try Addresses.parse(&.{"203.0.113.7"});
    const oversized: [maximum_sdp_size + 1]u8 = @splat('a');
    try std.testing.expectError(error.MessageTooLarge, addCandidates(std.testing.allocator, &oversized, parsed.slice()));
    try std.testing.expectError(error.InvalidAdvertiseAddress, addCandidates(std.testing.allocator, docker_answer, &.{}));

    const Scenario = struct {
        fn run(allocator: std.mem.Allocator, addresses: []const IpAddress) !void {
            const result = try addCandidates(allocator, docker_answer, addresses);
            allocator.free(result.sdp);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{parsed.slice()});
}

test "advertised addresses must be distinct reachable IP literals" {
    const valid = try Addresses.parse(&.{ "203.0.113.7", "2001:db8::7", "127.0.0.2", "::1", "10.0.0.1" });
    try std.testing.expectEqual(@as(usize, 5), valid.len);
    try std.testing.expectEqual(@as(usize, 0), (try Addresses.parse(&.{})).len);

    for ([_][]const u8{
        "",                 "0.0.0.0",                "::",                                           "224.0.0.1",     "239.255.255.250",
        "255.255.255.255",  "ff02::1",                "169.254.1.1",                                  "fe80::1",       "fe80::1%eth0",
        "::ffff:192.0.2.1", "203.0.113.7:19132",      "[2001:db8::7]",                                "203.0.113.7\n", " 203.0.113.7",
        "203.0.113.7\x00",  "example.com",            "localhost",                                    "1.2.3",         "01.2.3.4",
        "2001:db8::7 ",     "2001:db8:0:0:0:0:0:0:7", "1111:2222:3333:4444:5555:6666:7777:8888:9999",
    }) |text| {
        if (Addresses.parse(&.{text})) |_| {
            std.debug.print("accepted {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.InvalidAdvertiseAddress, err);
    }
    try std.testing.expectError(error.InvalidAdvertiseAddress, Addresses.parse(&.{ "203.0.113.7", "203.0.113.7" }));
    try std.testing.expectError(error.InvalidAdvertiseAddress, Addresses.parse(&.{ "2001:db8::7", "2001:DB8:0::7" }));
    try std.testing.expectError(error.InvalidAdvertiseAddress, Addresses.parse(&@as([maximum_addresses + 1][]const u8, @splat("192.0.2.1"))));
}
