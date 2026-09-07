# Third-party components

The library is distributed under the repository LICENSE. Native dependencies have their own licenses below.

The native build pins:

| Component | Version / source | License | Role |
|---|---|---|---|
| libdatachannel | v0.24.5, https://github.com/paullouisageneau/libdatachannel | MPL-2.0 | WebRTC C API |
| Mbed TLS | mbedtls-3.6.7, https://github.com/Mbed-TLS/mbedtls | Apache-2.0 OR GPL-2.0-or-later (use Apache-2.0) | DTLS and certificate cryptography |
| libjuice | libdatachannel's pinned submodule | MPL-2.0 | ICE/STUN/TURN |
| usrsctp | libdatachannel's pinned submodule | BSD-3-Clause | SCTP |
| plog | libdatachannel's pinned submodule | MIT | Native logging |

The exact submodule commits are resolved by the pinned parent repository. Media and WebSocket support are disabled. The dependency source trees include their license notices; retain applicable notices when distributing native binaries. `tools/libdatachannel-bounds.patch` modifies MPL-covered `src/impl/sctptransport.cpp`; distribute the corresponding patched source and license as required by MPL-2.0.

Build-only tools installed locally on Windows are CMake 3.31.10 (BSD-3-Clause) and Ninja 1.13.0 (Apache-2.0). Zig and its standard library retain their upstream license notices.

## Native bounds patch

Upstream v0.24.5 truncates SCTP user messages exceeding `mMaxMessageSize`, potentially presenting corrupted application data as a valid complete message. The patch clears the partial buffer, fails the association, and stops processing it.

The same source unconditionally resizes legacy partial-PPID buffers to `mMaxMessageSize`, expanding small messages or truncating large ones. The patch retains their actual size and fails the association on overflow. Valid binary messages are unaffected.
