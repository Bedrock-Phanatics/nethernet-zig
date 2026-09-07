# Using the Zig library

All commands and code paths are relative to the repository root.

## Dependency and build model

Target Zig 0.16.0. `std.Io` supplies sockets, clocks, structured concurrency, and cancellation. No old `std.net` or `std.time.Timer` APIs are used.

`tools/setup-native.ps1` builds pinned libdatachannel and Mbed TLS with Zig's C/C++ compiler on Windows. `tools/setup-native.sh` is the POSIX counterpart. The native installation prefix defaults to `.deps/native`; override it with `-Dnative-prefix`. Distribute the native shared library alongside your application. Windows installs copy the DLL into `zig-out/bin`.

A consuming `build.zig` can use:

```zig
const dependency = b.dependency("nethernet", .{
    .target = target,
    .optimize = optimize,
    .@"native-prefix" = native_prefix,
});
exe.root_module.addImport("nethernet", dependency.module("nethernet"));
```

## API and ownership

- `dialEndpoint(allocator, io, origin, network_id, options)` returns a ready owned connection. HTTP origins require an explicit port, including `:80`/`:443`. HTTP signaling gathers complete SDP and disables trickle ICE.
- `EndpointListener.listen(allocator, io, address, options)` creates an HTTP listener. `accept()` transfers an owned connection. HTTPS server termination belongs to the hosting layer/reverse proxy.
- `Discovery.listen(allocator, io, address, options)` binds a UDP discovery socket. `poll(timeout_ms)` drives receive, advertisements, signaling, and expiration. Cache responses borrow memory until refresh/expiration. `request(address)` sends an immediate discovery query.
- `LanListener.listen(allocator, discovery, options)` borrows discovery. `accept()`/`pollAccept()` drive all pending LAN negotiations. `dialLan(allocator, discovery, remote_network_id, options)` connects to a discovered address.
- `Connection.send(data, reliability)` copies input into native send storage before returning. Caller may reuse input. `error.Backpressure` means nothing from that message was submitted; retry after servicing the connection. A native failure after partial submission closes the connection.
- `Connection.receive()` returns a message from either channel, tagged with reliability. `poll()` exposes both messages and signals for custom signaling. Returned slices borrow internal storage until the next poll/receive. Copy with your allocator when retaining messages.
- `Connection.create`, `start`, `applySignal`, and `pollNegotiation` support application-defined signaling without interfaces, tasks, subscriptions, or inherited object graphs. Route using both `connection_id` and `network_id`.
- `localAddress()`/`remoteAddress()` borrow connection-owned identity strings. `state()`, `ready()`, and byte/message counters expose basic status.
- `close()` is idempotent. `destroy()` releases allocations and must be called exactly once. Accepted connections survive listener close; unaccepted connections and incomplete negotiations are destroyed by the listener.

Connection and LAN/discovery public operations have one application owner. Do not concurrently call `destroy` and another public operation. Native callbacks only copy into a mutex-protected bounded queue or update state; user code is never called under that mutex. Native deletion waits for callbacks, outside the mutex, before releasing memory.

The HTTP listener uses a fixed number of negotiation workers, not one worker per established WebRTC connection. Its allocator and any identity verifier callbacks must support concurrent calls. `init.gpa` and `std.testing.allocator` satisfy the tested use cases. Cancel/close the listener before releasing `io`, allocator, or callback context. Accepted connections can outlive the listener because they use the caller's allocator directly.

## Authentication

Server connections generate a fresh one-minute ES384 identity unless `ConnectionOptions.identity` supplies one. The application owns supplied token/domain strings and must keep them alive through negotiation. `identity.serverToken` returns allocated token memory; free it with the same allocator. Key pairs are value types.

Clients verify the server token's self-signature and detached DTLS fingerprint assertion. Servers verify cpk time claims and proof of fingerprint possession. `allow_anonymous` defaults to false. Possession of a cpk alone is not issuer authentication: configure `verify_client` to validate your trusted issuer/account policy. The callback may supply an alternative public key, whose fingerprint proof is checked again.

The interoperable ES384 key is P-384. PKIX/SPKI base64 and P-384 EC JWK cpk forms are supported. RS256 client-token headers may be inspected for cpk, with issuer verification delegated to the application; this is not an RS256 verifier.

SDP assertions contain a nested JSON string, standard base64, and detached JWS over the unique fingerprint list in appearance order. Time-claim arithmetic widens before comparison. Transport timers use `Clock.awake`; only JWT timestamps use real time.

`credentials.Urls.init` flattens STUN/TURN credentials into bounded, percent-encoded native URLs. Set `options.native.ice_servers = urls.values` and keep `urls` alive through connection creation. Credentials retrieval/refresh is application-owned; no global provider or cache is installed.

## Protocol authority and deliberate hardening

| Area | Behavior |
|---|---|
| Reliable channel | `ReliableDataChannel`, ordered SCTP reliability |
| Unreliable channel | `UnreliableDataChannel`, unordered, zero retransmissions |
| Framing | One-byte remaining-segment countdown; 262,143 payload bytes per outgoing segment; at most 255 outgoing segments |
| Empty sends | Return successfully without emitting a frame |
| Reassembly | One sequential group per channel; invalid countdown closes connection; unreliable countdown must be zero |
| Discovery | IDs 0/1/2; little-endian fields; SHA256-derived vanilla key; AES-256 ECB/PKCS7 with HMAC-SHA256 over plaintext |
| Discovery compatibility | Inclusive and historical exclusive payload lengths; message strings consume trailing bytes; advertisement bytes are lowercase hex |
| Advertisements | Version 6, signed zigzag varints, little-endian counts, RakNet pong conversion |
| HTTP | `/v1/join` probe and `/v1/join/{networkId}` SDP POST, one MiB body cap |
| Disconnect | Native `disconnected` is recoverable; failed/closed terminate connection |
| Timing | 15s negotiation, 10s connection, 2s discovery tick, 15s discovered-peer expiration |

ACKs, sequence rollover, RTT, retransmissions, packet-level fragmentation, congestion, and UDP MTU are WebRTC/SCTP responsibilities. There are no fabricated NetherNet ACK packets or additional sequence headers. The 262,143-byte message segment limit is not a UDP MTU.

Intentional hardening: overflowed five-byte varints are rejected; reassembly expires after a configurable 30s; HTTP origins reject userinfo/query/fragment; native callback traffic has an aggregate byte limit; native oversized SCTP messages fail instead of truncating. The checked-in native patch also corrects unconditional resizing of deprecated partial-PPID buffers. These changes do not alter valid tested wire messages.

## Resource limits and memory

Default native callback queue: 4 MiB and 512 entries, shared by signaling and channel fragments. Queue exhaustion fails the peer. Default message cap: 16 MiB. Reassembly grows geometrically on demand, capped at the configured maximum, and reuses capacity. Outgoing native buffered data is capped before submission, including fragment headers. Server counts, HTTP negotiation workers, and pending accepts are bounded.

A connection initially owns about 5.3 MiB of queue/scratch/send buffers plus small structs and native WebRTC state. Reassembly capacity is additional and retained for reuse until destroy. This is a deliberate bounded preallocation tradeoff, not a claim of minimal idle memory. Tune `native.queue_bytes`/`queue_entries` for workload needs (queue bytes must fit at least one maximum segment). No allocation occurs in the Zig native message callback, discovery codec, pure framing codec, or byte-ring operations.

The Windows UDP timeout path uses structured cancellation when Zig 0.16 reports `ConcurrencyUnavailable` for concurrent UDP batches. The fallback is isolated in discovery and does not affect WebRTC's native UDP hot path.

## Validation commands

```powershell
zig fmt --check build.zig src examples
zig build
zig build test --summary all
zig build test-native --summary all
zig build test -Doptimize=ReleaseSafe
zig build test-native -Doptimize=ReleaseSafe
zig build bench
```

Native tests include a strictly loopback UDP fault relay with loss, duplication, latency, jitter, and reordering. The relay changes encrypted datagrams, not application frames. The suite verifies exact reliable payload reconstruction and duplicate suppression.

`zig build test --fuzz=10000` enables coverage-guided fuzzing on supported hosts. Zig 0.16 refuses this command on Windows. Ordinary tests still execute the fuzz corpus and a deterministic 20,000-input campaign plus decoder-specific random tests. Testing-allocator suites inject every allocation failure into identity creation/verification, credentials, discovery creation, connection creation, and reassembly growth.

Local validation does not establish public TURN/TLS deployment compatibility, long-running load stability, native heap leak freedom, or Linux/macOS runtime correctness. Native allocations are outside Zig's testing allocator. The project includes native bounds hardening and exercised shutdown paths, but has not had an independent security audit.
