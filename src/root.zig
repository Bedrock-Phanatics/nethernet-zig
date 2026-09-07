//! NetherNet for Zig 0.16. Public connections are single-owner objects.
//! Listener accept transfers ownership; every create/listen/dial result must
//! eventually be destroyed. See docs/GUIDE.md for allocator, lifetime and I/O contracts.
pub const framing = @import("framing.zig");
pub const Reliability = framing.Reliability;
pub const Signal = @import("signal.zig").Signal;
pub const ServerData = @import("server_data.zig").ServerData;
pub const Discovery = @import("discovery.zig").Discovery;
pub const DiscoveryOptions = @import("discovery.zig").Options;
pub const Connection = @import("connection.zig").Connection;
pub const ConnectionOptions = @import("connection.zig").Options;
pub const Peer = @import("peer.zig").Peer;
pub const State = @import("peer.zig").State;
pub const Identity = @import("sdp_identity.zig").Identity;
pub const identity = @import("identity.zig");
pub const LanListener = @import("lan.zig").Listener;
pub const LanListenerOptions = @import("lan.zig").Options;
pub const dialLan = @import("lan.zig").dial;
pub const EndpointListener = @import("endpoint_listener.zig").Listener;
pub const EndpointListenerOptions = @import("endpoint_listener.zig").Options;
pub const dialEndpoint = @import("endpoint.zig").dial;
pub const credentials = @import("credentials.zig");
pub const ErrorCode = @import("error_codes.zig").ErrorCode;
pub const Address = @import("connection.zig").Address;
pub const Message = @import("connection.zig").Message;
