# nethernet-zig

A bounded Minecraft Bedrock NetherNet transport library for Zig 0.16.

It provides LAN discovery, HTTP signaling, authenticated SDP exchange, and reliable or unreliable WebRTC DataChannels through libdatachannel. Queues, message sizes, ICE candidates, listeners, and negotiation work are explicitly bounded.

## Requirements

- Zig 0.16.0
- Git and Python
- CMake and a C/C++ toolchain on Linux or macOS

Native dependencies are pinned to libdatachannel 0.24.5 and Mbed TLS 3.6.7.

## Build

Windows:

```powershell
./tools/setup-native.ps1
zig build
```

Linux or macOS:

```sh
sh tools/setup-native.sh
zig build
```

Use `-Dnative-prefix=/path/to/prefix` when supplying an existing patched libdatachannel installation.

## Usage

Add the package module to your executable:

```zig
const dependency = b.dependency("nethernet", .{
    .target = target,
    .optimize = optimize,
    .@"native-prefix" = native_prefix,
});
exe.root_module.addImport("nethernet", dependency.module("nethernet"));
```

A minimal endpoint client:

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

Connections have one application owner. Received slices remain valid until the next `poll()` or `receive()`. `close()` is immediate, `closeGracefully()` drains buffered sends up to its configured deadline, and `destroy()` must be called exactly once.

## Commands

```sh
zig build test
zig build test-native
zig build -Doptimize=ReleaseSafe test
zig build test-native -Doptimize=ReleaseSafe
zig build fuzz -Dfuzz-iterations=100000
zig build bench
zig build stress-smoke -Doptimize=ReleaseSafe
```

The larger transport stress action is manual-only in GitHub Actions. Local production-scale runs use `zig build stress -- [options]`.

See [docs/README.md](docs/README.md) for API and operational notes and [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md) for dependency licenses.