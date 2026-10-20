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
    sanitizer_runtime: ?[]const u8,
) void {
    run.addPathDir(b.pathJoin(&.{ prefix, "bin" }));
    if (sanitizer_runtime) |runtime| {
        run.setEnvironmentVariable("LD_PRELOAD", runtime);
        // Zig threads bring their own signal stack, which ASan would unmap at thread exit.
        if (std.mem.indexOf(u8, runtime, "libasan") != null) run.setEnvironmentVariable(
            "ASAN_OPTIONS",
            b.fmt("use_sigaltstack=0:{s}", .{b.graph.environ_map.get("ASAN_OPTIONS") orelse ""}),
        );
        if (std.mem.indexOf(u8, runtime, "libtsan") != null) run.setEnvironmentVariable(
            "TSAN_OPTIONS",
            b.fmt("suppressions={s}:{s}", .{ b.pathFromRoot("tools/tsan.supp"), b.graph.environ_map.get("TSAN_OPTIONS") orelse "" }),
        );
    }

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
        "Preload the runtime of a matching instrumented native dependency build",
    );
    const native_compiler = b.option([]const u8, "native-compiler", "C compiler that built the native dependencies") orelse "cc";
    const sanitizer_runtime: ?[]const u8 = if (native_sanitizer) |sanitizer| blk: {
        const library = switch (sanitizer) {
            .address => "libasan.so",
            .thread => "libtsan.so",
        };
        const path = std.mem.trimEnd(u8, b.run(&.{ native_compiler, b.fmt("-print-file-name={s}", .{library}) }), "\r\n");
        if (std.mem.indexOfScalar(u8, path, '/') == null) std.debug.panic("{s} cannot find {s}", .{ native_compiler, library });
        break :blk path;
    } else null;
    const native_test_filter = b.option(
        []const u8,
        "native-test-filter",
        "Run only matching native tests",
    );
    const native_filters: []const []const u8 = if (native_test_filter) |filter| &.{filter} else &.{};
    const handshake_pairs = b.option(usize, "handshake-pairs", "Concurrent native test pairs (1-100)") orelse 8;
    if (handshake_pairs == 0 or handshake_pairs > 100) @panic("handshake-pairs must be 1-100");

    const tracy = b.option(bool, "tracy", "Emit Tracy profiler zones") orelse false;
    const sanitize_thread = b.option(bool, "sanitize-thread", "Instrument nethernet and the stress harness with TSan") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(usize, "fuzz_iterations", fuzz_iterations);
    build_options.addOption(usize, "handshake_pairs", handshake_pairs);

    // ASan cannot unpoison Zig's unaligned signal stack when native code throws.
    const runtime_options = b.addOptions();
    runtime_options.addOption(bool, "signal_stack", native_sanitizer != .address);
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (native_sanitizer == .address) blk: {
        const source = b.graph.zig_lib_directory.handle.readFileAlloc(b.graph.io, "compiler/test_runner.zig", b.allocator, .limited(1 << 20)) catch |err|
            std.debug.panic("cannot read the Zig test runner: {t}", .{err});
        const options = "pub const std_options: std.Options = .{\n";
        if (std.mem.indexOf(u8, source, options) == null) @panic("unexpected Zig test runner layout");
        const patched = std.mem.replaceOwned(u8, b.allocator, source, options, options ++ "    .signal_stack_size = null,\n") catch @panic("OOM");
        break :blk .{ .path = b.addWriteFiles().add("test_runner.zig", patched), .mode = .server };
    } else null;

    const trace_options = b.addOptions();
    trace_options.addOption(bool, "tracy", tracy);

    const nethernet = b.addModule("nethernet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addNative(b, nethernet, target, native_prefix);
    nethernet.addOptions("trace_options", trace_options);
    if (sanitize_thread) nethernet.sanitize_thread = true;
    if (tracy) {
        if (b.lazyDependency("ztracy", .{
            .target = target,
            .optimize = optimize,
            .enable_ztracy = true,
        })) |ztracy| {
            nethernet.addImport("ztracy", ztracy.module("root"));
            nethernet.linkLibrary(ztracy.artifact("tracy"));
        }
    }

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
    integration_module.addOptions("build_options", build_options);
    const integration_tests = b.addTest(.{
        .root_module = integration_module,
        .filters = native_filters,
        .test_runner = test_runner,
    });
    const run_integration = b.addRunArtifact(integration_tests);
    addNativeRuntime(b, run_integration, target, native_prefix, sanitizer_runtime);

    const library_tests = b.addTest(.{
        .root_module = nethernet,
        .filters = native_filters,
        .test_runner = test_runner,
    });
    const run_library_tests = b.addRunArtifact(library_tests);
    addNativeRuntime(b, run_library_tests, target, native_prefix, sanitizer_runtime);

    const integration_step = b.step(
        "test-integration",
        "Run real WebRTC, endpoint, LAN, and network integration tests",
    );
    integration_step.dependOn(&run_library_tests.step);
    integration_step.dependOn(&run_integration.step);

    inline for (.{
        .{ "client", "examples/client.zig" },
        .{ "server", "examples/server.zig" },
        .{ "minecraft", "examples/minecraft.zig" },
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
        b.installDirectory(.{
            .source_dir = .{ .cwd_relative = b.pathJoin(&.{ native_prefix, "bin" }) },
            .install_dir = .bin,
            .install_subdir = "",
            .include_extensions = &.{".dll"},
        });
    }

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

    const stress_module = createModule(b, "tests/bench/stress.zig", target, optimize);
    stress_module.addImport("nethernet", nethernet);
    stress_module.addOptions("runtime_options", runtime_options);
    if (sanitize_thread) stress_module.sanitize_thread = true;
    if (target.result.os.tag == .windows) stress_module.linkSystemLibrary("psapi", .{});

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
    addNativeRuntime(b, run_stress, target, native_prefix, sanitizer_runtime);
    if (b.args) |args| run_stress.addArgs(args);
    const stress_step = b.step(
        "stress",
        "Run configurable real-transport stress diagnostics",
    );
    stress_step.dependOn(&run_stress.step);

    const echo_module = createModule(b, "tests/bench/echo.zig", target, optimize);
    echo_module.addImport("nethernet", nethernet);
    const echo = b.addExecutable(.{ .name = "nethernet-echo", .root_module = echo_module });
    b.step("echo-install", "Install the out-of-process echo server").dependOn(&b.addInstallArtifact(echo, .{}).step);

    const run_stress_smoke = b.addRunArtifact(stress);
    addNativeRuntime(b, run_stress_smoke, target, native_prefix, sanitizer_runtime);
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
