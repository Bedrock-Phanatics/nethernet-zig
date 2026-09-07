const std = @import("std");

fn module(b: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

fn addNative(b: *std.Build, value: *std.Build.Module, target: std.Build.ResolvedTarget, prefix: []const u8) void {
    value.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    value.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });

    if (target.result.os.tag == .windows) {
        value.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", "libdatachannel.dll.a" }) });
    } else {
        value.linkSystemLibrary("datachannel", .{});
    }
}

fn nativeModule(b: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, prefix: []const u8) *std.Build.Module {
    const value = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addNative(b, value, target, prefix);
    return value;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_prefix = b.option([]const u8, "native-prefix", "Installation prefix of patched libdatachannel") orelse b.pathFromRoot(".deps/native");

    const public_module = b.addModule("nethernet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addNative(b, public_module, target, native_prefix);

    const core_root = module(b, "tests.zig", target, optimize);
    const core_tests = b.addTest(.{ .root_module = core_root });
    b.step("test", "Run core codec, discovery, fuzz corpus and allocation tests").dependOn(&b.addRunArtifact(core_tests).step);
    b.default_step.dependOn(&core_tests.step);

    const native_root = nativeModule(b, "native_tests.zig", target, optimize, native_prefix);
    const native_tests = b.addTest(.{ .root_module = native_root });
    const run_native_tests = b.addRunArtifact(native_tests);
    run_native_tests.addPathDir(b.pathJoin(&.{ native_prefix, "bin" }));
    run_native_tests.setEnvironmentVariable("LD_LIBRARY_PATH", b.pathJoin(&.{ native_prefix, "lib" }));
    b.step("test-native", "Run real WebRTC, endpoint and LAN integration tests").dependOn(&run_native_tests.step);
    b.default_step.dependOn(&native_tests.step);

    inline for (.{
        .{ "client", "examples/client.zig" },
        .{ "echo", "examples/echo.zig" },
    }) |example| {
        const example_module = module(b, example[1], target, optimize);
        example_module.addImport("nethernet", public_module);
        b.installArtifact(b.addExecutable(.{ .name = example[0], .root_module = example_module }));
    }

    if (target.result.os.tag == .windows) {
        const dll = b.addInstallFileWithDir(
            .{ .cwd_relative = b.pathJoin(&.{ native_prefix, "bin", "libdatachannel.dll" }) },
            .bin,
            "libdatachannel.dll",
        );
        b.getInstallStep().dependOn(&dll.step);
    }

    const benchmark_module = module(b, "benchmarks/main.zig", target, .ReleaseFast);
    benchmark_module.addImport("discovery_codec", module(b, "src/discovery_codec.zig", target, .ReleaseFast));
    benchmark_module.addImport("framing", module(b, "src/framing.zig", target, .ReleaseFast));
    benchmark_module.addImport("queue", module(b, "src/queue.zig", target, .ReleaseFast));
    const benchmark = b.addExecutable(.{ .name = "nethernet-benchmark", .root_module = benchmark_module });
    b.step("bench", "Measure codecs, framing and bounded queues").dependOn(&b.addRunArtifact(benchmark).step);
}
