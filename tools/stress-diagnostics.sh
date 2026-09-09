#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

mode="${1:-}"
shift || true
case "$mode" in
  asan|tsan)
    if [ "$mode" = asan ]; then sanitizer=address; else sanitizer=thread; fi
    flag="-fsanitize=$sanitizer"
    prefix="$(pwd)/.deps/native-$mode"
    NETHERNET_NATIVE_PREFIX="$prefix" \
      NETHERNET_MBEDTLS_BUILD=".deps/mbedtls-build-$mode" \
      NETHERNET_RTC_BUILD=".deps/rtc-build-$mode" \
      NETHERNET_SANITIZER_FLAGS="$flag -fno-omit-frame-pointer" \
      tools/setup-native.sh
    zig build stress -Doptimize=ReleaseSafe -Dnative-prefix="$prefix" \
      -Dnative-sanitizer="$sanitizer" -- "$@"
    ;;
  valgrind)
    zig build -Doptimize=ReleaseSafe
    LD_LIBRARY_PATH="$(pwd)/.deps/native/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      valgrind --error-exitcode=1 --leak-check=full \
      --show-leak-kinds=definite,indirect zig-out/bin/transport-stress "$@"
    ;;
  *)
    echo "usage: tools/stress-diagnostics.sh asan|tsan|valgrind [stress arguments...]" >&2
    exit 2
    ;;
esac
