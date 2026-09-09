# nethernet-zig notes

## Public API

The main entry points are:

- `dialEndpoint` and `EndpointListener` for HTTP signaling.
- `Discovery`, `dialLan`, and `LanListener` for LAN discovery and signaling.
- `Connection.create`, `start`, `applySignal`, and `pollNegotiation` for custom signaling.
- `Connection.send`, `receive`, and `poll` for transport traffic.

`Connection` operations use a single application owner. Copy received data if it must survive another poll. Keep allocators, I/O contexts, discovery instances, and identity callback contexts alive for every object borrowing them.

## Shutdown

`close()` aborts immediately and is idempotent. `closeGracefully()` stops new sends and waits for libdatachannel's outgoing buffered amount to reach zero. It force-closes on cancellation, native failure, or `graceful_shutdown_timeout_ms`, which defaults to two seconds. Call `destroy()` exactly once after use.

## Important limits

Defaults are intentionally bounded and configurable through connection or native options:

- 16 MiB application message size.
- 1 MiB native callback queue with 512 entries.
- 32 remote ICE candidates across bundled SDP and trickle ICE.
- One required `ReliableDataChannel` and one `UnreliableDataChannel`.
- 30-second incomplete-message reassembly timeout.
- 16 MiB native buffered-send allowance.

Unknown or duplicate DataChannels are closed immediately and fail the peer. Signaling and reliable callback events fail closed when they cannot be retained. Unreliable dropping under queue pressure remains opt-in.

## Identity and signaling

Servers create short-lived ES384 identities unless one is supplied. Clients bind the signed identity to the SDP DTLS fingerprint. Keep `allow_anonymous` disabled for authenticated deployments and use `verify_client` to apply issuer or account policy.

LAN discovery encryption is protocol compatibility, not authentication. Treat discovery metadata and endpoints as untrusted.

## Testing and diagnostics

`zig build` runs core and native tests. Use `zig build bench` for codec, framing, receive-copy, and queue-pressure measurements. `zig build bench-memory` reports bounded Zig buffer reservations at several connection counts.

The reusable real-transport harness accepts connection count, duration or message count, payload size, rate, burst size, reliability, and churn options:

```sh
zig build stress -Doptimize=ReleaseSafe -- --connections 100 --duration-ms 600000 --payload-size 8192 --rate 20
```

Use `--profile rollover` for the manual single-association SCTP rollover run. On Linux, `sh tools/stress-diagnostics.sh asan`, `tsan`, or `valgrind` rebuilds or runs the native diagnostics as appropriate.

Heavy stress testing is never scheduled automatically. The GitHub `transport stress` workflow runs only when manually dispatched.