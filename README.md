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

The server accepts one connection and echoes a message. The client prints the
response and acknowledges it before both programs close.

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

    const message = try connection.receive();
    try connection.send(message.data, message.reliability);

    const acknowledgement = try connection.receive();
    if (!std.mem.eql(u8, acknowledgement.data, "ack")) return error.InvalidAcknowledgement;
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

`--protocol` and `--version` are required and must match the exact client build.
Check [Mojang's protocol metadata](https://mojang.github.io/bedrock-protocol-docs/changelog/).
For preview/beta 1.26.60.28 on Windows:

```powershell
.\zig-out\bin\minecraft.exe --protocol 2216 --version 1.26.60-beta.28 --identity nethernet-identity.der --trace
```

Connect through Add Server to `127.0.0.1:19132`. Keep the identity file between
runs. The Windows default accepts both IPv4 and IPv6.

With `--trace`, expect `GET /v1/join HTTP 200 application/json`, followed by
`POST /v1/join/{networkId} received`. A successful transport connection reaches
`[7/7] first Bedrock payload`. Live vanilla compatibility still needs testing.

For vanilla-facing applications, provide `status_provider` in
`EndpointListenerOptions`. GET returns JSON metadata, 503 when unavailable, or
500 when invalid. POST requires `Content-Type: application/sdp`.

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

Run `zig build bench` for benchmarks.

## License

[Apache-2.0](LICENSE).
