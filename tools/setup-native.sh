#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
test "$(zig version)" = 0.17.0
mkdir -p .deps

if [ ! -d .deps/libdatachannel/.git ]; then
    git clone \
        --branch v0.24.5 \
        --depth 1 \
        --recurse-submodules \
        --shallow-submodules \
        https://github.com/paullouisageneau/libdatachannel.git \
        .deps/libdatachannel
fi

if [ ! -d .deps/mbedtls/.git ]; then
    git clone \
        --branch mbedtls-3.6.7 \
        --depth 1 \
        --recurse-submodules \
        --shallow-submodules \
        https://github.com/Mbed-TLS/mbedtls.git \
        .deps/mbedtls
fi

test "$(git -C .deps/libdatachannel rev-parse HEAD)" = \
    443f6934d9007eb7076ab7825ba330f355fcbead
test "$(git -C .deps/mbedtls rev-parse HEAD)" = \
    068ff080b369adfac81509f9b57b2afabaf82dc5

for setting in "set MBEDTLS_SSL_DTLS_SRTP" "set MBEDTLS_AES_ROM_TABLES" \
    "unset MBEDTLS_DEBUG_C" "unset MBEDTLS_SELF_TEST"; do
    python3 .deps/mbedtls/scripts/config.py \
        -f .deps/mbedtls/include/mbedtls/mbedtls_config.h $setting
done

patches=""
for name in bounds mbedtls-link-order threadpool dtls-timer sctp-timer-wheel juice-timers \
    sctp-receive-pause dtls-incoming juice-mux-routing; do
    patches="$patches $(pwd)/tools/libdatachannel-$name.patch"
done
# Patches are reapplied to a clean tree whenever one changes, so edited patches take effect.
stamp=.deps/libdatachannel/.git/nethernet-patches
wanted="$(cat $patches | git hash-object --stdin)"
if [ "$(cat "$stamp" 2>/dev/null)" != "$wanted" ]; then
    git -C .deps/libdatachannel checkout -q -- .
    git -C .deps/libdatachannel submodule foreach --quiet --recursive git checkout -q -- .
    for patch in $patches; do
        git -C .deps/libdatachannel apply "$patch"
    done
    echo "$wanted" > "$stamp"
fi

prefix="${NETHERNET_NATIVE_PREFIX:-$(pwd)/.deps/native}"
mbedtls_build="${NETHERNET_MBEDTLS_BUILD:-.deps/mbedtls-build}"
rtc_build="${NETHERNET_RTC_BUILD:-.deps/rtc-build}"
flags="${NETHERNET_SANITIZER_FLAGS:-}"

cmake \
    -S .deps/mbedtls \
    -B "$mbedtls_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_C_FLAGS="$flags" \
    -DCMAKE_CXX_FLAGS="$flags" \
    -DENABLE_TESTING=OFF \
    -DENABLE_PROGRAMS=OFF
cmake --build "$mbedtls_build" -j 4 --target install

cmake \
    -S .deps/libdatachannel \
    -B "$rtc_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_PREFIX_PATH="$prefix" \
    -DCMAKE_C_FLAGS="$flags" \
    -DCMAKE_CXX_FLAGS="$flags" \
    -DNO_TESTS=ON \
    -DNO_EXAMPLES=ON \
    -DNO_MEDIA=ON \
    -DNO_WEBSOCKET=ON \
    -DUSE_MBEDTLS=ON \
    -DBUILD_SHARED_LIBS=ON
cmake --build "$rtc_build" -j 4 --target install
