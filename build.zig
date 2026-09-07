const std = @import("std");

fn nativeModule(b: *std.Build, source: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, prefix: []const u8) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .link_libc = true });
    addNative(b, module, target, prefix);
    return module;
}
fn addNative(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, prefix: []const u8) void {
    module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    if (target.result.os.tag == .windows) module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", "libdatachannel.dll.a" }) }) else module.linkSystemLibrary("datachannel", .{});
}
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const prefix = b.option([]const u8, "native-prefix", "Installation prefix of patched libdatachannel") orelse b.pathFromRoot(".deps/native");
    const module = b.addModule("nethernet", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    addNative(b, module, target, prefix);
    const core = b.createModule(.{ .root_source_file = b.path("src/core.zig"), .target = target, .optimize = optimize });
    const core_tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run core codec, discovery, fuzz corpus and allocation tests").dependOn(&b.addRunArtifact(core_tests).step);
    b.default_step.dependOn(&core_tests.step);
    const native_tests = b.addTest(.{ .root_module = nativeModule(b, "src/peer_test.zig", target, optimize, prefix) });
    const run_native = b.addRunArtifact(native_tests);
    run_native.addPathDir(b.pathJoin(&.{ prefix, "bin" }));
    run_native.setEnvironmentVariable("LD_LIBRARY_PATH", b.pathJoin(&.{ prefix, "lib" }));
    b.step("test-native", "Run real WebRTC, endpoint and LAN integration tests").dependOn(&run_native.step);
    b.default_step.dependOn(&native_tests.step);
    inline for (.{ .{ "client", "examples/client.zig" }, .{ "echo", "examples/echo.zig" } }) |entry| {
        const example_module = b.createModule(.{ .root_source_file = b.path(entry[1]), .target = target, .optimize = optimize });
        example_module.addImport("nethernet", module);
        b.installArtifact(b.addExecutable(.{ .name = entry[0], .root_module = example_module }));
    }
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&b.addInstallFileWithDir(.{ .cwd_relative = b.pathJoin(&.{ prefix, "bin", "libdatachannel.dll" }) }, .bin, "libdatachannel.dll").step);
    const benchmark = b.addExecutable(.{ .name = "nethernet-benchmark", .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark.zig"), .target = target, .optimize = .ReleaseFast }) });
    b.step("bench", "Measure codecs, framing and bounded queues").dependOn(&b.addRunArtifact(benchmark).step);
}
