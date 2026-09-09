# nethernet-zig

A Minecraft Bedrock NetherNet networking library for Zig 0.16.

- LAN discovery and signaling, including encrypted advertisements.
- HTTP/HTTPS endpoint dialing and an HTTP endpoint listener.
- ES384 identity tokens and signed SDP fingerprint assertions.
- Reliable ordered and unreliable unordered WebRTC messages.
- Bounded queues, explicit ownership, configurable limits, and reusable buffers.

WebRTC uses **libdatachannel 0.24.5** with a local bounds patch and **Mbed TLS 3.6.7**.

## Build

Run all commands from the repository root.

### Windows

Requires Zig **0.16.0**, Git, and Python:

~~~powershell
./tools/setup-native.ps1
zig build
~~~

Setup keeps downloaded sources, CMake, Ninja, and native build output under `.deps/`. The build compiles the tests and installs examples and the native DLL into `zig-out/bin/`.

### Linux and macOS

The POSIX setup script requires Zig 0.16.0, Git, Python 3, CMake, and a C/C++ toolchain:

~~~sh
sh tools/setup-native.sh
zig build
~~~

These platforms have not been runtime-validated. Ensure the installed libdatachannel shared library is discoverable by your platform's loader when running installed executables.

To use an existing installation of the patched native dependency:

~~~powershell
zig build -Dnative-prefix=/absolute/path/to/native
~~~

## Run the echo example

After building, start the listener in one terminal:

~~~powershell
./zig-out/bin/echo.exe
~~~

In a second terminal, also in this directory:

~~~powershell
./zig-out/bin/client.exe
~~~

The client prints `received: hello`. These examples bind to loopback port 18750, exchange one reliable message, and exit. The listener allows anonymous clients for this local demonstration.

Source: [client.zig](examples/client.zig) · [echo.zig](examples/echo.zig)

## Use the library

The public module is `nethernet`. Add this directory as a dependency in your application's package manifest, then import it in your build:

~~~zig
const dependency = b.dependency("nethernet", .{
    .target = target,
    .optimize = optimize,
    .@"native-prefix" = native_prefix,
});
exe.root_module.addImport("nethernet", dependency.module("nethernet"));
~~~

The native prefix is the absolute installation path of the patched native dependency. Distribute its shared library and applicable license notices with your application.

A minimal endpoint client:

~~~zig
const std = @import("std");
const nethernet = @import("nethernet");

pub fn main(init: std.process.Init) !void {
    const connection = try nethernet.dialEndpoint(
        init.gpa, init.io, "http://127.0.0.1:18750", 123, .{},
    );
    defer connection.destroy();

    try connection.send("hello", .reliable);
    const message = try connection.receive();
    std.debug.print("received {s}\n", .{message.data});
}
~~~

Connections have one application owner. Received data borrows connection storage until the next poll/receive. Closing is idempotent; call `destroy()` exactly once. See the [API and ownership guide](docs/GUIDE.md) before integrating custom signaling or authentication.

## Test and benchmark

| Command | Purpose |
|---|---|
| `zig build test` | Core tests; no native dependency required |
| `zig build test-native` | Real WebRTC, LAN, HTTP, and UDP fault-relay tests |
| `zig build fuzz -Dfuzz-iterations=100000` | Fuzz corpus and deterministic malformed-input campaign |
| `zig build test -Doptimize=ReleaseSafe` | Core tests with release safety checks |
| `zig build test-native -Doptimize=ReleaseSafe` | Native suite with release safety checks |
| `zig build bench` | Codec, framing, and queue microbenchmarks |
| `zig fmt --check build.zig build.zig.zon tests.zig native_tests.zig src tests bench examples` | Formatting check |

Coverage-guided fuzzing is unavailable on Windows in Zig 0.16. The ordinary test suite runs the fuzz corpus and deterministic malformed-input tests.

## Directory guide

| Path | Contents |
|---|---|
| [src/root.zig](src/root.zig) | Public API exports |
| [src/](src/) | Production library code and colocated unit tests |
| [tests/](tests/) | Core, fuzz, wire, and native integration suites and fixtures |
| [bench/](bench/) | Performance benchmarks |
| [examples/](examples/) | Small applications using the public module |
| [tools/](tools/) | Native setup and bounds patch |
| [docs/GUIDE.md](docs/GUIDE.md) | API, ownership, authentication, and resource limits |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | Measurements, methodology, and limitations |
| [docs/AUDIT.md](docs/AUDIT.md) | Compatibility review and validation scope |
| [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md) | Native dependencies and licensing |

Local validation covers Windows x64. Public TURN, long-running production load, native leak/race instrumentation, and non-Windows runtimes still need validation.
