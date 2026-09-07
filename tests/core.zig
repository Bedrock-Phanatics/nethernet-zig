test {
    _ = @import("../src/wakeup.zig");
    _ = @import("../src/credentials.zig");
    _ = @import("../src/discovery.zig");
    _ = @import("../src/discovery_codec.zig");
    _ = @import("../src/framing.zig");
    _ = @import("../src/identity.zig");
    _ = @import("../src/queue.zig");
    _ = @import("../src/sdp_identity.zig");
    _ = @import("../src/server_data.zig");
    _ = @import("../src/signal.zig");
    _ = @import("fuzz.zig");
    _ = @import("wire.zig");
}
