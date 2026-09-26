# NetherNet

NetherNet is a Zig transport library for Minecraft Bedrock networking. It
provides authenticated WebRTC connections over HTTP or LAN signaling, with
reliable and unreliable message delivery through libdatachannel.

## Features

- HTTP endpoint and LAN discovery connection flows
- Reliable and unreliable DataChannel messages
- Authenticated SDP exchange and configurable identity verification
- Bounded queues, message sizes, candidates, and signaling payloads
- Graceful shutdown, connection diagnostics, and transport statistics

## Ports

| Port | Protocol | Use |
| --- | --- | --- |
| 19132 | TCP | Direct HTTP signaling (`/v1/join`) |
| negotiated | UDP | ICE, DTLS and SCTP traffic |
| 7551 | UDP | LAN discovery |

Signaling only carries the SDP exchange; gameplay moves onto the negotiated UDP
ports, so both are required. Pin the UDP range with
`.native = .{ .port_range_begin = 30000, .port_range_end = 30010 }`.

LAN discovery is separate. `127.0.0.1:7551` does not work in the Add Server
screen, which needs the signaling port `127.0.0.1:19132`.

## Reachability

No STUN or TURN server is configured by default, so a peer only ever offers
host candidates. A server that must be reachable from outside its own network
has to advertise at least one candidate the client can actually reach: a public
address, a forwarded port (pin the range with `port_range_begin` /
`port_range_end`), or an explicitly configured relay via
`.native = .{ .ice_servers = &.{"stun:host:3478"} }`. Public infrastructure
stays opt-in rather than being enabled behind your back.

`EndpointListener` returns an empty `200` for `GET /v1/join` without a
`status_provider`, matching Axolotl's fallback. With a provider it returns JSON
status, including the advertised Bedrock protocol and version.

Network IDs are opaque strings throughout. `dialEndpoint` also accepts an
integer and percent-encodes the ID in the request path. IDs are bounded to
4096 bytes and cannot contain control characters.

## Requirements

- Zig 0.16.0
- Git and CMake
- A C/C++ toolchain supported by libdatachannel

## Build

Set up the pinned native dependencies, then build in `ReleaseSafe` mode:

```sh
# Linux and macOS
sh tools/setup-native.sh
zig build -Doptimize=ReleaseSafe
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File tools/setup-native.ps1
zig build -Doptimize=ReleaseSafe
```

An existing patched libdatachannel installation can be selected with
`-Dnative-prefix=/path/to/prefix`.

## Quick start

```zig
const std = @import("std");
const nethernet = @import("nethernet");

pub fn main(init: std.process.Init) !void {
    const connection = try nethernet.dialEndpoint(
        init.gpa,
        init.io,
        "http://127.0.0.1:18750",
        123,
        .{},
    );
    defer connection.destroy();

    try connection.send("hello", .reliable);

    const message = try connection.receive();
    std.debug.print("received: {s}\n", .{message.data});
}
```

Complete client and server programs are available in
[`examples/client.zig`](examples/client.zig) and
[`examples/server.zig`](examples/server.zig).

## Minecraft smoke test

[`examples/minecraft.zig`](examples/minecraft.zig) binds `0.0.0.0:19132` and
reports each transport stage up to the first Bedrock payload, which it hands
back undecoded. It is a transport test, not a Minecraft server.

```sh
./zig-out/bin/minecraft   # then Add Server -> 127.0.0.1:19132
```

Its identity is persisted to `nethernet-identity.der` (`--identity` to choose).
Clients pin the server key on first connection over plain HTTP, so a key that
changes on restart re-prompts every player. An existing P-384 key works if it is
PKCS#8:

```sh
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 |
    openssl pkcs8 -topk8 -nocrypt -outform DER -out nethernet-identity.der
```

Clients must present an identity unless `--offline` is passed.

For a same-client backend check on Windows, run the smoke test with
`--trace --identity nethernet-identity.der` twice. Use the default MbedTLS build
first. Then run `tools/setup-native.ps1 -Backend OpenSSL -OpenSslRoot <path>` and
build with `-Dnative-prefix=.deps/native-openssl`. Keep the identity file,
address, and client unchanged. The trace redacts identity assertions and ICE
passwords; compare HTTP, SDP, ICE, channel states, and the first payload.

## API overview

| API | Use |
| --- | --- |
| `dialEndpoint` | Connect to a server through HTTP signaling. |
| `EndpointListener` | Listen for HTTP-signaled connections. |
| `dialLan` | Discover and connect to a server on the local network. |
| `LanListener` | Advertise and accept connections on the local network. |
| `Connection` | Send and receive messages, inspect state, and close a connection. |
| `ConnectionOptions` | Configure timeouts, limits, ICE servers, and identity policy. |
| `Identity` / `IdentityKeyPair` | Configure authenticated SDP identities. |
| `identity_file` | Load or create a persistent PKCS#8 P-384 server identity. |

The supported public surface is exposed by `@import("nethernet")`. Everything
under `src/internal` is private implementation detail.

## Verification

```sh
zig fmt --check build.zig build.zig.zon src tests examples
zig build test
zig build fuzz -Dfuzz-iterations=100000
zig build test-integration -Doptimize=ReleaseSafe
zig build stress-smoke -Doptimize=ReleaseSafe
```

## License

Licensed under Apache-2.0. See [LICENSE](LICENSE).