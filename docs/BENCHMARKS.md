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
