# NetherNet

NetherNet is a Minecraft Bedrock transport library for Zig 0.16. It provides
LAN discovery, HTTP signaling, authenticated SDP exchange, and reliable or
unreliable WebRTC DataChannels through libdatachannel.

## Features

- Endpoint and LAN connection flows.
- Reliable and unreliable message transport.
- Bounded queues, signaling, candidates, and message sizes.
- Native WebRTC integration with pinned libdatachannel and Mbed TLS versions.

## Source layout

The library is organized by responsibility. Public consumers import only
`src/root.zig`; `src/core.zig` is the native-free entry point used by protocol
tests and fuzzing.

```text
src/
├── auth/       identity tokens, SDP assertions, and ICE credentials
├── discovery/  LAN discovery codec, client, and server advertisements
├── endpoint/   HTTP and LAN connection flows
├── internal/   private queue and wakeup primitives
├── protocol/   signaling values and stable wire error codes
└── transport/  connection state, framing, and libdatachannel ownership
```

Files under `internal/` are implementation details and are not part of the
compatibility surface. Tests are split into native-free protocol tests,
integration tests backed by real WebRTC peers, fuzz targets, and benchmarks.

## Build

Requires **Zig 0.16.0**, Git, CMake, and a C/C++ toolchain.

```sh
# Linux/macOS
sh tools/setup-native.sh
zig build -Doptimize=ReleaseSafe
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File tools/setup-native.ps1
zig build -Doptimize=ReleaseSafe
```

Use `-Dnative-prefix=/path/to/prefix` to provide an existing patched native
installation.

## API

| API | Purpose |
| --- | --- |
| `dialEndpoint` | Connect through HTTP signaling. |
| `EndpointListener` | Accept HTTP-signaled connections. |
| `dialLan` | Connect through LAN discovery/signaling. |
| `LanListener` | Accept LAN connections. |
| `Connection` | Send, receive, inspect, and close a connection. |

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
    std.debug.print("{s}\n", .{message.data});
}
```

See [`examples/client.zig`](examples/client.zig) and
[`examples/server.zig`](examples/server.zig) for complete examples.

## Verification

```sh
zig fmt --check build.zig build.zig.zon src tests examples
zig build test
zig build fuzz -Dfuzz-iterations=100000
zig build test-integration -Doptimize=ReleaseSafe
zig build stress-smoke -Doptimize=ReleaseSafe
```

Coverage-guided fuzzing is run on Linux CI with Zig's `--fuzz` mode.

## License

Apache-2.0. See [LICENSE](LICENSE).
