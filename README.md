# NetherNet

A Zig transport library for Minecraft Bedrock, powered by libdatachannel.

- Authenticated WebRTC connections over HTTP or LAN discovery
- Reliable and unreliable messaging with fragmentation and reassembly
- Configurable limits, backpressure, and connection diagnostics

## Requirements

- Zig 0.16.0
- Git and CMake
- A C/C++ toolchain supported by libdatachannel

## Build

Linux and macOS:

```sh
sh tools/setup-native.sh
zig build -Doptimize=ReleaseSafe
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File tools/setup-native.ps1
zig build -Doptimize=ReleaseSafe
```

Use `-Dnative-prefix=/path/to/prefix` to select an existing patched
libdatachannel installation.

## Example: echo server and client

The server accepts one connection and echoes messages until it receives `ack`.
The client prints the response and acknowledges it before both programs close.

### Server

[examples/server.zig](examples/server.zig)

```zig
const std = @import("std");
const nethernet = @import("nethernet");

pub fn main(init: std.process.Init) !void {
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:18750");

    const listener = try nethernet.EndpointListener.listen(
        init.gpa,
        init.io,
        address,
        .{
            .connection = .{
                .allow_anonymous = true,
            },
        },
    );
    defer listener.destroy();

    std.debug.print("NetherNet server on http://127.0.0.1:18750\n", .{});

    const connection = try listener.accept();
    defer connection.destroy();

    while (true) {
        const message = try connection.receive();
        if (std.mem.eql(u8, message.data, "ack")) break;
        try connection.send(message.data, message.reliability);
    }
}
```

This local example allows clients without an identity token.

### Client

[examples/client.zig](examples/client.zig)

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
    try connection.send("ack", .reliable);
}
```

### Run it

Build the examples using the instructions above, then start the server:

```sh
./zig-out/bin/server
```

In a second terminal, run the client:

```sh
./zig-out/bin/client
```

On Windows, run the corresponding executables:

```powershell
# First terminal
.\zig-out\bin\server.exe

# Second terminal
.\zig-out\bin\client.exe
```

The client prints:

```text
received: hello
```

### Minecraft smoke test

[examples/minecraft.zig](examples/minecraft.zig) tests transport connections and
receives Bedrock payloads. It does not implement login or gameplay.

The example advertises protocol 2193 and version 1.26.51, the latest stable
release in [Mojang's protocol changelog](https://mojang.github.io/bedrock-protocol-docs/changelog/),
so no flags are needed. `--protocol` and `--version` override them. Hosting
applications should advertise the protocol their game layer actually speaks.

```powershell
.\zig-out\bin\minecraft.exe --trace
```

Connect through Add Server to `127.0.0.1:19132`. Keep the identity file between
runs so the client's trust-on-first-use prompt only appears once. The Windows
default accepts both IPv4 and IPv6.

The example verifies client tokens against Minecraft's published signing keys,
including issuer, audience, expiration, and the fingerprint binding. `--offline`
disables issuer verification and permits anonymous clients.

With `--trace`, expect `GET /v1/join HTTP 200 application/json`, then
`POST /v1/join/{networkId} received`. `[7/7] first Bedrock payload` means the
WebRTC transport works end to end. The example then prints the protocol from
the client's `RequestNetworkSettings`. Gameplay login is outside this library.

For vanilla-facing applications, provide `status_provider` in
`EndpointListenerOptions`. Without one, GET returns 200 with an empty body,
like go-nethernet. Provider failures return 503 and invalid metadata 500.
TLS handshakes on the plaintext port are closed immediately so clients fall
back from `https://` to `http://` without waiting.

Authenticated listeners require `connection.verify_client`. Without it, startup
returns `MissingClientVerifier`, unless `allow_anonymous` is explicitly enabled.
`identity_issuer.Authority` verifies Minecraft multiplayer tokens and refetches
the signing keys when an unknown key ID appears, at most once a minute:

```zig
var authority = nethernet.identity_issuer.Authority.init(gpa, io);
defer authority.deinit();
try authority.refresh();
// EndpointListenerOptions.connection.verify_client = authority.verifier()
```

`identity_issuer.Keys` verifies RS256 tokens against a host-supplied JWKS
snapshot for other issuers.

A self-signed server identity proves key possession, not server trust. Clients
can use `verify_server` to pin a known key. Keep the server's identity file across
restarts. Transport authentication does not replace gameplay authorization.

## Networking

| Port | Protocol | Purpose |
| --- | --- | --- |
| 19132 | TCP | HTTP signaling (`/v1/join`) |
| Negotiated | UDP | WebRTC traffic |
| 7551 | UDP | LAN discovery |

Both signaling and WebRTC ports must be reachable. Configure
`port_range_begin` and `port_range_end` to fix the UDP range.
STUN and TURN servers are optional and must be configured explicitly.

For LAN discovery, bind hosts to `0.0.0.0:7551` and clients to port `0`.
Set `ServerData` with your server details and matching client protocol/version.
Port 7551 allows sharing, but Windows may deliver packets to only one listener.

## Tests

```sh
zig build test
zig build test-integration -Doptimize=ReleaseSafe
zig build fuzz -Dfuzz-iterations=1000
zig build stress-smoke -Doptimize=ReleaseSafe
```

`tests/interop/run.sh` runs the echo server against a
[go-nethernet](https://github.com/df-mc/go-nethernet) client that follows the
vanilla join flow: an `https://` probe, `GET /v1/join`, a signed offer, and
echoes on both data channels. It needs Go and `curl`, and CI runs it on Linux
and Windows.

Run `zig build bench` for benchmarks.

## License

[Apache-2.0](LICENSE).
