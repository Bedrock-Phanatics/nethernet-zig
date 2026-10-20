#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

mode="${1:-}"
shift || true
step="${NETHERNET_DIAGNOSTICS_STEP:-stress}"
# TSan cannot map its shadow memory under the address randomization of recent kernels.
norandom="setarch $(uname -m) -R"
case "$mode" in
  asan|tsan)
    if [ "$mode" = asan ]; then sanitizer=address; else sanitizer=thread; fi
    flag="-fsanitize=$sanitizer"
    prefix="$(pwd)/.deps/native-$mode"
    NETHERNET_NATIVE_PREFIX="$prefix" \
      NETHERNET_MBEDTLS_BUILD=".deps/mbedtls-build-$mode" \
      NETHERNET_RTC_BUILD=".deps/rtc-build-$mode" \
      NETHERNET_SANITIZER_FLAGS="$flag -fno-omit-frame-pointer" \
      sh tools/setup-native.sh
    if [ "$mode" = asan ]; then norandom=; fi
    $norandom zig build "$step" -Doptimize=ReleaseSafe -Dnative-prefix="$prefix" \
      -Dnative-sanitizer="$sanitizer" -- "$@"
    ;;
  zig-tsan)
    TSAN_OPTIONS="suppressions=$(pwd)/tools/zig-tsan.supp ${TSAN_OPTIONS:-}" \
      $norandom zig build "$step" -Doptimize=ReleaseSafe -Dsanitize-thread=true -- "$@"
    ;;
  valgrind)
    zig build stress-install -Doptimize=ReleaseSafe
    LD_LIBRARY_PATH="$(pwd)/.deps/native/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      valgrind --error-exitcode=1 --leak-check=full \
      --show-leak-kinds=definite,indirect zig-out/bin/transport-stress "$@"
    ;;
  *)
    echo "usage: tools/stress-diagnostics.sh asan|tsan|zig-tsan|valgrind [stress arguments...]" >&2
    exit 2
    ;;
esac
