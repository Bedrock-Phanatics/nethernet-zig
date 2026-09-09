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
    const fuzz_iterations = b.option(usize, "fuzz-iterations", "Number of deterministic fuzz inputs") orelse 20_000;

    const build_options = b.addOptions();
    build_options.addOption(usize, "fuzz_iterations", fuzz_iterations);

    const public_module = b.addModule("nethernet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addNative(b, public_module, target, native_prefix);

    const core_root = module(b, "tests.zig", target, optimize);
    core_root.addOptions("build_options", build_options);
    const core_tests = b.addTest(.{ .root_module = core_root });
    const run_core_tests = b.addRunArtifact(core_tests);
    b.step("test", "Run core codec, discovery, fuzz corpus and allocation tests").dependOn(&run_core_tests.step);
    b.step("fuzz", "Run the fuzz corpus and deterministic malformed-input campaign").dependOn(&run_core_tests.step);
    b.default_step.dependOn(&run_core_tests.step);

    const native_root = nativeModule(b, "native_tests.zig", target, optimize, native_prefix);
    const native_tests = b.addTest(.{ .root_module = native_root });
    const run_native_tests = b.addRunArtifact(native_tests);
    run_native_tests.addPathDir(b.pathJoin(&.{ native_prefix, "bin" }));
    run_native_tests.setEnvironmentVariable(
        if (target.result.os.tag == .macos) "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH",
        b.pathJoin(&.{ native_prefix, "lib" }),
    );
    b.step("test-native", "Run real WebRTC, endpoint and LAN integration tests").dependOn(&run_native_tests.step);
    b.default_step.dependOn(&run_native_tests.step);

    inline for (.{
        .{ "client", "examples/client.zig" },
        .{ "echo", "examples/echo.zig" },
    }) |example| {
        const example_module = module(b, example[1], target, optimize);
        example_module.addImport("nethernet", public_module);
        const executable = b.addExecutable(.{ .name = example[0], .root_module = example_module });
        b.installArtifact(executable);
        b.step(b.fmt("example-{s}", .{example[0]}), b.fmt("Build the {s} example", .{example[0]})).dependOn(&executable.step);
    }

    if (target.result.os.tag == .windows) {
        const dll = b.addInstallFileWithDir(
            .{ .cwd_relative = b.pathJoin(&.{ native_prefix, "bin", "libdatachannel.dll" }) },
            .bin,
            "libdatachannel.dll",
        );
        b.getInstallStep().dependOn(&dll.step);
    }

    const wake_bench_module = module(b, "bench/wakeup.zig", target, .ReleaseFast);
    wake_bench_module.addImport("wakeup", module(b, "src/wakeup.zig", target, .ReleaseFast));
    wake_bench_module.addImport("queue", module(b, "src/queue.zig", target, .ReleaseFast));
    const wake_bench = b.addExecutable(.{ .name = "wakeup-benchmark", .root_module = wake_bench_module });
    b.step("bench-wakeup", "Compare event wakeup latency and idle CPU with 1 ms polling").dependOn(&b.addRunArtifact(wake_bench).step);

    const benchmark_module = module(b, "bench/main.zig", target, .ReleaseFast);
    benchmark_module.addImport("discovery_codec", module(b, "src/discovery_codec.zig", target, .ReleaseFast));
    benchmark_module.addImport("framing", module(b, "src/framing.zig", target, .ReleaseFast));
    benchmark_module.addImport("queue", module(b, "src/queue.zig", target, .ReleaseFast));
    const benchmark = b.addExecutable(.{ .name = "nethernet-benchmark", .root_module = benchmark_module });
    b.step("bench", "Measure codecs, framing and bounded queues").dependOn(&b.addRunArtifact(benchmark).step);

    const memory_module = module(b, "bench/memory.zig", target, .ReleaseFast);
    memory_module.addImport("framing", module(b, "src/framing.zig", target, .ReleaseFast));
    memory_module.addImport("queue", module(b, "src/queue.zig", target, .ReleaseFast));
    const memory_bench = b.addExecutable(.{ .name = "memory-benchmark", .root_module = memory_module });
    const run_memory_bench = b.addRunArtifact(memory_bench);
    b.step("bench-memory", "Report bounded Zig buffer memory at 1, 100, 500, and 1000 connections").dependOn(&run_memory_bench.step);
}
