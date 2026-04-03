// ── build.sig — Sig build configuration using sig_build APIs ─────────────
//
// This file defines the build graph for the Sig compiler project.
// It uses the sig_build zero-allocator build system exclusively.
// Zero references to upstream build APIs or allocator-accepting functions.
//
const sig_build = @import("sig_build");
const sig = @import("sig");
const std = @import("std"); // Only for std.SemanticVersion

// ── Version constants ────────────────────────────────────────────────────
// CI workflows grep these constants to resolve release versions.
// sig_version struct is the source of truth; sig_version_string is derived.
// Grep patterns: sig_version.*major = \K\d+, sig_version.*minor = \K\d+, etc.
const zig_version: std.SemanticVersion = .{ .major = 0, .minor = 16, .patch = 0 };
const sig_version = .{ .major = 0, .minor = 0, .patch = 4, .pre = "dev" };
const sig_version_string = "0.0.4-dev";

// ── Step function stubs ──────────────────────────────────────────────────
// Placeholder step functions for steps whose execution logic will be wired
// in the build runner scheduler (task 1.11). For now they are no-ops —
// the build runner dispatches the actual work based on step metadata.

fn noopStep(ctx: *sig_build.Step_Context) sig_build.SigError!void {
    _ = ctx;
}

// ── Build entry point ────────────────────────────────────────────────────

pub fn build(ctx: *sig_build.Build_Context) !void {
    // ── Wire version constants to Build_Context ──────────────────────
    ctx.zig_version_major = zig_version.major;
    ctx.zig_version_minor = zig_version.minor;
    ctx.zig_version_patch = zig_version.patch;
    @memcpy(ctx.sig_version[0..sig_version_string.len], sig_version_string);
    ctx.sig_version_len = sig_version_string.len;

    // ── Build options ────────────────────────────────────────────────
    // Option names preserved for CI grep compatibility.
    const skip_lib = ctx.option(bool, "no-lib", "Skip copying of lib/ files and langref to installation prefix") orelse false;
    const skip_langref = ctx.option(bool, "no-langref", "Skip copying of langref to the installation prefix") orelse skip_lib;
    const lib_files_only = ctx.option(bool, "lib-files-only", "Only install library files") orelse false;
    const no_bin = ctx.option(bool, "no-bin", "Skip emitting compiler binary") orelse false;

    // Target and optimization (read from -D flags, fall back to ctx defaults)
    const has_target = ctx.target.arch_len > 0;

    // Compiler feature flags
    const static_llvm = ctx.option(bool, "static-llvm", "Disable integration with system-installed LLVM, Clang, LLD, and libc++") orelse false;
    _ = ctx.option(bool, "enable-llvm", "Build self-hosted compiler with LLVM backend enabled") orelse static_llvm;
    _ = ctx.option(bool, "strip", "Omit debug information");
    _ = ctx.option(bool, "single-threaded", "Build artifacts that run in single threaded mode");

    // Tracy integration
    _ = ctx.option(bool, "tracy", "Enable Tracy integration") orelse false;
    _ = ctx.option(bool, "tracy-callstack", "Include callstack information with Tracy data") orelse false;
    _ = ctx.option(bool, "tracy-allocation", "Include allocation information with Tracy data") orelse false;
    _ = ctx.option(u32, "tracy-callstack-depth", "Declare callstack depth for Tracy data") orelse 10;

    // Test matrix options
    _ = ctx.option(bool, "skip-debug", "Main test suite skips debug builds") orelse false;
    _ = ctx.option(bool, "skip-release", "Main test suite skips release builds") orelse false;
    _ = ctx.option(bool, "skip-release-small", "Main test suite skips release-small builds") orelse false;
    _ = ctx.option(bool, "skip-release-fast", "Main test suite skips release-fast builds") orelse false;
    _ = ctx.option(bool, "skip-release-safe", "Main test suite skips release-safe builds") orelse false;
    _ = ctx.option(bool, "skip-non-native", "Main test suite skips non-native builds") orelse false;
    _ = ctx.option(bool, "skip-libc", "Main test suite skips tests that link libc") orelse false;
    _ = ctx.option(bool, "skip-single-threaded", "Main test suite skips tests that are single-threaded") orelse false;
    _ = ctx.option(bool, "skip-compile-errors", "Main test suite skips compile error tests") orelse false;
    _ = ctx.option(bool, "skip-spirv", "Main test suite skips targets with spirv32/spirv64 architecture") orelse false;
    _ = ctx.option(bool, "skip-wasm", "Main test suite skips targets with wasm32/wasm64 architecture") orelse false;
    _ = ctx.option(bool, "skip-freebsd", "Main test suite skips targets with freebsd OS") orelse false;
    _ = ctx.option(bool, "skip-netbsd", "Main test suite skips targets with netbsd OS") orelse false;
    _ = ctx.option(bool, "skip-openbsd", "Main test suite skips targets with openbsd OS") orelse false;
    _ = ctx.option(bool, "skip-windows", "Main test suite skips targets with windows OS") orelse false;
    _ = ctx.option(bool, "skip-darwin", "Main test suite skips targets with darwin OSs") orelse false;
    _ = ctx.option(bool, "skip-linux", "Main test suite skips targets with linux OS") orelse false;
    _ = ctx.option(bool, "skip-llvm", "Main test suite skips targets that use LLVM backend") orelse false;

    // Test filters
    _ = ctx.option(bool, "test-filter", "Skip tests that do not match any filter");
    _ = ctx.option(bool, "test-target-filter", "Skip tests whose target triple do not match any filter");

    // Version override
    _ = ctx.option(bool, "version-string", "Override Zig version string");

    // Sig mode
    _ = ctx.option(bool, "sig-mode", "Sig diagnostics mode (strict or warn)");

    // ── Compiler compilation step ────────────────────────────────────
    if (!no_bin) {
        _ = try ctx.addCompileStep(.{
            .source_path = "src/main.zig",
            .output_name = "sig",
            .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
            .optimize = ctx.optimize,
            .target = if (has_target) &ctx.target else null,
            .imports = &.{},
            .compiler_path = "",
        });
    }

    // ── Lib installation step ────────────────────────────────────────
    // Exclusion filtering is handled at execution time by the install step
    // function (task 1.11). The exclusion list is documented here for reference:
    //   .gz, .z.0, .z.9, .zst.3, .zst.19, .lzma, .xz, .tzif, .tar,
    //   .expect, .expect-noinput, .golden, .input, test.zig, README.md,
    //   compress-e.txt, compress-gettysburg.txt, compress-pi.txt,
    //   rfc1951.txt, rfc1952.txt, rfc8478.txt
    if (!skip_lib) {
        _ = try ctx.addInstallStep(.{
            .source_dir = "lib",
            .dest_dir = "lib/zig",
        });
    }

    if (lib_files_only) return;

    // ── Test steps ───────────────────────────────────────────────────
    // "test" is the umbrella step that depends on all sub-test steps.
    const test_step = try ctx.addStep("test", "Run all tests", &noopStep);

    // test-unit: compiler source unit tests
    const test_unit = try ctx.addTestStep(.{
        .name = "test-unit",
        .source_path = "src/main.zig",
        .imports = &.{},
    });
    try ctx.addDependency(test_step, test_unit);

    // test-cases: compiler test cases (invokes sig test-cases at execution time)
    const test_cases = try ctx.addStep("test-cases", "Run the main compiler test cases", &noopStep);
    try ctx.addDependency(test_step, test_cases);

    // test-modules: per-target module tests (invokes sig test-modules at execution time)
    const test_modules = try ctx.addStep("test-modules", "Run the per-target module tests", &noopStep);
    try ctx.addDependency(test_step, test_modules);

    // test-fmt: formatting check (invokes sig fmt --check at execution time)
    const test_fmt = try ctx.addStep("test-fmt", "Check source files have conforming formatting", &noopStep);
    try ctx.addDependency(test_step, test_fmt);

    // test-sig: sig property + unit tests (invokes sig test on each file at execution time)
    const test_sig = try ctx.addStep("test-sig", "Run Sig property and unit tests", &noopStep);
    try ctx.addDependency(test_step, test_sig);

    // ── fmt step ─────────────────────────────────────────────────────
    // Formats: lib, src, test, tools, build.sig, build.sig.zon
    // Excludes: test/cases, test/behavior/zon
    _ = try ctx.addStep("fmt", "Format source files", &noopStep);

    // ── Documentation steps ──────────────────────────────────────────
    if (!skip_langref) {
        _ = try ctx.addStep("langref", "Build and install the language reference", &noopStep);
    } else {
        // Register as no-op so `sig build langref` doesn't error with "unknown step"
        _ = try ctx.addStep("langref", "Build and install the language reference (skipped: -Dno-langref)", &noopStep);
    }

    const docs_step = try ctx.addStep("docs", "Build and install documentation", &noopStep);
    _ = docs_step;

    _ = try ctx.addStep("std-docs", "Build and install the standard library documentation", &noopStep);

    // ── Benchmark step ───────────────────────────────────────────────
    _ = try ctx.addStep("bench-sig", "Run Sig benchmark suite", &noopStep);

    // ── Build runner self-hosting step ───────────────────────────────
    {
        // Wire sig and std imports for the build runner compilation.
        var sig_import: sig_build.Import_Entry = .{};
        const sig_name = "sig";
        const sig_path = "lib/sig/sig.zig";
        @memcpy(sig_import.name[0..sig_name.len], sig_name);
        sig_import.name_len = sig_name.len;
        @memcpy(sig_import.path[0..sig_path.len], sig_path);
        sig_import.path_len = sig_path.len;

        var std_import: sig_build.Import_Entry = .{};
        const std_name = "std";
        const std_path = "lib/std/std.zig";
        @memcpy(std_import.name[0..std_name.len], std_name);
        std_import.name_len = std_name.len;
        @memcpy(std_import.path[0..std_path.len], std_path);
        std_import.path_len = std_path.len;

        const imports = [_]sig_build.Import_Entry{ sig_import, std_import };

        _ = try ctx.addCompileStep(.{
            .source_path = "tools/sig_build/main.sig",
            .output_name = "build-runner",
            .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
            .optimize = .Debug,
            .target = null,
            .imports = &imports,
            .compiler_path = "",
        });
    }
}
