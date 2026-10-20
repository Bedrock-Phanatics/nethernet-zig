const std = @import("std");
const enabled = @import("trace_options").tracy;

const SourceLocation = extern struct {
    name: ?[*:0]const u8,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: u32,
    color: u32,
};

const Context = extern struct {
    id: u32,
    active: i32,
};

extern fn ___tracy_emit_zone_begin(location: *const SourceLocation, active: i32) Context;
extern fn ___tracy_emit_zone_end(context: Context) void;

pub const Zone = if (enabled) struct {
    context: Context,

    pub inline fn end(self: Zone) void {
        ___tracy_emit_zone_end(self.context);
    }
} else struct {
    pub inline fn end(_: Zone) void {}
};

pub inline fn zone(comptime source: std.builtin.SourceLocation, comptime name: [:0]const u8) Zone {
    if (!enabled) return .{};
    // Tracy identifies zones by the address of their static source location.
    const static = struct {
        const location: SourceLocation = .{
            .name = name,
            .function = source.fn_name,
            .file = source.file,
            .line = source.line,
            .color = 0,
        };
    };
    return .{ .context = ___tracy_emit_zone_begin(&static.location, 1) };
}
