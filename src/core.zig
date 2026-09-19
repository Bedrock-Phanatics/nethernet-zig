//! Native-free protocol surface used by unit tests and fuzz targets.

const std = @import("std");

pub const credentials = @import("auth/credentials.zig");
pub const identity = @import("auth/token.zig");
pub const sdp_identity = @import("auth/sdp.zig");
pub const Identity = sdp_identity.Identity;
pub const IdentityKeyPair = sdp_identity.KeyPair;

pub const discovery = @import("discovery/client.zig");
pub const discovery_codec = @import("discovery/codec.zig");
pub const server_data = @import("discovery/server_data.zig");
pub const Discovery = discovery.Discovery;
pub const DiscoveryOptions = discovery.Options;
pub const ServerData = server_data.ServerData;

pub const ErrorCode = @import("protocol/error_code.zig").ErrorCode;
pub const signal = @import("protocol/signal.zig");
pub const Signal = signal.Signal;

pub const framing = @import("transport/framing.zig");
pub const Reliability = framing.Reliability;

pub const queue = @import("internal/queue.zig");
pub const wakeup = @import("internal/wakeup.zig");

test {
    std.testing.refAllDecls(@This());
}
