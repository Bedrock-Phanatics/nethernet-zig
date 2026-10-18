# Performance baseline

Phase 1 audit of nethernet 1.1.0 (libdatachannel 0.24.5 + MbedTLS 3.6.7, Zig 0.16.0).
Every number below was measured on the machine described here; nothing is extrapolated.

## Environment

- AMD Ryzen 5 5500 (6 cores, 12 threads), 15.9 GB RAM
- Windows 11 10.0.26200, native
- Linux: Ubuntu on WSL2 (kernel 6.6.87.2) on the same machine, `perf` 6.8
- Loopback only: client and server peers live in the same process

## Reproducing

```sh
zig build bench
zig build stress -Doptimize=ReleaseFast -- <options>
zig build stress -Doptimize=ReleaseFast -Dtracy=true -- <options>   # then tracy-capture
```

The realistic workload used throughout:

```sh
--connections 100 --duration-ms 10000 --rate 20 --burst 4 --max-in-flight 64 \
  --payload-size 8192 --profile bedrock --reliability mixed
```

`--profile bedrock` draws sizes from 32 B to 8 KiB, mostly under 128 B. `--reliability mixed`
sends every tenth message unreliably. Each pair is one client and one server connection, and
each round trip is a client send, a server echo and the client receive.

New harness options: `--wait wakeup|sleep`, `--idle`, `--rtc-threads N`, `--ice-udp-mux`.
New report fields include API-thread versus background CPU, CPU per round trip and per KiB,
RSS and Zig heap per pair, allocations per round trip, creation, teardown and reconnect times,
queue entry high water, sender backpressure, and Zig heap retained after teardown.

## Harness correction

The old harness slept 1 ms whenever a pass made no progress. On Windows that sleep lasts up to
one 15.6 ms timer tick, so it measured the timer, not the transport. The harness now subscribes
every peer to one `Wakeup` and waits with a deadline; `--wait sleep` keeps the old behavior.

| 100 pairs, Windows ReleaseSafe | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| sleep (3 runs, before) | 2.26-2.29 ms | 14.3-14.4 ms | 16.1-16.2 ms |
| wakeup (3 runs) | 1.38-1.39 ms | 2.11-2.12 ms | 2.86-3.48 ms |

With two pairs the difference is 31 ms versus 0.31 ms p50.

## Connection count

Windows, ReleaseSafe, realistic workload, two runs each:

| Pairs | p50 | p95 | p99 | max | CPU |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.32-0.34 ms | 0.48 ms | 0.60-0.63 ms | 1.1 ms | 0-3% |
| 10 | 0.29-0.30 ms | 0.50-0.52 ms | 0.88-0.95 ms | 2.4 ms | 5-17% |
| 50 | 0.84-0.85 ms | 1.31-1.33 ms | 1.91-1.94 ms | 7.6 ms | 62-149% |
| 100 | 1.39-1.40 ms | 2.12-2.21 ms | 2.90-3.24 ms | 7.3 ms | 42-140% |
| 200 | 0.34-0.37 ms | 0.75-1.25 ms | 9.5-12.2 ms | 46 ms | 250% |
| 400 | 0.91-0.92 ms | 3.7-4.0 ms | 34-52 ms | 120 ms | 348-356% |

Linux, ReleaseFast, realistic workload, default and two libdatachannel workers:

| Pairs | Workers | p50 | p95 | p99 | CPU |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 12 | 0.43 ms | 0.73 ms | 1.12 ms | 20% |
| 10 | 2 | 0.40 ms | 0.52 ms | 0.68 ms | 14% |
| 100 | 12 | 0.46-0.47 ms | 2.52-2.73 ms | 3.3-5.5 ms | 192-197% |
| 100 | 2 | 0.44-0.45 ms | 0.52-0.54 ms | 0.72-0.76 ms | 138-139% |
| 200 | 12 | 6.6 ms | 17.9 ms | 26.4 ms | 327% |
| 200 | 2 | 0.50 ms | 0.71 ms | 3.1 ms | 213% |
| 400 | 12 | 56 ms | 99 ms | 116 ms | 387% |
| 400 | 2 | 0.80 ms | 12.1 ms | 100 ms | 240% |

Latency degrades between 100 and 200 pairs with the default worker count and between 200 and
400 pairs with two workers. Windows CPU at 50 and 100 pairs is bimodal between identical runs;
two workers removed most of the spread (100 pairs: 36-40%).

## Saturation

`--rate 0 --burst 64 --max-in-flight 64 --profile fixed`, ReleaseFast:

| Platform | Pairs | Size | Workers | Round trips/s | MiB/s | CPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Windows | 1 | 64 B | 12 / 2 | 13,022 / 15,409 | 1.6 / 1.9 | 332% / 206% |
| Windows | 10 | 64 B | 12 / 2 | 13,528 / 19,676 | 1.7 / 2.4 | 350% / 252% |
| Windows | 1 | 1200 B | 12 / 2 | 6,960 / 5,607 | 15.9 / 12.8 | 323% / 166% |
| Windows | 1 | 1200 B unreliable | 12 / 2 | 6,936 / 5,666 | 15.9 / 13.0 | 321% / 165% |
| Windows | 1 | 64 KiB | 12 / 2 | 328 / 182 | 41.0 / 22.7 | 298% / 163% |
| Windows | 1 | 1 MiB, 1-4 in flight | 12 | 17-18 | 33-36 | |
| Linux | 1 | 64 B | 12 / 2 | 9,987 / 9,019 | | 345% / 179% |
| Linux | 10 | 64 B | 12 / 2 | 31,747 / 45,139 | | 409% / 256% |

The API thread runs at 88-99% in every 64 B case, so one polling thread is the ceiling for
small messages. Fewer workers help many small messages and hurt bulk transfer.

## Idle

100 connected pairs with no traffic for 15 s: 0.8-1.2% CPU on Windows and 2.8% on Linux,
about 0.01-0.03% per pair, with two to six harness loop iterations in total.

## Memory

| Measurement | Value |
| --- | ---: |
| Zig heap per pair after setup | 3.69 MB (1.84 MB per connection) |
| RSS per pair, Windows ReleaseSafe, 50-400 pairs | 4.26-4.38 MB |
| RSS per pair, Windows ReleaseFast | 0.68 MB |
| RSS per pair, Linux ReleaseSafe / ReleaseFast | 4.27 MB / 0.59 MB |
| RSS growth, 100 pairs, fixed 8 KiB, 20 s, ReleaseFast | +235 MB (+1.17 MB per connection) |
| Zig heap retained after teardown, with and without 345 reconnects | 0 B |
| Zig allocations per round trip at steady state | 0 |

Each connection preallocates a 1 MiB receive ring, 8 KiB of ring entries and three 256 KiB
scratch buffers. Safe builds fill new allocations with 0xAA, so all of it is resident from the
start. In fast builds the ring becomes resident as traffic wraps it, which the 8 KiB run shows
after a few seconds. Realistic runs never queued more than one entry or 16 KiB.

## Setup, teardown and churn

| Measurement | Windows ReleaseSafe | Windows ReleaseFast | Linux ReleaseFast |
| --- | ---: | ---: | ---: |
| Create 100 pairs | 306-311 ms | 208-211 ms | 221-233 ms |
| Negotiate 100 pairs | 636-641 ms | 640-648 ms | 642-727 ms |
| Destroy 100 pairs | 91-95 ms | 41-43 ms | 80-104 ms |

Churn with 10 pairs reconnecting every 200 round trips: 631 reconnects in 15 s, 31 ms mean
negotiation, 0.24 ms mean teardown, no failures.

## Tracy zones

100 pairs, realistic workload, Windows ReleaseFast, 10 s:

| Zone | Count | Mean | Max |
| --- | ---: | ---: | ---: |
| `peer.send` | 39,970 | 41.8 us | 743 us |
| `rtcSendMessage` | 39,970 | 41.1 us | 743 us |
| `rtcGetBufferedAmount` | 39,970 | 409 ns | 38 us |
| `native.onMessage` | 39,970 | 895 ns | 40 us |
| `peer.enqueue` (lock held) | 39,970 | 667 ns | 36 us |
| `peer.enqueue.lock` (acquire) | 39,912 | 71 ns | 39 us |
| `peer.notify` | 42,775 | 132 ns | 8.5 us |
| `connection.poll` | 1,419,986 | 203 ns | 1.5 ms |
| `peer.poll.lock` (acquire) | 1,415,701 | 17 ns | 17 us |
| `peer.dequeue` | 1,411,656 | 19 ns | 64 us |
| `connection.reassemble` | 39,964 | 84 ns | 25 us |
| `peer.close` | 200 | 129 us | 1.0 ms |

Most polls find nothing: the harness polls every connection after each wakeup. Peers signal
1.07 times per received message.

## Linux profile

`perf record -D 2000 -F 1999 -g`, 100 pairs, realistic workload, steady state only:

| Thread | Share |
| --- | ---: |
| libdatachannel workers (`RTC worker`) | 48.5% |
| API thread | 30.8% |
| libjuice poll thread | 18.2% |
| usrsctp timer | 2.5% |

| Library | Share |
| --- | ---: |
| libdatachannel (with usrsctp, libjuice, MbedTLS) | 50.0% |
| libc (malloc, free, mutexes, clock_gettime) | 17.0% |
| nethernet and harness | 16.4% |
| kernel, unattributed | 8.1% |
| vDSO clock reads | 4.4% |
| libstdc++ | 3.7% |

Largest symbols: `Connection.pollInternal` 13.1%, libjuice `conn_poll_process` and friends 8%,
malloc and free 5-6%, mutex lock and unlock 4%, clock reads 4.5%, then a long tail of SCTP,
ChaCha20-Poly1305 and `std::function` dispatch. During setup, P-384 identity work in Zig and
MbedTLS P-256 for per-peer DTLS certificates dominate.

## Data path

Receive, per fragment: usrsctp copies into a new `std::vector`, libdatachannel wraps it in a
`shared_ptr` and dispatches it through its worker pool, the message callback takes the global
C API mutex for the user pointer, then nethernet locks the peer twice (channel lookup, then
enqueue), copies into the ring and signals both wakeups while still holding the lock. `poll`
locks the peer three times (negotiation check, closed check, pop) and copies out of the ring.
A single fragment is then returned without another copy; multi-fragment messages are copied
into the reassembly buffer.

Send, per fragment: three peer or send locks, one `rtcGetBufferedAmount` and one
`rtcSendMessage`, each taking libdatachannel's global C API mutex. nethernet copies the
payload behind the one-byte header, libdatachannel copies it again into a `std::vector`, and
usrsctp, DTLS and the UDP send all run synchronously on the calling thread.

Every incoming packet becomes a task on libdatachannel's single-mutex worker pool, which spawns
one worker per hardware thread by default.

## Bottlenecks

Ranked by measured impact:

1. **libdatachannel worker oversubscription.** Twelve workers share one mutex and condition
   variable. Two workers cut Linux CPU by 29% and p99 from 3.4 ms to 0.73 ms at 100 pairs,
   moved the degradation point past 200 pairs, and raised 10-pair saturation by 42-46% on both
   platforms. Bulk transfer prefers more workers.
2. **Native per-message cost.** About 75-85% of process CPU is in native threads, and
   `rtcSendMessage` averages 41 us on the API thread. Allocation, mutexes, clock reads and
   task dispatch dominate rather than cryptography.
3. **No readiness signal.** A shared `Wakeup` says something happened, not where, so a server
   polls every connection per wakeup. That is 13% of all CPU at 100 pairs on Linux and pins
   the API thread at 400 pairs on Windows, where p99 stays at 35-55 ms with any worker count.
4. **Preallocated per-connection buffers.** 1.84 MB of Zig heap per connection, resident
   immediately in safe builds and resident under traffic in fast builds.
5. **Reliable overflow is fatal.** More than 1 MiB of unread reliable data fails the
   connection instead of applying backpressure. Reproduced with 64 x 1 MiB messages in flight.
6. **Setup cost.** Creating a pair takes 2.1-3.1 ms, mostly P-384 identity work and per-peer
   DTLS certificate generation, and negotiating 100 pairs in one process takes about 640 ms.
7. **Zig locking and copies.** Two locks per received message, three per poll, a wake syscall
   under the peer lock, and two receive copies. Uncontended today (71 ns mean acquire), so this
   matters only after the items above.
8. **Queue scans.** The per-poll signal scan costs 23, 183 and 729 ns with 16, 128 and 512
   queued fragments, and priority pops shift queued bytes one at a time. Negligible at the
   observed occupancy of one entry.
9. **libjuice poll mode.** 18% of CPU on its poll thread, scanning every agent per wakeup. UDP
   mux could avoid it but does not negotiate between two peers in one process, so it is
   untested here.

## Plan

In expected order of benefit:

1. Choose the worker count deliberately. `Peer.setNativeThreadPoolSize` exists now; measure a
   default of two to four on Linux and Windows at 400 and 1,000 pairs and for bulk transfer.
2. Add a ready list. Peers push themselves onto a bounded, deduplicated per-listener queue from
   their callbacks, and a server-side `poll` dispatches only ready connections, with a deadline
   heap for timeouts in the style of raknet-zig's `poll`, `nextDeadline` and `processTimers`.
3. Switch reliable receive to libdatachannel's pull API (`rtcSetAvailableCallback` and
   `rtcReceiveMessage`). SCTP then applies backpressure instead of failing, the ring and one
   copy disappear, and memory per connection drops by about 1 MiB. Unreliable data and signals
   keep a small bounded queue.
4. Grow buffers on demand up to their limits, shrink them when idle, and size scratch buffers
   to the negotiated message size.
5. Cut native calls per send: track buffered amount from callbacks instead of calling
   `rtcGetBufferedAmount`, and avoid the extra payload copy where the API allows.
6. Reduce setup cost: share one DTLS certificate across peers through `certificatePemFile` and
   reuse server identity tokens within their validity window.
7. Merge the two receive-path locks, signal after unlocking, and keep a signal count in the
   queue so polls stop scanning.
8. Evaluate libjuice UDP mux with peers in separate processes.

## Reference implementations

- HashimTheArab/go-nethernet `lunar` is upstream df-mc/go-nethernet plus discovery changes:
  vanilla counts the length prefix inclusively, and lunar no longer validates it. nethernet
  writes the inclusive length and accepts both, with HMAC covering integrity.
- Upstream picks the media default candidate by reachability (relay, then srflx, then host),
  while libdatachannel uses the best host candidate, preferring IPv4. Vanilla clients connect
  with both; no change made.
- Upstream honors the remote `max-message-size` and caps messages at 255 segments, citing
  vanilla. nethernet honors the same attribute and accepts 256 segments by design (commit
  775af8e). The 256th segment is only reachable with a negotiated size far below vanilla's.
- Upstream starts SCTP with a cancellable context and closes transports asynchronously after a
  remote error. libdatachannel handles SCTP startup internally, and nethernet already bounds
  negotiation with timeouts and makes `close` wait for native deletion.
- Upstream rejects duplicate connection IDs and errors when no local candidates were gathered;
  nethernet's `NoLocalIceCandidate` covers the latter.
- No CPU or memory optimizations in either Go branch apply to this design.
- raknet-zig contributes the listener-driven `poll` with borrowed payloads, a deadline heap,
  bounded queues that grow on demand, reserved control capacity, and diagnostic counters.

## Correctness baseline

Windows, before any change:

- `zig build test`: 61 of 61 passed
- `zig build test-integration -Doptimize=ReleaseSafe`: 166 of 166 passed
- `zig build bench`: completed

After the changes in this phase:

| Check | Windows | Linux |
| --- | --- | --- |
| `zig build test`, Debug and ReleaseSafe | 61 of 61 | 61 of 61 (Debug) |
| `zig build fuzz -Dfuzz-iterations=100000` | 5 of 5 | not run |
| `zig build test-integration -Doptimize=ReleaseSafe` | 166 of 166 | 166 of 166 |
| `zig build stress-smoke -Doptimize=ReleaseSafe` | no failures | no failures |
| `sh tests/interop/run.sh` against go-nethernet | 1 B to 1 MiB echoed | Go not installed |
| `zig build -Dtracy=true` | builds | not run |

Stripped ReleaseFast builds with and without the Tracy zones have identical `.text`. Unstripped
builds differ only in instruction scheduling, from debug line information.

## Not measured

- Callback-to-poll latency per message. Tracy shows both ends, but the harness does not stamp
  messages inside the queue.
- Separate peers over a real network, mobile clients, or vanilla Bedrock under load.
- Kernel time on Linux, since `perf_event_paranoid` is 2 in this WSL setup.
- UDP mux, 1,000 or more pairs, and long soak runs.

## Phase 2

Same machine and workloads. Each row compares 1.1.0 with the current tree under identical
arguments, and every change kept the existing invariants and tests.

Changes:

- The callback queue restarts at offset zero whenever it drains, wraps without division, removes
  priority entries with `memmove` instead of byte loops, and stores 8-byte entries.
- A received fragment takes the peer lock once instead of twice, and a poll takes it once instead
  of three times. Queued signals are counted, so polls and waits no longer scan the queue.
- Every enqueue and state change already advances the peer's wakeup sequence under its lock. A
  poll that finds nothing records that sequence, and later polls return immediately until it
  moves, first in `Peer` and then in an established `Connection` with no reassembly in progress.

Queue microbenchmarks, ns per operation:

| Operation | 1.1.0 | Now |
| --- | ---: | ---: |
| Push and pop, 128 B | 16.7 | 14.1 |
| Signal check, 16 / 128 / 512 queued | 23 / 189 / 738 | O(1) in `Peer`; scan 11 / 133 / 545 |
| Priority pop behind 16 / 128 / 512, 20,000 pops | 27 / 200 / 750 | 21 / 151 / 560 |

Transport, ReleaseFast:

| Workload | Measurement | 1.1.0 | Now |
| --- | --- | ---: | ---: |
| Windows, 100 pairs, realistic | process CPU | 86-89% | 64-68% |
| | API thread CPU | 18-19% | 13-14% |
| | p50 / p99 | 1.35-1.36 / 2.7-3.0 ms | 1.37 / 2.5-2.7 ms |
| | RSS growth in 10 s | 15-16 MB | 8.6-9.2 MB |
| Windows, 400 pairs, realistic, 4 workers | process CPU | 279-282% | 251-255% |
| | API thread CPU | 83-88% | 67-69% |
| | p50 / p95 | 1.03-1.05 / 4.8-6.2 ms | 0.91-0.96 / 3.7-4.3 ms |
| Windows, 100 pairs, fixed 8 KiB | RSS growth / peak | 218 / 307 MB | 11 / 100 MB |
| Windows, 10 pairs, 64 B saturation, 2 workers | RSS growth | 19 MB | 0.8 MB |
| Linux, 200 pairs, realistic, 2 workers | API thread CPU | 40-43% | 35-38% |
| | `Connection.pollInternal` share | 10.3% | 5.3% |

Throughput and latency elsewhere are unchanged within run-to-run noise, since native code still
accounts for over 75% of CPU. The remaining poll cost is two cache misses per idle connection
per sweep. At 400 pairs the API thread is mostly synchronous `rtcSendMessage`, so a ready list
would save little there.

Worker counts, ReleaseFast, current tree:

| Workload | Platform | default (12) | 2 | 4 |
| --- | --- | ---: | ---: | ---: |
| 10 pairs, 64 B saturation, round trips/s | Windows | 11.8-12.7k | 16.3-17.3k | 15.3-16.8k |
| | Linux | 30.0k | 41.8-46.5k | 16.4-17.7k |
| 1 pair, 1200 B saturation, round trips/s | Windows | 7.0-7.1k | 5.6-6.2k | 7.2-7.7k |
| 1 pair, 64 KiB, 8 in flight, round trips/s | Windows | 268-299 | 147-169 | 246-266 |
| | Linux | 172 | 170 | 287 |
| 200 pairs, realistic, p99 | Linux | 24 ms | 1.2 ms | 6.5 ms |
| 400 pairs, realistic, p50 / p99 | Linux | 56 / 116 ms | 0.8-0.9 / 85-128 ms | 1.5-1.6 / 6-12 ms |

No single count wins everywhere, so the default stays libdatachannel's. Servers with many small
messages should set two to four workers and measure their own mix.

Still open:

- More than the receive queue of unread reliable data still fails the connection, for example
  64 x 64 KiB in flight against the default 1 MiB queue. libdatachannel's pull API would block a
  shared worker thread per slow consumer, so it is not a safe replacement as is.
- `rtcGetBufferedAmount` is about 1% of a send and was left in place.
