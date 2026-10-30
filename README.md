# NetherNet

A Zig implementation of Minecraft Bedrock's NetherNet transport, built on
[libdatachannel](https://github.com/paullouisageneau/libdatachannel).

Works with vanilla Bedrock 1.26.52 and [go-nethernet](https://github.com/df-mc/go-nethernet).

## Requirements

- Zig 0.17.0
- Git, CMake and a C/C++ toolchain
- Linux or Windows, x86_64

## Build

```sh
sh tools/setup-native.sh                                         # Linux
powershell -ExecutionPolicy Bypass -File tools/setup-native.ps1  # Windows
zig build -Doptimize=ReleaseSafe
```

The setup script builds a patched libdatachannel into `.deps/native`. Use `-Dnative-prefix=<path>`
to point at another build.

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

| API | Purpose |
| --- | --- |
| `EndpointListener` | HTTP signaling server, `accept` returns established connections |
| `dialEndpoint` | Connects to an HTTP signaling server |
| `LanListener`, `dialLan` | LAN discovery and signaling |
| `Connection` | `send`, `receive`, `poll`, `wait`, `shutdown`, `closeGracefully`, `bufferedAmount`, `diagnostics` |
| `Wakeup` | One wait across many connections via `connection.peer.subscribe` |
| `Callback` | `connection.setCallback` runs a function instead, for hosts with their own scheduler |
| `identity_issuer.Authority` | Verifies client identities against Minecraft's keys |
| `Peer.setNativeThreadPoolSize` | Native worker count, at most four by default |

Messages returned by `receive` and `poll` are borrowed until the next call. Poll a connection from
one thread, while `send`, `close` and `closeGracefully` are safe from any thread. A callback runs on
a native thread with the connection locked, so it should only hand the work off; once
`setCallback(null)` returns, none is running. `close` and `destroy` abort SCTP and drop anything it
still holds, while `shutdown` (non-blocking) and `closeGracefully` let it go out first.
`EndpointListener` can cap concurrent negotiations and open HTTP connections per client IP with
`maximum_negotiations_per_address` and `maximum_connections_per_address`. IPv6 clients count per /64
and loopback is exempt. `Authority.verifier()` downloads Minecraft's keys when it meets an unknown one,
while `cachedVerifier()` never waits and refreshes in the background, for threads that serve other
connections. Set `allow_anonymous = true` to accept clients without an identity, for testing.

When a connection's receive queue (`queue_bytes`, `queue_entries`) fills up, it stops reading SCTP
until half of it is drained, so a slow reader throttles its sender instead of losing the connection.
`callbackStats().receive_pauses` counts these pauses. If the peer closes the whole connection while
reading is paused, what SCTP had already accepted is handed over on the close into a spill queue
(`spill_bytes`, `spill_entries`) and read before the connection reports closed;
`callbackStats().spilled_messages` counts what went through it. Tearing a connection down sends a DTLS
close_notify, so the peer sees the close at once instead of when ICE consent expires.

## Networking

| Port | Protocol | Purpose |
| --- | --- | --- |
| 19132 | TCP | HTTP signaling |
| Negotiated | UDP | WebRTC, fixed with `port_range_begin`/`port_range_end` |
| 7551 | UDP | LAN discovery |

Every connection gets its own UDP socket by default. On Linux those sockets are served through
epoll, so the receive thread's work no longer grows with the connection count: with 100 to 1000
go-nethernet clients a socket per connection measured the same server CPU as the mux and better tail
latency. `.native = .{ .enable_ice_udp_mux = true }` shares one socket instead. On Windows the mux
measured slower than separate sockets, so profile your own setup. A client address is only bound to a
session after an authenticated ICE check, so reconnects and reused NAT ports reach the right session.
The mux is not yet verified against vanilla clients, so it stays opt-in. The shared socket asks for an
8 MiB buffer, so on Linux raise `net.core.rmem_max` and `net.core.wmem_max` to 8388608 before serving
many players with it, otherwise bursts overflow the default buffer.

## Examples

```sh
zig build
./zig-out/bin/minecraft --trace   # accepts a vanilla client on port 19132
./zig-out/bin/server              # echo server for ./zig-out/bin/client
```

## Tests

```sh
zig build test
zig build test-integration -Doptimize=ReleaseSafe
zig build fuzz
zig build stress -Doptimize=ReleaseFast -- --connections 100 --duration-ms 10000
sh tests/interop/run.sh            # needs Go
```

`tools/stress-diagnostics.sh asan|tsan|zig-tsan|valgrind` runs the stress harness under sanitizers
on Linux, or the integration tests with `NETHERNET_DIAGNOSTICS_STEP=test-integration`. `zig build echo-install` and `tests/interop/load` measure a server against go-nethernet
clients from another process.

## License

Apache-2.0. Native dependencies are listed in [NOTICE](NOTICE).
