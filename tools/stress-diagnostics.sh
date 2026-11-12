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
    [ -f .deps/native/include/rtc/rtc.h ] || sh tools/setup-native.sh
    TSAN_OPTIONS="suppressions=$(pwd)/tools/zig-tsan.supp ${TSAN_OPTIONS:-}" \
      $norandom zig build "$step" -Doptimize=ReleaseSafe -Dsanitize-thread=true -- "$@"
    ;;
  valgrind)
    [ -f .deps/native/include/rtc/rtc.h ] || sh tools/setup-native.sh
    # Valgrind does not know AVX-512
    zig build stress-install -Doptimize=ReleaseSafe -Dcpu=baseline
    LD_LIBRARY_PATH="$(pwd)/.deps/native/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      valgrind --error-exitcode=1 --leak-check=full \
      --show-leak-kinds=definite,indirect,possible \
      --errors-for-leak-kinds=definite,indirect zig-out/bin/transport-stress "$@"
    ;;
  perf)
    prefix="$(pwd)/.deps/native-perf"
    NETHERNET_NATIVE_PREFIX="$prefix" \
      NETHERNET_MBEDTLS_BUILD=".deps/mbedtls-build-perf" \
      NETHERNET_RTC_BUILD=".deps/rtc-build-perf" \
      NETHERNET_SANITIZER_FLAGS="-g -fno-omit-frame-pointer" \
      sh tools/setup-native.sh
    zig build stress-install -Doptimize=ReleaseFast -Dnative-prefix="$prefix"
    export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    perf stat -e task-clock,context-switches,cpu-migrations zig-out/bin/transport-stress "$@"
    perf record -F 999 -g -o .deps/perf.data zig-out/bin/transport-stress "$@"
    report="perf report -i .deps/perf.data --stdio"
    $report --no-children -g none --sort comm 2>/dev/null | grep -v '^$' | head -30
    $report --no-children -g none --sort comm,dso 2>/dev/null | grep -v '^$' | head -50
    $report --no-children -g none --sort dso,symbol 2>/dev/null | grep -v '^$' | head -120
    $report --children -g none --sort symbol 2>/dev/null | grep -v '^$' | head -120
    ;;
  massif)
    prefix="$(pwd)/.deps/native-perf"
    NETHERNET_NATIVE_PREFIX="$prefix" \
      NETHERNET_MBEDTLS_BUILD=".deps/mbedtls-build-perf" \
      NETHERNET_RTC_BUILD=".deps/rtc-build-perf" \
      NETHERNET_SANITIZER_FLAGS="-g -fno-omit-frame-pointer" \
      sh tools/setup-native.sh
    zig build stress-install -Doptimize=ReleaseSafe -Dcpu=baseline -Dnative-prefix="$prefix"
    LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      valgrind --tool=massif --massif-out-file=.deps/massif.out --depth=12 --threshold=0.5 \
      zig-out/bin/transport-stress "$@"
    ms_print --threshold=0.5 .deps/massif.out | grep -E '^ *[0-9]+ +[0-9,]+ +[0-9,]+|^[0-9.]+% |^([| ] ){0,4}->' | head -1500
    ;;
  *)
    echo "usage: tools/stress-diagnostics.sh asan|tsan|zig-tsan|valgrind|perf|massif [stress arguments...]" >&2
    exit 2
    ;;
esac
