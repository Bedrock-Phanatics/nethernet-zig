# NetherNet

A Zig implementation of Minecraft Bedrock's NetherNet transport, built on libdatachannel.

- HTTP signaling (`/v1/join`) and LAN discovery
- Signed identities verified against Minecraft's authorization keys
- Reliable and unreliable channels with fragmentation and reassembly
- Bounded memory, backpressure, and connection diagnostics

Tested with vanilla Bedrock 1.26.52 and against [go-nethernet](https://github.com/df-mc/go-nethernet).

## Requirements

- Zig 0.16.0
- Git, CMake, and a C/C++ toolchain
- Windows x86_64 or Linux x86_64

## Build

```sh
sh tools/setup-native.sh                                  # Linux
powershell -ExecutionPolicy Bypass -File tools/setup-native.ps1  # Windows
zig build -Doptimize=ReleaseSafe
```

Use `-Dnative-prefix=<path>` to point at an existing libdatachannel build.

## Usage

```zig
var authority = nethernet.identity_issuer.Authority.init(gpa, io);
defer authority.deinit();
try authority.refresh();

const listener = try nethernet.EndpointListener.listen(gpa, io, address, .{
    .connection = .{
        .server_identity_key = try nethernet.identity_file.loadOrCreate(io, gpa, "identity.der"),
        .verify_client = authority.verifier(),
    },
    .status_provider = .{ .context = &status, .get = Status.get },
});
defer listener.destroy();

const connection = try listener.accept();
defer connection.destroy();

const message = try connection.receive();
try connection.send(message.data, message.reliability);
```

Keep the identity file across restarts so players only confirm the server once.
`allow_anonymous = true` accepts clients without an identity, for testing.

## Examples

| Example | Description |
| --- | --- |
| [server.zig](examples/server.zig) / [client.zig](examples/client.zig) | Local echo server and client |
| [minecraft.zig](examples/minecraft.zig) | Accepts a vanilla client and reports each transport stage |

```sh
./zig-out/bin/minecraft --trace
```

Add a server at your machine's address, port `19132`, and join. The example
stops after the client's first packet since it does not implement gameplay.

## Networking

| Port | Protocol | Purpose |
| --- | --- | --- |
| 19132 | TCP | HTTP signaling |
| Negotiated | UDP | WebRTC traffic, fixed with `port_range_begin`/`port_range_end` |
| 7551 | UDP | LAN discovery |

## Tests

```sh
zig build test
zig build test-integration -Doptimize=ReleaseSafe
zig build fuzz
sh tests/interop/run.sh   # requires Go
```

## License

[Apache-2.0](LICENSE)
