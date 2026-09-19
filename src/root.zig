//! NetherNet transport for Minecraft Bedrock.

const core = @import("core.zig");
const connection = @import("connection.zig");
const endpoint_listener = @import("endpoint_listener.zig");
const lan = @import("lan.zig");
const peer = @import("peer.zig");

pub const framing = core.framing;
pub const identity = core.identity;
pub const credentials = core.credentials;

pub const Reliability = core.Reliability;
pub const Signal = core.Signal;
pub const ServerData = core.ServerData;
pub const ErrorCode = core.ErrorCode;

pub const Connection = connection.Connection;
pub const ConnectionOptions = connection.Options;
pub const CallbackStats = connection.CallbackStats;
pub const ConnectionDiagnostics = connection.Diagnostics;
pub const IceState = connection.IceState;
pub const IceGatheringState = connection.IceGatheringState;
pub const ChannelState = connection.ChannelState;
pub const ChannelDiagnostics = connection.ChannelDiagnostics;
pub const SelectedIceAddresses = connection.SelectedIceAddresses;
pub const Address = connection.Address;
pub const Message = connection.Message;

pub const Peer = peer.Peer;
pub const State = peer.State;

pub const Identity = core.Identity;
pub const IdentityKeyPair = core.IdentityKeyPair;

pub const Discovery = core.Discovery;
pub const DiscoveryOptions = core.DiscoveryOptions;

pub const LanListener = lan.Listener;
pub const LanListenerOptions = lan.Options;
pub const dialLan = lan.dial;

pub const EndpointListener = endpoint_listener.Listener;
pub const EndpointListenerOptions = endpoint_listener.Options;
pub const EndpointServerStatus = endpoint_listener.ServerStatus;
pub const EndpointStatusProvider = endpoint_listener.StatusProvider;
pub const dialEndpoint = @import("endpoint.zig").dial;
