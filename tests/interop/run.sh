#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
go build -o ../../zig-out/bin/interop .
cd ../..
export LD_LIBRARY_PATH="$(pwd)/.deps/native/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

zig-out/bin/server &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
attempts=0
until curl -fs http://127.0.0.1:18750/v1/join > /dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 50 ] || { echo "server did not start" >&2; exit 1; }
  sleep 0.1
done

zig-out/bin/interop 127.0.0.1:18750 1,1200,262143,262144,1048576 1,1200,8192
wait $server
