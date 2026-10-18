const std = @import("std");
const enabled = @import("trace_options").tracy;
const ztracy = if (enabled) @import("ztracy") else struct {};

pub const Zone = if (enabled) struct {
    context: ztracy.ZoneCtx,

    pub inline fn end(self: Zone) void {
        self.context.End();
    }
} else struct {
    pub inline fn end(_: Zone) void {}
};

pub inline fn zone(comptime source: std.builtin.SourceLocation, comptime name: [:0]const u8) Zone {
    return if (enabled) .{ .context = ztracy.ZoneN(source, name) } else .{};
}
