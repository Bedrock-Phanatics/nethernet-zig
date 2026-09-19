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