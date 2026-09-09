//! NetherNet networking for Zig 0.16.
//! API details are in `docs/README.md`.

pub const framing = @import("framing.zig");
pub const identity = @import("identity.zig");
pub const credentials = @import("credentials.zig");

pub const Reliability = framing.Reliability;

pub const Signal = @import("signal.zig").Signal;
pub const ServerData = @import("server_data.zig").ServerData;
pub const ErrorCode = @import("error_codes.zig").ErrorCode;

pub const Connection = @import("connection.zig").Connection;
pub const ConnectionOptions = @import("connection.zig").Options;
pub const CallbackStats = @import("connection.zig").CallbackStats;
pub const ConnectionDiagnostics = @import("connection.zig").Diagnostics;
pub const IceState = @import("connection.zig").IceState;
pub const IceGatheringState = @import("connection.zig").IceGatheringState;
pub const ChannelState = @import("connection.zig").ChannelState;
pub const ChannelDiagnostics = @import("connection.zig").ChannelDiagnostics;
pub const SelectedIceAddresses = @import("connection.zig").SelectedIceAddresses;
pub const Address = @import("connection.zig").Address;
pub const Message = @import("connection.zig").Message;

pub const Peer = @import("peer.zig").Peer;
pub const State = @import("peer.zig").State;

pub const Identity = @import("sdp_identity.zig").Identity;

pub const Discovery = @import("discovery.zig").Discovery;
pub const DiscoveryOptions = @import("discovery.zig").Options;

pub const LanListener = @import("lan.zig").Listener;
pub const LanListenerOptions = @import("lan.zig").Options;
pub const dialLan = @import("lan.zig").dial;

pub const EndpointListener = @import("endpoint_listener.zig").Listener;
pub const EndpointListenerOptions = @import("endpoint_listener.zig").Options;
pub const EndpointServerStatus = @import("endpoint_listener.zig").ServerStatus;
pub const EndpointStatusProvider = @import("endpoint_listener.zig").StatusProvider;
pub const dialEndpoint = @import("endpoint.zig").dial;
