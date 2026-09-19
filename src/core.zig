//! Native-free NetherNet protocol and utility components.

pub const credentials = @import("credentials.zig");
pub const discovery = @import("discovery.zig");
pub const discovery_codec = @import("discovery_codec.zig");
pub const framing = @import("framing.zig");
pub const identity = @import("identity.zig");
pub const queue = @import("queue.zig");
pub const sdp_identity = @import("sdp_identity.zig");
pub const server_data = @import("server_data.zig");
pub const signal = @import("signal.zig");
pub const wakeup = @import("wakeup.zig");

pub const Reliability = framing.Reliability;
pub const Signal = signal.Signal;
pub const ServerData = server_data.ServerData;
pub const ErrorCode = @import("error_codes.zig").ErrorCode;

pub const Identity = sdp_identity.Identity;
pub const IdentityKeyPair = sdp_identity.KeyPair;

pub const Discovery = discovery.Discovery;
pub const DiscoveryOptions = discovery.Options;

test {
    _ = credentials;
    _ = discovery;
    _ = discovery_codec;
    _ = framing;
    _ = identity;
    _ = queue;
    _ = sdp_identity;
    _ = server_data;
    _ = signal;
    _ = wakeup;
}
