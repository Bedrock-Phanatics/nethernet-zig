#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
test "$(zig version)" = 0.16.0
mkdir -p .deps
test -d .deps/libdatachannel/.git || git clone --branch v0.24.5 --depth 1 --recurse-submodules --shallow-submodules https://github.com/paullouisageneau/libdatachannel.git .deps/libdatachannel
test -d .deps/mbedtls/.git || git clone --branch mbedtls-3.6.7 --depth 1 --recurse-submodules --shallow-submodules https://github.com/Mbed-TLS/mbedtls.git .deps/mbedtls
test "$(git -C .deps/libdatachannel rev-parse HEAD)" = 443f6934d9007eb7076ab7825ba330f355fcbead
test "$(git -C .deps/mbedtls rev-parse HEAD)" = 068ff080b369adfac81509f9b57b2afabaf82dc5
python3 .deps/mbedtls/scripts/config.py -f .deps/mbedtls/include/mbedtls/mbedtls_config.h set MBEDTLS_SSL_DTLS_SRTP
patch="$(pwd)/tools/libdatachannel-bounds.patch"
git -C .deps/libdatachannel apply --reverse --check "$patch" 2>/dev/null || git -C .deps/libdatachannel apply "$patch"
prefix="$(pwd)/.deps/native"
cmake -S .deps/mbedtls -B .deps/mbedtls-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$prefix" -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF
cmake --build .deps/mbedtls-build -j 4 --target install
cmake -S .deps/libdatachannel -B .deps/rtc-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" -DNO_TESTS=ON -DNO_EXAMPLES=ON -DNO_MEDIA=ON -DNO_WEBSOCKET=ON -DUSE_MBEDTLS=ON -DBUILD_SHARED_LIBS=ON
cmake --build .deps/rtc-build -j 4 --target install
