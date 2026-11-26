#!/usr/bin/env bash
# Linux only. Drives an echo server with go-nethernet load clients from another process and reports the
# server's CPU and RSS over the traffic window, as one JSON line. {addr} in the command becomes its address.
# usage: tools/bench-server.sh <connections> <rate> <seconds> <server command...>
#   tools/bench-server.sh 500 20 10 zig-out/bin/nethernet-echo {addr}
#   tools/bench-server.sh 500 20 10 zig-out/bin/nethernet-load -mode serve -addr {addr}
set -eu
cd "$(dirname "$0")/.."
connections=$1
rate=$2
seconds=$3
shift 3
[ -x zig-out/bin/nethernet-load ] || (cd tests/interop && go build -o ../../zig-out/bin/nethernet-load ./load)

addr="127.0.0.1:$((18800 + RANDOM % 100))"
"${@//\{addr\}/$addr}" > /dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
until curl -fs "http://$addr/v1/join" > /dev/null 2>&1; do
    kill -0 $server 2>/dev/null || { echo "server exited" >&2; exit 1; }
    sleep 0.1
done

ticks() { awk '{print $14 + $15}' /proc/$server/stat; }
rss() { awk '/VmRSS/ {print $2}' /proc/$server/status; }
idle_rss=$(rss)
result=""
while IFS= read -r line; do
    case "$line" in
        TRAFFIC_START) start_ticks=$(ticks); start=$(date +%s.%N) ;;
        TRAFFIC_END) end_ticks=$(ticks); end=$(date +%s.%N); busy_rss=$(rss) ;;
        \{*) result=$line ;;
    esac
done < <(zig-out/bin/nethernet-load -addr "$addr" -n "$connections" -rate "$rate" -duration "${seconds}s" 2>&1)

# Clock ticks are 1/100 s, so ticks per second read as percent of one core.
cpu=$(awk -v t=$((end_ticks - start_ticks)) -v s="$start" -v e="$end" 'BEGIN {printf "%.1f", t / (e - s)}')
echo "{\"connections\":$connections,\"rate\":$rate,\"server_cpu_percent\":$cpu,\"server_rss_kib_per_connection\":$(((busy_rss - idle_rss) / connections)),\"load\":$result}"
