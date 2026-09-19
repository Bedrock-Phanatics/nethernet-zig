const std = @import("std");

const NativeSanitizer = enum {
    address,
    thread,
};

fn createModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

fn addNative(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    prefix: []const u8,
) void {
    module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });

    if (target.result.os.tag == .windows) {
        module.addObjectFile(.{
            .cwd_relative = b.pathJoin(&.{ prefix, "lib", "libdatachannel.dll.a" }),
        });
        return;
    }

    module.linkSystemLibrary("datachannel", .{});
}

fn createNativeModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    prefix: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addNative(b, module, target, prefix);
    return module;
}

fn addNativeRuntime(
    b: *std.Build,
    run: *std.Build.Step.Run,
    target: std.Build.ResolvedTarget,
    prefix: []const u8,
) void {
    run.addPathDir(b.pathJoin(&.{ prefix, "bin" }));

    switch (target.result.os.tag) {
        .linux => run.setEnvironmentVariable(
            "LD_LIBRARY_PATH",
            b.pathJoin(&.{ prefix, "lib" }),
        ),
        .macos => run.setEnvironmentVariable(
            "DYLD_LIBRARY_PATH",
            b.pathJoin(&.{ prefix, "lib" }),
        ),
        else => {},
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_prefix = b.option(
        []const u8,
        "native-prefix",
        "Installation prefix of patched libdatachannel",
    ) orelse b.pathFromRoot(".deps/native");
    const fuzz_iterations = b.option(
        usize,
        "fuzz-iterations",
        "Number of deterministic fuzz inputs",
    ) orelse 20_000;
    const native_sanitizer = b.option(
        NativeSanitizer,
        "native-sanitizer",
        "Link a matching instrumented native dependency build",
    );

    const build_options = b.addOptions();
    build_options.addOption(usize, "fuzz_iterations", fuzz_iterations);

    const nethernet = b.addModule("nethernet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addNative(b, nethernet, target, native_prefix);

    const core = createModule(b, "src/core.zig", target, optimize);

    const unit_tests = b.addTest(.{ .root_module = core });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const wire_module = createModule(b, "tests/wire.zig", target, optimize);
    wire_module.addImport("nethernet_core", core);
    const wire_tests = b.addTest(.{ .root_module = wire_module });
    const run_wire_tests = b.addRunArtifact(wire_tests);

    const test_step = b.step("test", "Run core unit and wire-format tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_wire_tests.step);

    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .error_tracing = false,
        .target = target,
        .optimize = optimize,
    });
    fuzz_module.addImport("nethernet_core", core);
    fuzz_module.addOptions("build_options", build_options);
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_module,
        .use_llvm = true,
        .use_lld = true,
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    b.step("fuzz", "Run bounded parser fuzzing").dependOn(&run_fuzz.step);

    const integration_module = createModule(
        b,
        "tests/integration/root.zig",
        target,
        optimize,
    );
    integration_module.addImport("nethernet", nethernet);
    const integration_tests = b.addTest(.{ .root_module = integration_module });
    const run_integration = b.addRunArtifact(integration_tests);
    addNativeRuntime(b, run_integration, target, native_prefix);

    const integration_step = b.step(
        "test-integration",
        "Run real WebRTC, endpoint, LAN, and network integration tests",
    );
    integration_step.dependOn(&run_integration.step);
    b.step("test-native", "Alias for test-integration").dependOn(integration_step);

    inline for (.{
        .{ "client", "examples/client.zig" },
        .{ "server", "examples/server.zig" },
    }) |example| {
        const example_module = createModule(b, example[1], target, optimize);
        example_module.addImport("nethernet", nethernet);
        const executable = b.addExecutable(.{
            .name = example[0],
            .root_module = example_module,
        });
        b.installArtifact(executable);
    }

    if (target.result.os.tag == .windows) {
        const dll = b.addInstallFileWithDir(
            .{ .cwd_relative = b.pathJoin(&.{ native_prefix, "bin", "libdatachannel.dll" }) },
            .bin,
            "libdatachannel.dll",
        );
        b.getInstallStep().dependOn(&dll.step);
    }

    const wake_bench_module = createModule(
        b,
        "tests/bench/wakeup.zig",
        target,
        .ReleaseFast,
    );
    wake_bench_module.addImport(
        "wakeup",
        createModule(b, "src/internal/wakeup.zig", target, .ReleaseFast),
    );
    wake_bench_module.addImport(
        "queue",
        createModule(b, "src/internal/queue.zig", target, .ReleaseFast),
    );
    const wake_bench = b.addExecutable(.{
        .name = "wakeup-benchmark",
        .root_module = wake_bench_module,
    });
    const wake_bench_step = b.step(
        "bench-wakeup",
        "Measure wakeup latency and idle CPU",
    );
    wake_bench_step.dependOn(&b.addRunArtifact(wake_bench).step);

    const benchmark_module = createModule(
        b,
        "tests/bench/main.zig",
        target,
        .ReleaseFast,
    );
    benchmark_module.addImport(
        "discovery_codec",
        createModule(b, "src/discovery/codec.zig", target, .ReleaseFast),
    );
    benchmark_module.addImport(
        "framing",
        createModule(b, "src/transport/framing.zig", target, .ReleaseFast),
    );
    benchmark_module.addImport(
        "queue",
        createModule(b, "src/internal/queue.zig", target, .ReleaseFast),
    );
    const benchmark = b.addExecutable(.{
        .name = "nethernet-benchmark",
        .root_module = benchmark_module,
    });
    const benchmark_step = b.step(
        "bench",
        "Measure codec, framing, and queue performance",
    );
    benchmark_step.dependOn(&b.addRunArtifact(benchmark).step);

    const memory_module = createModule(
        b,
        "tests/bench/memory.zig",
        target,
        .ReleaseFast,
    );
    memory_module.addImport(
        "framing",
        createModule(b, "src/transport/framing.zig", target, .ReleaseFast),
    );
    memory_module.addImport(
        "queue",
        createModule(b, "src/internal/queue.zig", target, .ReleaseFast),
    );
    const memory_bench = b.addExecutable(.{
        .name = "memory-benchmark",
        .root_module = memory_module,
    });
    const memory_bench_step = b.step(
        "bench-memory",
        "Report bounded buffer memory",
    );
    memory_bench_step.dependOn(&b.addRunArtifact(memory_bench).step);

    const stress_module = createModule(b, "tests/bench/stress.zig", target, optimize);
    stress_module.addImport("nethernet", nethernet);
    if (target.result.os.tag == .windows) stress_module.linkSystemLibrary("psapi", .{});
    if (native_sanitizer) |sanitizer| {
        stress_module.linkSystemLibrary(switch (sanitizer) {
            .address => "asan",
            .thread => "tsan",
        }, .{});
    }

    const stress = b.addExecutable(.{
        .name = "transport-stress",
        .root_module = stress_module,
    });
    const install_stress = b.addInstallArtifact(stress, .{});
    const stress_install_step = b.step(
        "stress-install",
        "Install the transport stress executable",
    );
    stress_install_step.dependOn(&install_stress.step);

    const run_stress = b.addRunArtifact(stress);
    addNativeRuntime(b, run_stress, target, native_prefix);
    if (b.args) |args| run_stress.addArgs(args);
    const stress_step = b.step(
        "stress",
        "Run configurable real-transport stress diagnostics",
    );
    stress_step.dependOn(&run_stress.step);

    const run_stress_smoke = b.addRunArtifact(stress);
    addNativeRuntime(b, run_stress_smoke, target, native_prefix);
    run_stress_smoke.addArgs(&.{
        "--connections",
        "2",
        "--duration-ms",
        "1500",
        "--payload-size",
        "8192",
        "--churn-messages",
        "50",
    });
    const stress_smoke_step = b.step(
        "stress-smoke",
        "Run a short real-transport stress check",
    );
    stress_smoke_step.dependOn(&run_stress_smoke.step);
}
