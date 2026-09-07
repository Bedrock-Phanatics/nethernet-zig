# Benchmarks

Measured on Windows x64 with Zig 0.16.0 ReleaseFast. These are single-run microbenchmarks using reusable buffers, not deployed network latency or throughput measurements. CPU scheduling and power state affect the results.

Discovery measurements include hexadecimal advertisement encoding, AES, and HMAC. Each operation runs 10,000 times.

| Payload bytes | Encode ns/op | Decode ns/op |
|---:|---:|---:|
| 32 | 228.2 | 258.1 |
| 64 | 277.1 | 342.7 |
| 128 | 391.8 | 510.8 |
| 256 | 624.0 | 845.6 |
| 512 | 1106.3 | 1504.8 |
| 1024 | 1997.9 | 2784.8 |
| 1400 | 2694.5 | 3768.0 |
| 8192 | 14819.7 | 21046.6 |

Discovery encoding and decoding perform no allocations after buffer initialization.

Framing plus reassembly measured 8.8 ns for 32 bytes, 28.5 ns for 1400 bytes, 179 ns for 8192 bytes, 9.85 microseconds for 262143 bytes, and 20.28 microseconds for 524288 bytes. A 128-byte queue push/pop measured 7.9 ns.

Run from the repository root:

~~~sh
zig build bench
~~~

These measurements exclude native SCTP, sockets, contention, and connection allocation. Full-network latency percentiles, concurrent-connection scaling, sustained throughput, native allocation profiling, and long-duration load testing remain unmeasured.

## Event wakeups versus polling

Run `zig build bench-wakeup` for a 500-packet bounded-queue comparison and a
one-second idle measurement for each strategy. Both use the same producer,
queue, mutex, and buffers. The old `sleep(1ms)` loop exists only as the benchmark
baseline. Arrival phase varies; latency runs from queue publication to receipt.
Reported columns are p50/p95/p99 nanoseconds, idle wait count, and process CPU
nanoseconds. Neither callback publication nor the queue allocates per packet.

Windows x64, Zig 0.16.0 ReleaseFast, single run:

| Strategy | p50 | p95 | p99 | Idle waits / second | Measured idle CPU |
|---|---:|---:|---:|---:|---:|
| 1 ms polling | 14.964 ms | 16.010 ms | 16.106 ms | 64 | 0 ns |
| Event-driven | 12.7 us | 24.3 us | 88.0 us | 1 | 0 ns |

The Windows scheduler rounded short sleeps substantially above 1 ms in this
run. Both idle CPU readings were below measurement resolution; zero does not
prove zero CPU cost. Wait counts demonstrate the reduction in idle wakeups.
These are local handoff measurements, not end-to-end WebRTC latency. Run on the
target OS and compare multiple runs before drawing performance conclusions.
Timing percentiles are reported rather than asserted in CI to avoid scheduler
noise causing failures. Functional tests cover notification races, cancellation,
queue exhaustion, deadline expiry, and real native/LAN/HTTP traffic.
