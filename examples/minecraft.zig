const std = @import("std");
const nethernet = @import("nethernet");

/// Advertised on `GET /v1/join`; bump these as Bedrock moves on.
const protocol_version = 2193;
const game_version = "1.26.51";

const usage =
    \\usage: minecraft [address] [--identity <path>] [--offline]
    \\
    \\  address           TCP signaling address, default 0.0.0.0:19132
    \\  --identity <path> PKCS#8 P-384 identity, default nethernet-identity.der
    \\  --offline         accept clients that present no identity
    \\
;

const banner =
    \\NetherNet-Zig transport smoke test. This is not a Minecraft server: it
    \\establishes the transport and hands you the first Bedrock payload undecoded.
    \\
    \\  signaling  tcp {s}
    \\  identity   {s} (sha256 {x})
    \\  anonymous  {}
    \\
    \\Add Server -> 127.0.0.1:19132, then join.
    \\
    \\
;

const Status = struct {
    queries: std.atomic.Value(usize) = .init(0),

    fn get(context: ?*anyopaque) !nethernet.EndpointServerStatus {
        const self: *Status = @ptrCast(@alignCast(context.?));
        _ = self.queries.fetchAdd(1, .monotonic);

        return .{
            .name = "NetherNet-Zig transport smoke test",
            .protocol = protocol_version,
            .version = game_version,
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

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--offline")) {
            offline = true;
        } else if (std.mem.eql(u8, args[index], "--identity")) {
            index += 1;
            if (index == args.len) {
                std.debug.print("{s}", .{usage});
                return error.MissingIdentityPath;
            }
            identity_path = args[index];
        } else if (std.mem.startsWith(u8, args[index], "-")) {
            std.debug.print("{s}", .{usage});
            return error.UnknownOption;
        } else {
            address_text = args[index];
        }
    }

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

    var status: Status = .{};
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
        },
    );
    defer listener.destroy();

    std.debug.print(banner, .{ address_text, identity_path, fingerprint, offline });

    const connection = try listener.accept();
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
