#!/usr/bin/env bash
# Runs the stress workloads against several native builds, alternating them within each repetition so
# machine drift lands on all alike. One JSON line per run goes to <out>/<prefix name>.jsonl.
# usage: tools/bench-matrix.sh <out> <repetitions> <native prefix>...
set -eu
cd "$(dirname "$0")/.."
out=$1
reps=$2
shift 2
prefixes=("$@")
mkdir -p "$out"
zig build stress-install -Doptimize=ReleaseFast
for prefix in "${prefixes[@]}"; do : > "$out/$(basename "$prefix").jsonl"; done

run() {
    tag=$1
    shift
    for rep in $(seq 1 "$reps"); do
        for prefix in "${prefixes[@]}"; do
            line=$(LD_LIBRARY_PATH="$prefix/lib" zig-out/bin/transport-stress "$@" 2>&1 | grep '^{' | tail -1 || true)
            [ -n "$line" ] || line='{"error":true}'
            echo "{\"tag\":\"$tag\",\"rep\":$rep,\"r\":$line}" >> "$out/$(basename "$prefix").jsonl"
        done
    done
}

for n in 1 10 100 500 1000; do run "game-$n" --connections $n --duration-ms 8000 --timeout-ms 20000; done
for n in 100 1000; do run "idle-$n" --connections $n --duration-ms 8000 --idle --timeout-ms 20000; done
for n in 1 10 100; do
    run "bulk-$n" --connections $n --duration-ms 8000 --rate 0 --profile fixed --payload-size 8192 --reliability reliable --timeout-ms 20000
done
run bulk64k-1 --connections 1 --duration-ms 8000 --rate 0 --profile fixed --payload-size 65536 --max-in-flight 16 --reliability reliable --timeout-ms 20000
run unrel-10 --connections 10 --duration-ms 8000 --rate 0 --profile fixed --payload-size 1024 --reliability unreliable --timeout-ms 20000
run churn-20 --connections 20 --duration-ms 8000 --churn-messages 20 --timeout-ms 20000
