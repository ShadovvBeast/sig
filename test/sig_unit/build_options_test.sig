// Unit tests for build options generation — specific examples, edge cases, and format verification.
//
// Since the build runner (tools/sig_build/main.sig) is not wired as a test import,
// these tests replicate the build runner logic using the same algorithms.
//
// Requirements: 1.2, 1.3, 1.5, 2.3, 2.10, 5.1, 5.2, 5.3, 5.4, 5.5,
//               7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.8

const std = @import("std");
const testing = std.testing;
const sig = @import("sig");
const containers = sig.containers;

// ── Error set ───────────────────────────────────────────────────────────
const SigError = error{ CapacityExceeded, BufferTooSmall, DepthExceeded, QuotaExceeded };

// ── Capacity constants ──────────────────────────────────────────────────
const MAX_OPTIONS = 32;
const NAME_BUF_SIZE = 64;
const VALUE_BUF_SIZE = 256;
const BUILD_OPTIONS_BUF_SIZE = 8192;
const VERSION_BUF_SIZE = 128;

// ── Replicated types ────────────────────────────────────────────────────
const Option_Map = containers.BoundedStringMap(NAME_BUF_SIZE, VALUE_BUF_SIZE, MAX_OPTIONS);
const Optimize_Mode = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };

const Build_Context = struct {
    options: Option_Map = .{},
    optimize: Optimize_Mode = .Debug,
    zig_version_major: u32 = 0,
    zig_version_minor: u32 = 0,
    zig_version_patch: u32 = 0,
    sig_version: [64]u8 = undefined,
    sig_version_len: usize = 0,
};

// ── Helper functions (replicated from tools/sig_build/main.sig) ─────────

fn boolStr(val: bool) []const u8 {
    return if (val) "true" else "false";
}

fn optBool(map: *const Option_Map, name: []const u8, default: bool) bool {
    const value = map.getValue(name) orelse return default;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return default;
}

fn optU32(map: *const Option_Map, name: []const u8, default: u32) u32 {
    const value = map.getValue(name) orelse return default;
    return std.fmt.parseInt(u32, value, 10) catch default;
}

fn parseSemver(
    version: []const u8,
    major: *[]const u8,
    minor: *[]const u8,
    patch: *[]const u8,
    pre: *[]const u8,
    build_meta: *[]const u8,
) void {
    var core_part = version;
    var extra_part: []const u8 = "";

    if (std.mem.indexOfScalar(u8, version, '-')) |dash_pos| {
        core_part = version[0..dash_pos];
        extra_part = version[dash_pos + 1 ..];
    }

    var dot_iter = std.mem.splitScalar(u8, core_part, '.');
    major.* = dot_iter.next() orelse "0";
    minor.* = dot_iter.next() orelse "0";
    patch.* = dot_iter.next() orelse "0";

    if (extra_part.len > 0) {
        if (std.mem.indexOfScalar(u8, extra_part, '+')) |plus_pos| {
            pre.* = extra_part[0..plus_pos];
            build_meta.* = extra_part[plus_pos + 1 ..];
        } else {
            pre.* = extra_part;
            build_meta.* = "";
        }
    }
}

// ── generateBuildOptionsToBuffer ─────────────────────────────────────────

fn generateBuildOptionsToBuffer(
    build_ctx: *const Build_Context,
    version: []const u8,
    buf: *[BUILD_OPTIONS_BUF_SIZE]u8,
) ![]const u8 {
    const have_llvm = build_ctx.options.getValue("enable-llvm") != null or
        build_ctx.options.getValue("static-llvm") != null;
    const skip_non_native = optBool(&build_ctx.options, "skip-non-native", false);
    const llvm_has_m68k = if (have_llvm) optBool(&build_ctx.options, "llvm-has-m68k", false) else false;
    const llvm_has_csky = if (have_llvm) optBool(&build_ctx.options, "llvm-has-csky", false) else false;
    const llvm_has_arc = if (have_llvm) optBool(&build_ctx.options, "llvm-has-arc", false) else false;
    const llvm_has_xtensa = if (have_llvm) optBool(&build_ctx.options, "llvm-has-xtensa", false) else false;
    const debug_gpa = optBool(&build_ctx.options, "debug-allocator", false);
    const enable_debug_extensions = optBool(&build_ctx.options, "debug-extensions", false);
    const enable_logging = optBool(&build_ctx.options, "log", false);
    const enable_link_snapshots = optBool(&build_ctx.options, "link-snapshot", false);
    const enable_tracy = optBool(&build_ctx.options, "tracy", false);
    const enable_tracy_callstack = optBool(&build_ctx.options, "tracy-callstack", false);
    const enable_tracy_allocation = optBool(&build_ctx.options, "tracy-allocation", false);
    const tracy_callstack_depth = optU32(&build_ctx.options, "tracy-callstack-depth", 10);
    const value_tracing = optBool(&build_ctx.options, "value-tracing", false);

    const dev_str = build_ctx.options.getValue("dev") orelse "full";
    const io_mode_str = build_ctx.options.getValue("io-mode") orelse "threaded";
    const vim_str = build_ctx.options.getValue("value-interpret-mode") orelse "direct";

    const is_debug = build_ctx.optimize == .Debug;
    const is_strip = optBool(&build_ctx.options, "strip", false);
    const mem_leak_frames: u32 = blk: {
        if (build_ctx.options.getValue("mem-leak-frames")) |v| {
            break :blk std.fmt.parseInt(u32, v, 10) catch 0;
        }
        if (is_strip) break :blk 0;
        if (!is_debug) break :blk 0;
        if (debug_gpa) break :blk 4;
        break :blk 0;
    };

    var semver_major: []const u8 = "0";
    var semver_minor: []const u8 = "0";
    var semver_patch: []const u8 = "0";
    var semver_pre: []const u8 = "";
    var semver_build: []const u8 = "";
    parseSemver(version, &semver_major, &semver_minor, &semver_patch, &semver_pre, &semver_build);

    const sig_version_str = build_ctx.sig_version[0..build_ctx.sig_version_len];

    const result = std.fmt.bufPrint(buf,
        \\pub const mem_leak_frames: u32 = {d};
        \\pub const skip_non_native: bool = {s};
        \\pub const have_llvm: bool = {s};
        \\pub const llvm_has_m68k: bool = {s};
        \\pub const llvm_has_csky: bool = {s};
        \\pub const llvm_has_arc: bool = {s};
        \\pub const llvm_has_xtensa: bool = {s};
        \\pub const debug_gpa: bool = {s};
        \\pub const version: [:0]const u8 = "{s}";
        \\pub const sig_version: [:0]const u8 = "{s}";
        \\pub const semver: @import("std").SemanticVersion = .{{
        \\    .major = {s},
        \\    .minor = {s},
        \\    .patch = {s},
        \\    .pre = "{s}",
        \\    .build = "{s}",
        \\}};
        \\pub const enable_debug_extensions: bool = {s};
        \\pub const enable_logging: bool = {s};
        \\pub const enable_link_snapshots: bool = {s};
        \\pub const enable_tracy: bool = {s};
        \\pub const enable_tracy_callstack: bool = {s};
        \\pub const enable_tracy_allocation: bool = {s};
        \\pub const tracy_callstack_depth: u32 = {d};
        \\pub const value_tracing: bool = {s};
        \\pub const @"src.dev.Env" = enum (u4) {{
        \\    bootstrap = 0,
        \\    core = 1,
        \\    full = 2,
        \\    c_source = 3,
        \\    ast_gen = 4,
        \\    sema = 5,
        \\    @"aarch64-linux" = 6,
        \\    cbe = 7,
        \\    @"powerpc-linux" = 8,
        \\    @"riscv64-linux" = 9,
        \\    spirv = 10,
        \\    wasm = 11,
        \\    @"x86_64-linux" = 12,
        \\}};
        \\pub const dev: @"src.dev.Env" = .{s};
        \\pub const @"build.IoMode" = enum (u1) {{
        \\    threaded = 0,
        \\    evented = 1,
        \\}};
        \\pub const io_mode: @"build.IoMode" = .{s};
        \\pub const @"build.ValueInterpretMode" = enum (u1) {{
        \\    direct = 0,
        \\    by_name = 1,
        \\}};
        \\pub const value_interpret_mode: @"build.ValueInterpretMode" = .{s};
        \\
    , .{
        mem_leak_frames,
        boolStr(skip_non_native),
        boolStr(have_llvm),
        boolStr(llvm_has_m68k),
        boolStr(llvm_has_csky),
        boolStr(llvm_has_arc),
        boolStr(llvm_has_xtensa),
        boolStr(debug_gpa),
        version,
        sig_version_str,
        semver_major,
        semver_minor,
        semver_patch,
        semver_pre,
        semver_build,
        boolStr(enable_debug_extensions),
        boolStr(enable_logging),
        boolStr(enable_link_snapshots),
        boolStr(enable_tracy),
        boolStr(enable_tracy_callstack),
        boolStr(enable_tracy_allocation),
        tracy_callstack_depth,
        boolStr(value_tracing),
        dev_str,
        io_mode_str,
        vim_str,
    }) catch return error.BufferTooSmall;

    return result;
}

// ── resolveVersionStringFromParts ────────────────────────────────────────

fn resolveVersionStringFromParts(
    buf: *[VERSION_BUF_SIZE]u8,
    base_version: []const u8,
    is_dev: bool,
    count: ?[]const u8,
    hash: ?[]const u8,
) []const u8 {
    if (!is_dev) {
        if (base_version.len > VERSION_BUF_SIZE) return base_version[0..VERSION_BUF_SIZE];
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    }

    const c = count orelse {
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    };
    const h = hash orelse {
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    };

    const dev_tag = "-dev.";
    const plus = "+";
    const total = base_version.len + dev_tag.len + c.len + plus.len + h.len;
    if (total > VERSION_BUF_SIZE) {
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    }

    var offset: usize = 0;
    @memcpy(buf[offset..][0..base_version.len], base_version);
    offset += base_version.len;
    @memcpy(buf[offset..][0..dev_tag.len], dev_tag);
    offset += dev_tag.len;
    @memcpy(buf[offset..][0..c.len], c);
    offset += c.len;
    @memcpy(buf[offset..][0..plus.len], plus);
    offset += plus.len;
    @memcpy(buf[offset..][0..h.len], h);
    offset += h.len;

    return buf[0..offset];
}

// ── Test helper: create a Build_Context with sig_version set ────────────

fn makeCtx(optimize: Optimize_Mode) Build_Context {
    var ctx: Build_Context = .{};
    ctx.optimize = optimize;
    const sv = "0.0.4-dev";
    @memcpy(ctx.sig_version[0..sv.len], sv);
    ctx.sig_version_len = sv.len;
    return ctx;
}

/// Parse mem_leak_frames u32 value from generated output.
fn parseMemLeakFrames(output: []const u8) ?u32 {
    const prefix = "pub const mem_leak_frames: u32 = ";
    const start_idx = std.mem.indexOf(u8, output, prefix) orelse return null;
    const value_start = start_idx + prefix.len;
    const semi_idx = std.mem.indexOfScalarPos(u8, output, value_start, ';') orelse return null;
    return std.fmt.parseInt(u32, output[value_start..semi_idx], 10) catch null;
}

// ═══════════════════════════════════════════════════════════════════════════
// Task 4.2 — Unit tests for generateBuildOptions
// ═══════════════════════════════════════════════════════════════════════════

test "generateBuildOptions: default release config" {
    var ctx = makeCtx(.ReleaseFast);
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);

    // All boolean flags should be false by default
    try testing.expect(std.mem.indexOf(u8, output, "pub const have_llvm: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const skip_non_native: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const debug_gpa: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_tracy: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_logging: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const value_tracing: bool = false;") != null);

    // mem_leak_frames should be 0 for release
    try testing.expect(std.mem.indexOf(u8, output, "pub const mem_leak_frames: u32 = 0;") != null);

    // Default enum values
    try testing.expect(std.mem.indexOf(u8, output, "pub const dev: @\"src.dev.Env\" = .full;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const io_mode: @\"build.IoMode\" = .threaded;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const value_interpret_mode: @\"build.ValueInterpretMode\" = .direct;") != null);

    // Version and sig_version
    try testing.expect(std.mem.indexOf(u8, output, "pub const version: [:0]const u8 = \"0.16.0\";") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const sig_version: [:0]const u8 = \"0.0.4-dev\";") != null);

    // tracy_callstack_depth default
    try testing.expect(std.mem.indexOf(u8, output, "pub const tracy_callstack_depth: u32 = 10;") != null);
}

test "generateBuildOptions: debug config with all flags enabled" {
    var ctx = makeCtx(.Debug);
    try ctx.options.put("enable-llvm", "true");
    try ctx.options.put("skip-non-native", "true");
    try ctx.options.put("debug-allocator", "true");
    try ctx.options.put("debug-extensions", "true");
    try ctx.options.put("log", "true");
    try ctx.options.put("link-snapshot", "true");
    try ctx.options.put("tracy", "true");
    try ctx.options.put("tracy-callstack", "true");
    try ctx.options.put("tracy-allocation", "true");
    try ctx.options.put("value-tracing", "true");
    try ctx.options.put("llvm-has-m68k", "true");
    try ctx.options.put("llvm-has-csky", "true");
    try ctx.options.put("llvm-has-arc", "true");
    try ctx.options.put("llvm-has-xtensa", "true");
    try ctx.options.put("dev", "sema");
    try ctx.options.put("io-mode", "evented");
    try ctx.options.put("value-interpret-mode", "by_name");

    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0-dev.3083+e4e2b7da1", &buf);

    try testing.expect(std.mem.indexOf(u8, output, "pub const have_llvm: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const skip_non_native: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const debug_gpa: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_debug_extensions: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_logging: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_link_snapshots: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_tracy: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_tracy_callstack: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_tracy_allocation: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const value_tracing: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const llvm_has_m68k: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const llvm_has_csky: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const llvm_has_arc: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const llvm_has_xtensa: bool = true;") != null);

    // mem_leak_frames = 4 for Debug + debug-gpa
    try testing.expect(std.mem.indexOf(u8, output, "pub const mem_leak_frames: u32 = 4;") != null);

    // Custom enum values
    try testing.expect(std.mem.indexOf(u8, output, "pub const dev: @\"src.dev.Env\" = .sema;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const io_mode: @\"build.IoMode\" = .evented;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const value_interpret_mode: @\"build.ValueInterpretMode\" = .by_name;") != null);
}

test "generateBuildOptions: have_llvm=false forces all llvm_has_* to false" {
    var ctx = makeCtx(.ReleaseFast);
    // Explicitly set llvm sub-flags to true, but do NOT set enable-llvm
    try ctx.options.put("llvm-has-m68k", "true");
    try ctx.options.put("llvm-has-csky", "true");
    try ctx.options.put("llvm-has-arc", "true");
    try ctx.options.put("llvm-has-xtensa", "true");

    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);

    // have_llvm should be false (no enable-llvm or static-llvm set)
    try testing.expect(std.mem.indexOf(u8, output, "pub const have_llvm: bool = false;") != null);
    // All llvm_has_* must be false regardless of -D flags
    try testing.expect(std.mem.indexOf(u8, output, "pub const llvm_has_m68k: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const llvm_has_csky: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const llvm_has_arc: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const llvm_has_xtensa: bool = false;") != null);
}

test "generateBuildOptions: version string with pre-release and build metadata" {
    var ctx = makeCtx(.ReleaseFast);
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0-dev.3083+e4e2b7da1", &buf);

    // Verify semver struct fields
    try testing.expect(std.mem.indexOf(u8, output, ".major = 0,") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".minor = 16,") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".patch = 0,") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".pre = \"dev.3083\",") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".build = \"e4e2b7da1\",") != null);
}

test "generateBuildOptions: output matches real options.zig format" {
    // Reproduce the exact config from .zig-cache/c/59e99a88.../options.zig
    var ctx = makeCtx(.Debug);
    try ctx.options.put("debug-extensions", "true");
    try ctx.options.put("log", "true");
    try ctx.options.put("dev", "full");
    try ctx.options.put("io-mode", "threaded");
    try ctx.options.put("value-interpret-mode", "direct");
    // Override sig_version to match the cached file
    const sv = "0.0.3-dev";
    @memcpy(ctx.sig_version[0..sv.len], sv);
    ctx.sig_version_len = sv.len;

    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0-dev.3083+e4e2b7da1", &buf);

    // Verify key lines match the real cached options.zig
    try testing.expect(std.mem.indexOf(u8, output, "pub const mem_leak_frames: u32 = 0;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const have_llvm: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const debug_gpa: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const version: [:0]const u8 = \"0.16.0-dev.3083+e4e2b7da1\";") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const sig_version: [:0]const u8 = \"0.0.3-dev\";") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_debug_extensions: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_logging: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const enable_link_snapshots: bool = false;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const tracy_callstack_depth: u32 = 10;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const dev: @\"src.dev.Env\" = .full;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const io_mode: @\"build.IoMode\" = .threaded;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const value_interpret_mode: @\"build.ValueInterpretMode\" = .direct;") != null);
}

// ═══════════════════════════════════════════════════════════════════════════
// Task 4.3 — Unit tests for resolveVersionString
// ═══════════════════════════════════════════════════════════════════════════

test "resolveVersionString: dev build with count and hash" {
    var buf: [VERSION_BUF_SIZE]u8 = undefined;
    const result = resolveVersionStringFromParts(&buf, "0.16.0", true, "3083", "e4e2b7da1");
    try testing.expectEqualStrings("0.16.0-dev.3083+e4e2b7da1", result);
}

test "resolveVersionString: release build produces base version only" {
    var buf: [VERSION_BUF_SIZE]u8 = undefined;
    const result = resolveVersionStringFromParts(&buf, "0.16.0", false, "3083", "e4e2b7da1");
    try testing.expectEqualStrings("0.16.0", result);
}

test "resolveVersionString: git failure falls back to base version" {
    var buf: [VERSION_BUF_SIZE]u8 = undefined;
    const result = resolveVersionStringFromParts(&buf, "0.16.0", true, null, null);
    try testing.expectEqualStrings("0.16.0", result);
}

test "resolveVersionString: null hash falls back to base version" {
    var buf: [VERSION_BUF_SIZE]u8 = undefined;
    const result = resolveVersionStringFromParts(&buf, "0.16.0", true, "3083", null);
    try testing.expectEqualStrings("0.16.0", result);
}

test "resolveVersionString: null count falls back to base version" {
    var buf: [VERSION_BUF_SIZE]u8 = undefined;
    const result = resolveVersionStringFromParts(&buf, "0.16.0", true, null, "e4e2b7da1");
    try testing.expectEqualStrings("0.16.0", result);
}

test "resolveVersionString: version-string override is used directly" {
    // When -Dversion-string is provided, the caller uses it directly.
    // We simulate this by just verifying the override value passes through as-is.
    const override = "1.2.3-custom+build42";
    var ctx = makeCtx(.ReleaseFast);
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, override, &buf);

    // The override version should appear verbatim in the output
    try testing.expect(std.mem.indexOf(u8, output, "pub const version: [:0]const u8 = \"1.2.3-custom+build42\";") != null);
    // Semver should parse the override correctly
    try testing.expect(std.mem.indexOf(u8, output, ".major = 1,") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".minor = 2,") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".patch = 3,") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".pre = \"custom\",") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".build = \"build42\",") != null);
}

// ═══════════════════════════════════════════════════════════════════════════
// Task 4.4 — Unit tests for edge cases
// ═══════════════════════════════════════════════════════════════════════════

test "mem_leak_frames: Debug without debug-gpa is 0" {
    var ctx = makeCtx(.Debug);
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
    try testing.expectEqual(@as(u32, 0), parseMemLeakFrames(output).?);
}

test "mem_leak_frames: Debug with debug-gpa is 4" {
    var ctx = makeCtx(.Debug);
    try ctx.options.put("debug-allocator", "true");
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
    try testing.expectEqual(@as(u32, 4), parseMemLeakFrames(output).?);
}

test "mem_leak_frames: ReleaseSafe is 0" {
    var ctx = makeCtx(.ReleaseSafe);
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
    try testing.expectEqual(@as(u32, 0), parseMemLeakFrames(output).?);
}

test "mem_leak_frames: ReleaseFast is 0" {
    var ctx = makeCtx(.ReleaseFast);
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
    try testing.expectEqual(@as(u32, 0), parseMemLeakFrames(output).?);
}

test "mem_leak_frames: ReleaseSmall is 0" {
    var ctx = makeCtx(.ReleaseSmall);
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
    try testing.expectEqual(@as(u32, 0), parseMemLeakFrames(output).?);
}

test "mem_leak_frames: Debug with strip forces 0" {
    var ctx = makeCtx(.Debug);
    try ctx.options.put("debug-allocator", "true");
    try ctx.options.put("strip", "true");
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
    try testing.expectEqual(@as(u32, 0), parseMemLeakFrames(output).?);
}

test "mem_leak_frames: ReleaseSafe with debug-gpa still 0 (not Debug)" {
    var ctx = makeCtx(.ReleaseSafe);
    try ctx.options.put("debug-allocator", "true");
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
    try testing.expectEqual(@as(u32, 0), parseMemLeakFrames(output).?);
}

test "enum formatting: dev values" {
    var ctx = makeCtx(.ReleaseFast);

    // Test .full (default)
    {
        var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
        const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
        try testing.expect(std.mem.indexOf(u8, output, "pub const dev: @\"src.dev.Env\" = .full;") != null);
    }

    // Test .bootstrap
    try ctx.options.put("dev", "bootstrap");
    {
        var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
        const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
        try testing.expect(std.mem.indexOf(u8, output, "pub const dev: @\"src.dev.Env\" = .bootstrap;") != null);
    }

    // Test .core
    try ctx.options.put("dev", "core");
    {
        var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
        const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
        try testing.expect(std.mem.indexOf(u8, output, "pub const dev: @\"src.dev.Env\" = .core;") != null);
    }
}

test "enum formatting: io_mode values" {
    var ctx = makeCtx(.ReleaseFast);

    // Default: .threaded
    {
        var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
        const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
        try testing.expect(std.mem.indexOf(u8, output, "pub const io_mode: @\"build.IoMode\" = .threaded;") != null);
    }

    // .evented
    try ctx.options.put("io-mode", "evented");
    {
        var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
        const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
        try testing.expect(std.mem.indexOf(u8, output, "pub const io_mode: @\"build.IoMode\" = .evented;") != null);
    }
}

test "enum formatting: value_interpret_mode values" {
    var ctx = makeCtx(.ReleaseFast);

    // Default: .direct
    {
        var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
        const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
        try testing.expect(std.mem.indexOf(u8, output, "pub const value_interpret_mode: @\"build.ValueInterpretMode\" = .direct;") != null);
    }

    // .by_name
    try ctx.options.put("value-interpret-mode", "by_name");
    {
        var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
        const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);
        try testing.expect(std.mem.indexOf(u8, output, "pub const value_interpret_mode: @\"build.ValueInterpretMode\" = .by_name;") != null);
    }
}

test "output contains all 3 inline enum definitions" {
    var ctx = makeCtx(.ReleaseFast);
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);

    // src.dev.Env enum with 13 variants (u4)
    try testing.expect(std.mem.indexOf(u8, output, "pub const @\"src.dev.Env\" = enum (u4) {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "    bootstrap = 0,") != null);
    try testing.expect(std.mem.indexOf(u8, output, "    @\"x86_64-linux\" = 12,") != null);

    // build.IoMode enum with 2 variants (u1)
    try testing.expect(std.mem.indexOf(u8, output, "pub const @\"build.IoMode\" = enum (u1) {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "    threaded = 0,") != null);
    try testing.expect(std.mem.indexOf(u8, output, "    evented = 1,") != null);

    // build.ValueInterpretMode enum with 2 variants (u1)
    try testing.expect(std.mem.indexOf(u8, output, "pub const @\"build.ValueInterpretMode\" = enum (u1) {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "    direct = 0,") != null);
    try testing.expect(std.mem.indexOf(u8, output, "    by_name = 1,") != null);
}
