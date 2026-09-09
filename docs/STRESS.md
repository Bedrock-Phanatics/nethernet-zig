# Transport stress and native diagnostics

`zig build stress -Doptimize=ReleaseSafe -- [options]` runs real libdatachannel/usrsctp loopback pairs. It validates every echoed payload and emits one JSON record containing setup time, throughput, latency p50/p95/p99, process CPU (which may exceed 100% when native worker threads use multiple cores), resident-memory growth, reconnects, callback queue high-water use, unreliable drops, corruption, and transport failures. Receive and negotiation waits have deadlines, so a deadlock becomes a failing timeout.

`--rate` limits aggregate batches per second; `--burst` is the number of messages queued before draining. Options are `--connections`, `--duration-ms`, `--messages`, `--payload-size`, `--rate`, `--burst`, `--churn-messages`, `--timeout-ms`, `--reliability reliable|unreliable|mixed`, and `--profile fixed|bedrock|rollover`. Storage for connection pairs, payloads, and latency samples is allocated before traffic; the harness adds no allocations in its packet loop.

The `bedrock` profile cycles 32, 64, 96, 128, 256, 512, 1400, and 8192-byte messages up to `--payload-size`; mixed reliability sends every tenth message unreliably. Use a large burst and payload to exercise native send/backpressure and the bounded callback queue. Churn replaces pairs after the configured message interval.

```sh
zig build stress -Doptimize=ReleaseSafe -- --connections 500 --duration-ms 3600000 --payload-size 8192 --rate 20 --churn-messages 10000
zig build stress -Doptimize=ReleaseSafe -- --connections 1000 --duration-ms 21600000 --payload-size 262144 --burst 32 --reliability reliable
zig build stress -Doptimize=ReleaseSafe -- --profile rollover
```

The rollover profile uses one long-lived reliable SCTP association and tiny messages so usrsctp advances native DATA TSNs as quickly as possible. libdatachannel exposes neither its usrsctp socket nor the diagnostic `SCTP_SET_INITIAL_DBG_SEQ` option, so the harness does not reach through SCTP internals. With no explicit `--duration-ms` or `--messages`, this manual profile uses bounded 256-message batches and runs 2^32 application messages, guaranteeing at least that many native DATA chunks; preserve the JSON message count. Set a duration explicitly for a shorter progression soak, which is not proof of wraparound.

`zig build stress-smoke -Doptimize=ReleaseSafe` is the CI-safe 1.5-second profile. Production-scale runs are manual, including the `transport stress` workflow because socket, thread, handle, and memory limits differ by host; increase connection counts gradually.

## Native diagnostics

On Linux, run `sh tools/stress-diagnostics.sh asan ...`, `tsan ...`, or `valgrind ...`. ASan also enables leak detection when the runtime supports LSan. The script builds isolated instrumented native prefixes. TSan support varies by libc/toolchain. Valgrind is Linux-only here and substantially slower. macOS sanitizer support varies by Apple toolchain. Windows records CPU and working-set growth, but the supported sanitizer path is Linux.

Compare RSS after setup across equal-length windows: allocators and native libraries retain arenas, so bounded plateaus are expected while monotonic growth is suspicious. Save JSON with OS version, CPU model, `zig version`, git commit, libdatachannel commit, build mode, command line, and diagnostic-tool version.

## Baseline

```text
Date: 2026-09-09
OS: Microsoft Windows 11 Home 10.0.26200 (build 26200), x86_64
CPU: AMD Ryzen 5 5500
Zig: 0.16.0; Mode: ReleaseSafe
Command: zig build stress-smoke -Doptimize=ReleaseSafe
Parameters: 2 pairs, 1500 ms, Bedrock/mixed, 8192-byte cap, churn every 50 messages
Result: 50 round trips; 32.8 msg/s; 0.08 MiB/s; p50/p95/p99 31.07/32.14/32.14 ms; CPU 39.0%; post-setup RSS change -1,593,344 bytes; 1 reconnect; 0 failures/corruptions/drops; queue high-water 8193 bytes
```
