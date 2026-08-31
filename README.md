# NetherNet for .NET 10

An implementation of Minecraft: Bedrock Edition's NetherNet transport for C# and .NET 10, ported from [`df-mc/go-nethernet`](https://github.com/df-mc/go-nethernet).

The library includes:

- WebRTC ICE/DTLS/SCTP connections with Minecraft's reliable and unreliable data channels.
- NetherNet message fragmentation and reconstruction (up to 255 segments).
- LAN discovery on UDP port `7551`, including the vanilla AES-ECB/HMAC packet envelope.
- Version 6 server advertisements and RakNet pong-data conversion.
- HTTP/HTTPS `/v1/join` endpoint signaling.
- ES384 identity tokens and detached DTLS fingerprint assertions.
- Trickle ICE and complete-SDP (non-trickle) negotiation.

## Build

```powershell
dotnet build NetherNet.slnx
dotnet test NetherNet.slnx
```

## LAN server

```csharp
using System.Net;
using NetherNet;
using NetherNet.Discovery;

await using var discovery = DiscoveryListener.Listen(
    new IPEndPoint(IPAddress.Any, DiscoveryListener.DefaultPort));

discovery.SetServerData(new ServerData
{
    ServerName = "My Server",
    LevelName = "My World",
    GameType = GameType.Survival,
    MaxPlayerCount = 20,
    AcceptsOnlineAuth = true,
    AcceptsSelfSignedAuth = true,
    Nonce = Convert.ToHexString(Guid.NewGuid().ToByteArray()).ToLowerInvariant()
});

await using var listener = NetherNetListener.Listen(discovery, new ListenerOptions
{
    // Set false in production and provide VerifyClientToken for authenticated clients.
    AllowAnonymous = true
});

await using NetherNetConnection connection = await listener.AcceptAsync();
byte[] packet = await connection.ReceiveAsync();
await connection.SendAsync(packet);
```

## LAN client

```csharp
using System.Net;
using NetherNet;
using NetherNet.Discovery;

await using var discovery = DiscoveryListener.Listen(new IPEndPoint(IPAddress.Any, 0));

// Responses are refreshed by the discovery listener every two seconds.
await Task.Delay(TimeSpan.FromSeconds(3));
ulong serverId = discovery.Responses.Keys.First();

await using NetherNetConnection connection = await new Dialer().DialAsync(
    serverId.ToString(), discovery);
```

## HTTP endpoint server

```csharp
using NetherNet;
using NetherNet.Endpoint;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
var signaling = app.MapNetherNet();
await using var listener = NetherNetListener.Listen(signaling, new ListenerOptions
{
    AllowAnonymous = true
});

await app.RunAsync();
```

For endpoint clients, create an `EndpointClient` and dial a network ID such as `https://example.com:443`.

## Resource limits

Network-facing collections and negotiations are bounded by default. The limits can be tuned through:

- `EndpointHandlerOptions.MaximumPendingOffers`
- `ListenerOptions.MaximumConcurrentNegotiations`
- `ListenerOptions.MaximumPendingAccepts`
- `ListenerOptions.MaximumQueuedPacketsPerChannel`
- `ListenerOptions.MaximumReconstructedMessageSize`
- `DialerOptions.MaximumQueuedPacketsPerChannel`
- `DialerOptions.MaximumReconstructedMessageSize`
- `DiscoveryOptions.MaximumDiscoveredServers`

Exceeding an admission or packet-queue limit rejects the offer or closes the offending connection rather than retaining unbounded state.

## Authentication

Servers generate a short-lived self-signed P-384 identity by default. Client identity tokens can be supplied through `DialerOptions.Identity`. For authenticated servers, keep `AllowAnonymous` disabled and provide `ListenerOptions.VerifyClientToken`; the library separately verifies that the token's `cpk` key signed the negotiated DTLS fingerprint assertion.

## TODO
vulnerability checking
WebRTC transport is provided by SIPSorcery. Its current DCEP decoder does not expose incoming reliability fields, so incoming channels are classified using Minecraft's fixed `ReliableDataChannel` and `UnreliableDataChannel` labels. Outgoing channel parameters still match NetherNet.

Compact JWT and detached JWS signing and verification are provided by `jose-jwt`. Discovery encryption, UDP transport, HTTP signaling, JSON, and PKIX/JWK key handling use the .NET runtime libraries.
