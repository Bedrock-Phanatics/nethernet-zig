const std = @import("std");
const builtin = @import("builtin");
const nethernet = @import("nethernet");

const usage =
    \\usage: minecraft [address] --protocol <number> --version <string> [--identity <path>] [--offline] [--trace]
    \\
    \\  address           TCP signaling address, default 0.0.0.0:19132 (also IPv6 on Windows)
    \\  --identity <path> PKCS#8 P-384 identity, default nethernet-identity.der
    \\  --offline         accept clients that present no identity
    \\  --trace           print safe HTTP and WebRTC negotiation stages
    \\  --protocol <number> required: protocol for the exact client build
    \\  --version <string>  required: version for the exact client build
    \\
;

const banner =
    \\NetherNet-Zig transport smoke test. This is not a Minecraft server: it
    \\establishes the transport and hands you the first Bedrock payload undecoded.
    \\
    \\  signaling  tcp {s}
    \\  identity   {s} (sha256 {x})
    \\  anonymous  {}
    \\  advertised protocol {d}, version {s} (transport test only)
    \\
    \\Add Server -> a reachable address and port for this listener, then join.
    \\
    \\
;

const Status = struct {
    queries: std.atomic.Value(usize) = .init(0),
    protocol: u32 = 0,
    version: []const u8 = "",

    fn get(context: ?*anyopaque) !nethernet.EndpointServerStatus {
        const self: *Status = @ptrCast(@alignCast(context.?));
        _ = self.queries.fetchAdd(1, .monotonic);

        return .{
            .name = "NetherNet-Zig transport smoke test",
            .protocol = self.protocol,
            .version = self.version,
            .level = "nethernet-zig",
            .players = 0,
            .max_players = 1,
            .game_type = 0,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var address_text: []const u8 = "0.0.0.0:19132";
    var identity_path: []const u8 = "nethernet-identity.der";
    var offline = false;
    var trace = false;
    var status: Status = .{};

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--offline")) {
            offline = true;
        } else if (std.mem.eql(u8, args[index], "--trace")) {
            trace = true;
        } else if (std.mem.eql(u8, args[index], "--identity")) {
            index += 1;
            if (index == args.len) {
                std.debug.print("{s}", .{usage});
                return error.MissingIdentityPath;
            }
            identity_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--protocol")) {
            index += 1;
            if (index == args.len) {
                std.debug.print("{s}", .{usage});
                return error.MissingProtocol;
            }
            status.protocol = std.fmt.parseInt(u32, args[index], 10) catch {
                std.debug.print("{s}", .{usage});
                return error.InvalidProtocol;
            };
            if (status.protocol == 0) return error.InvalidProtocol;
        } else if (std.mem.eql(u8, args[index], "--version")) {
            index += 1;
            if (index == args.len) {
                std.debug.print("{s}", .{usage});
                return error.MissingVersion;
            }
            if (args[index].len == 0 or args[index][0] == '-' or !std.unicode.utf8ValidateSlice(args[index]))
                return error.InvalidVersion;
            status.version = args[index];
        } else if (std.mem.startsWith(u8, args[index], "-")) {
            std.debug.print("{s}", .{usage});
            return error.UnknownOption;
        } else {
            address_text = args[index];
        }
    }

    if (status.protocol == 0 or status.version.len == 0) {
        std.debug.print("Both --protocol and --version must match the exact client build.\n{s}", .{usage});
        return error.MissingClientMetadata;
    }

    if (trace) nethernet.Peer.enableNativeTrace();

    const key = try nethernet.identity_file.loadOrCreate(
        init.io,
        init.gpa,
        identity_path,
    );

    var fingerprint: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        &key.public_key.toUncompressedSec1(),
        &fingerprint,
        .{},
    );

    const listener = try nethernet.EndpointListener.listen(
        init.gpa,
        init.io,
        try std.Io.net.IpAddress.parseLiteral(address_text),
        .{
            .connection = .{
                .server_identity_key = key,
                .allow_anonymous = offline,
            },
            .status_provider = .{ .context = &status, .get = Status.get },
            .trace = trace,
        },
    );
    defer listener.destroy();

    // Windows needs separate listeners for IPv4 and IPv6.
    const address = listener.server.socket.address;
    const ipv6_listener = if (builtin.os.tag == .windows and address == .ip4 and
        std.mem.eql(u8, &address.ip4.bytes, &.{ 0, 0, 0, 0 }))
        try nethernet.EndpointListener.listen(
            init.gpa,
            init.io,
            .{ .ip6 = .{ .bytes = .{0} ** 16, .port = address.getPort() } },
            listener.options,
        )
    else
        null;
    defer if (ipv6_listener) |ipv6| ipv6.destroy();

    std.debug.print(banner, .{ address_text, identity_path, fingerprint, offline, status.protocol, status.version });
    if (ipv6_listener != null) std.debug.print("  signaling  tcp [::]:{d}\n", .{address.getPort()});

    const connection = if (ipv6_listener) |ipv6| connection: {
        const Accepted = union(enum) { ipv4: anyerror!*nethernet.Connection, ipv6: anyerror!*nethernet.Connection };
        var results: [2]Accepted = undefined;
        var select = std.Io.Select(Accepted).init(init.io, &results);
        defer while (select.cancel()) |pending| {
            const extra = switch (pending) {
                inline else => |result| result catch continue,
            };
            extra.destroy();
        };
        try select.concurrent(.ipv4, nethernet.EndpointListener.accept, .{listener});
        try select.concurrent(.ipv6, nethernet.EndpointListener.accept, .{ipv6});
        break :connection try switch (try select.await()) {
            inline else => |result| result,
        };
    } else try listener.accept();
    defer connection.destroy();

    const diagnostics = connection.diagnostics();
    var failures: usize = 0;

    stage(1, "endpoint discovered", status.queries.load(.monotonic) > 0, &failures);
    stage(2, "SDP offer answered", true, &failures);
    stage(3, "ICE connected", diagnostics.ice_state == .connected or
        diagnostics.ice_state == .completed, &failures);
    stage(4, "DTLS/SCTP connected", connection.state() == .connected, &failures);
    stage(5, "ReliableDataChannel open", diagnostics.reliable.state == .open, &failures);
    stage(6, "UnreliableDataChannel open", diagnostics.unreliable.state == .open, &failures);

    var local: [256]u8 = undefined;
    var remote: [256]u8 = undefined;
    if (connection.selectedIceAddresses(&local, &remote)) |selected| {
        if (selected) |pair| {
            std.debug.print("      udp {s} <-> {s}\n", .{ pair.local, pair.remote });
        }
    } else |_| {}

    const first = try connection.receive();
    stage(7, "first Bedrock payload", true, &failures);
    std.debug.print("      {d} bytes, {s}, starts {x}\n", .{
        first.data.len,
        @tagName(first.reliability),
        first.data[0..@min(8, first.data.len)],
    });

    var payloads: usize = 1;
    var bytes: usize = first.data.len;
    while (connection.receive()) |message| {
        payloads += 1;
        bytes += message.data.len;
    } else |_| {}

    std.debug.print("\n{d} payloads, {d} bytes before the peer went away\n", .{
        payloads,
        bytes,
    });

    if (failures != 0) return error.TransportStageFailed;
}

fn stage(number: usize, name: []const u8, reached: bool, failures: *usize) void {
    if (!reached) failures.* += 1;
    std.debug.print("[{d}/7] {s: <28} {s}\n", .{
        number,
        name,
        if (reached) "ok" else "FAILED",
    });
}
