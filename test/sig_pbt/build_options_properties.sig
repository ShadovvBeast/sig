// Feature: sig-compiler-entry — Property-based tests for build options generation.
//
// Since the build runner (tools/sig_build/main.sig) is not wired as a test import,
// these tests replicate the build runner logic using the same algorithms.
//
// Requirements: 1.2, 1.3, 2.3, 2.4, 2.6, 2.7, 2.8, 2.9, 2.10,
//               3.2, 3.3, 3.4, 5.2, 5.3, 6.2, 7.1, 7.2, 7.3,
//               7.4, 7.5, 7.6, 7.7, 7.8, 7.9

const std = @import("std");
const harness = @import("harness");
const sig = @import("sig");
const containers = sig.containers;

// ── Error set ───────────────────────────────────────────────────────────
const SigError = error{ CapacityExceeded, BufferTooSmall, DepthExceeded, QuotaExceeded };

// ── Capacity constants (smaller for tests) ──────────────────────────────
const MAX_OPTIONS = 32;
const NAME_BUF_SIZE = 64;
const VALUE_BUF_SIZE = 256;
const PATH_BUF_SIZE = 4096;
const BUILD_OPTIONS_BUF_SIZE = 8192;
const VERSION_BUF_SIZE = 128;
const MAX_CMD_ARGS = 32;

// ── Replicated Option_Map ───────────────────────────────────────────────
const Option_Map = containers.BoundedStringMap(NAME_BUF_SIZE, VALUE_BUF_SIZE, MAX_OPTIONS);

// ── Replicated Optimize_Mode ────────────────────────────────────────────
const Optimize_Mode = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };

// ── Replicated Build_Context (simplified for build options tests) ───────
const Build_Context = struct {
    options: Option_Map = .{},
    optimize: Optimize_Mode = .Debug,
    zig_version_major: u32 = 0,
    zig_version_minor: u32 = 0,
    zig_version_patch: u32 = 0,
    sig_version: [64]u8 = undefined,
    sig_version_len: usize = 0,
};

// ── Replicated Command_Buffer (for Property 7) ─────────────────────────

const Import_Entry = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    path: [PATH_BUF_SIZE]u8 = undefined,
    path_len: usize = 0,
};

const Command_Buffer = struct {
    args: [MAX_CMD_ARGS][PATH_BUF_SIZE]u8 = undefined,
    arg_lens: [MAX_CMD_ARGS]usize = [_]usize{0} ** MAX_CMD_ARGS,
    arg_count: usize = 0,

    pub fn addArg(self: *Command_Buffer, arg: []const u8) SigError!void {
        if (self.arg_count >= MAX_CMD_ARGS) return error.CapacityExceeded;
        if (arg.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(self.args[self.arg_count][0..arg.len], arg);
        self.arg_lens[self.arg_count] = arg.len;
        self.arg_count += 1;
    }

    pub fn getArg(self: *const Command_Buffer, i: usize) []const u8 {
        return self.args[i][0..self.arg_lens[i]];
    }
};

const Compile_Options = struct {
    source_path: []const u8,
    output_name: []const u8,
    cache_dir: []const u8,
    optimize: Optimize_Mode,
    target: ?[]const u8,
    imports: []const Import_Entry,
    compiler_path: []const u8,
};

// ── Helper functions (replicated from tools/sig_build/main.sig) ─────────

/// Return "true" or "false" as a string slice for bool formatting.
fn boolStr(val: bool) []const u8 {
    return if (val) "true" else "false";
}

/// Read a boolean option from the map, returning `default` if absent.
fn optBool(map: *const Option_Map, name: []const u8, default: bool) bool {
    const value = map.getValue(name) orelse return default;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return default;
}

/// Read a u32 option from the map, returning `default` if absent or unparseable.
fn optU32(map: *const Option_Map, name: []const u8, default: u32) u32 {
    const value = map.getValue(name) orelse return default;
    return std.fmt.parseInt(u32, value, 10) catch default;
}

/// Parse a semver version string into its components.
/// Handles "M.N.P", "M.N.P-pre", and "M.N.P-pre+build" formats.
fn parseSemver(
    version: []const u8,
    major: *[]const u8,
    minor: *[]const u8,
    patch: *[]const u8,
    pre: *[]const u8,
    build_meta: *[]const u8,
) void {
    // Split on first '-' to separate "M.N.P" from optional "pre+build"
    var core_part = version;
    var extra_part: []const u8 = "";

    if (std.mem.indexOfScalar(u8, version, '-')) |dash_pos| {
        core_part = version[0..dash_pos];
        extra_part = version[dash_pos + 1 ..];
    }

    // Parse M.N.P from core_part
    var dot_iter = std.mem.splitScalar(u8, core_part, '.');
    major.* = dot_iter.next() orelse "0";
    minor.* = dot_iter.next() orelse "0";
    patch.* = dot_iter.next() orelse "0";

    // Parse pre and build from extra_part
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

// ── generateBuildOptionsToBuffer ─────────────────────────────────────────────
//
// Replicated from tools/sig_build/main.sig generateBuildOptions, but writes
// to a caller-provided buffer instead of a file. Returns the formatted content
// as a slice so tests can parse and verify the output.

fn generateBuildOptionsToBuffer(
    build_ctx: *const Build_Context,
    version: []const u8,
    buf: *[BUILD_OPTIONS_BUF_SIZE]u8,
) ![]const u8 {
    // 1. Read option flags with defaults
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

    // dev mode: default .full
    const dev_str = build_ctx.options.getValue("dev") orelse "full";
    // io_mode: default .threaded
    const io_mode_str = build_ctx.options.getValue("io-mode") orelse "threaded";
    // value_interpret_mode: default .direct
    const vim_str = build_ctx.options.getValue("value-interpret-mode") orelse "direct";

    // mem_leak_frames: 0 for release/strip, 4 for Debug+debug-gpa
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

    // 2. Parse semver from version string
    var semver_major: []const u8 = "0";
    var semver_minor: []const u8 = "0";
    var semver_patch: []const u8 = "0";
    var semver_pre: []const u8 = "";
    var semver_build: []const u8 = "";
    parseSemver(version, &semver_major, &semver_minor, &semver_patch, &semver_pre, &semver_build);

    // 3. Get sig_version from Build_Context
    const sig_version_str = build_ctx.sig_version[0..build_ctx.sig_version_len];

    // 4. Format all declarations into the buffer
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

// ── resolveVersionStringFromParts ────────────────────────────────────────────
//
// Replicated version formatting logic from resolveVersionString, but takes
// pre-computed count and hash strings instead of running git. This lets us
// test the formatting logic deterministically.

fn resolveVersionStringFromParts(
    buf: *[VERSION_BUF_SIZE]u8,
    base_version: []const u8,
    is_dev: bool,
    count: ?[]const u8,
    hash: ?[]const u8,
) []const u8 {
    // Release builds: no dev suffix.
    if (!is_dev) {
        if (base_version.len > VERSION_BUF_SIZE) return base_version[0..VERSION_BUF_SIZE];
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    }

    // Dev builds: need both count and hash.
    const c = count orelse {
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    };
    const h = hash orelse {
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    };

    // Format: "{base_version}-dev.{count}+{hash}"
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

// ── buildCompileCommand (replicated for Property 7) ─────────────────────────

fn buildCompileCommand(cmd: *Command_Buffer, opts: Compile_Options) SigError!void {
    if (opts.compiler_path.len > 0) {
        try cmd.addArg(opts.compiler_path);
    } else {
        try cmd.addArg("sig");
    }

    try cmd.addArg("build-exe");

    // --dep for each import (before -Mroot=)
    for (opts.imports) |imp| {
        const name_slice = imp.name[0..imp.name_len];
        try cmd.addArg("--dep");
        try cmd.addArg(name_slice);
    }

    // -Mroot=<source_path>
    {
        var root_buf: [PATH_BUF_SIZE]u8 = undefined;
        const root_prefix = "-Mroot=";
        const src_path = opts.source_path;
        if (root_prefix.len + src_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(root_buf[0..root_prefix.len], root_prefix);
        @memcpy(root_buf[root_prefix.len..][0..src_path.len], src_path);
        try cmd.addArg(root_buf[0 .. root_prefix.len + src_path.len]);
    }

    // -Mname=path for each import
    for (opts.imports) |imp| {
        var mod_buf: [PATH_BUF_SIZE]u8 = undefined;
        const name_slice = imp.name[0..imp.name_len];
        const path_slice = imp.path[0..imp.path_len];
        const prefix_len = 2 + name_slice.len + 1; // "-M" + name + "="
        const total = prefix_len + path_slice.len;
        if (total > PATH_BUF_SIZE) return error.BufferTooSmall;
        mod_buf[0] = '-';
        mod_buf[1] = 'M';
        @memcpy(mod_buf[2..][0..name_slice.len], name_slice);
        mod_buf[2 + name_slice.len] = '=';
        @memcpy(mod_buf[prefix_len..][0..path_slice.len], path_slice);
        try cmd.addArg(mod_buf[0..total]);
    }

    try cmd.addArg("-O");
    try cmd.addArg(switch (opts.optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    });

    if (opts.target) |triple_str| {
        try cmd.addArg("-target");
        try cmd.addArg(triple_str);
    }

    try cmd.addArg("--cache-dir");
    try cmd.addArg(opts.cache_dir);

    try cmd.addArg("--name");
    try cmd.addArg(opts.output_name);
}

// ── Random generators ───────────────────────────────────────────────────

fn randomOptimizeMode(random: std.Random) Optimize_Mode {
    return switch (random.uintLessThan(u8, 4)) {
        0 => .Debug,
        1 => .ReleaseSafe,
        2 => .ReleaseFast,
        3 => .ReleaseSmall,
        else => unreachable,
    };
}

fn randomBool(random: std.Random) bool {
    return random.boolean();
}

/// Build a random Build_Context with random -D flags and optimize mode.
fn randomBuildContext(random: std.Random, ctx: *Build_Context) void {
    ctx.* = .{};
    ctx.optimize = randomOptimizeMode(random);

    // Random sig_version
    const sig_ver = "0.0.4-dev";
    @memcpy(ctx.sig_version[0..sig_ver.len], sig_ver);
    ctx.sig_version_len = sig_ver.len;

    // Randomly set boolean -D flags
    const bool_flags = [_][]const u8{
        "skip-non-native",    "enable-llvm",       "static-llvm",
        "llvm-has-m68k",      "llvm-has-csky",     "llvm-has-arc",
        "llvm-has-xtensa",    "debug-allocator",   "debug-extensions",
        "log",                "link-snapshot",     "tracy",
        "tracy-callstack",    "tracy-allocation",  "value-tracing",
        "strip",
    };

    for (bool_flags) |flag| {
        if (randomBool(random)) {
            ctx.options.put(flag, if (randomBool(random)) "true" else "false") catch {};
        }
    }

    // Randomly set enum options
    if (randomBool(random)) {
        const dev_vals = [_][]const u8{ "full", "bootstrap", "core", "sema" };
        ctx.options.put("dev", dev_vals[random.uintLessThan(usize, dev_vals.len)]) catch {};
    }
    if (randomBool(random)) {
        const io_vals = [_][]const u8{ "threaded", "evented" };
        ctx.options.put("io-mode", io_vals[random.uintLessThan(usize, io_vals.len)]) catch {};
    }
    if (randomBool(random)) {
        const vim_vals = [_][]const u8{ "direct", "by_name" };
        ctx.options.put("value-interpret-mode", vim_vals[random.uintLessThan(usize, vim_vals.len)]) catch {};
    }
}

/// Generate a random version string in "M.N.P" or "M.N.P-dev.COUNT+HASH" format.
fn randomVersionString(random: std.Random, buf: *[VERSION_BUF_SIZE]u8) []const u8 {
    const major = random.uintLessThan(u16, 100);
    const minor = random.uintLessThan(u16, 100);
    const patch = random.uintLessThan(u16, 100);

    if (randomBool(random)) {
        // Release: "M.N.P"
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ major, minor, patch }) catch buf[0..3];
    } else {
        // Dev: "M.N.P-dev.COUNT+HASH"
        const count = random.uintLessThan(u32, 10000);
        var hash_buf: [9]u8 = undefined;
        const hex = "0123456789abcdef";
        for (&hash_buf) |*c| {
            c.* = hex[random.uintLessThan(usize, 16)];
        }
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}-dev.{d}+{s}", .{
            major, minor, patch, count, @as([]const u8, &hash_buf),
        }) catch buf[0..5];
    }
}

// ── Property tests (placeholders — implementations in tasks 3.2–3.8) ────

// Feature: sig-compiler-entry, Property 1: Generated file contains all required constants with correct types
// **Validates: Requirements 1.2, 1.3, 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7**
test "property: generated file contains all required constants with correct types" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ctx: Build_Context = .{};
            randomBuildContext(random, &ctx);
            var version_buf: [VERSION_BUF_SIZE]u8 = undefined;
            const version = randomVersionString(random, &version_buf);
            var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
            const output = try generateBuildOptionsToBuffer(&ctx, version, &buf);

            // All 22 required constants with their expected type annotations
            const expected = [_][]const u8{
                "pub const mem_leak_frames: u32",
                "pub const skip_non_native: bool",
                "pub const have_llvm: bool",
                "pub const llvm_has_m68k: bool",
                "pub const llvm_has_csky: bool",
                "pub const llvm_has_arc: bool",
                "pub const llvm_has_xtensa: bool",
                "pub const debug_gpa: bool",
                "pub const version: [:0]const u8",
                "pub const sig_version: [:0]const u8",
                "pub const semver: @import(\"std\").SemanticVersion",
                "pub const enable_debug_extensions: bool",
                "pub const enable_logging: bool",
                "pub const enable_link_snapshots: bool",
                "pub const enable_tracy: bool",
                "pub const enable_tracy_callstack: bool",
                "pub const enable_tracy_allocation: bool",
                "pub const tracy_callstack_depth: u32",
                "pub const value_tracing: bool",
                "pub const dev: @\"src.dev.Env\"",
                "pub const io_mode: @\"build.IoMode\"",
                "pub const value_interpret_mode: @\"build.ValueInterpretMode\"",
            };

            for (expected) |needle| {
                if (std.mem.indexOf(u8, output, needle) == null) {
                    std.debug.print("Missing constant: {s}\nOutput:\n{s}\n", .{ needle, output });
                    return error.CapacityExceeded;
                }
            }
        }
    };
    harness.property("all required constants present", S.run);
}

// Feature: sig-compiler-entry, Property 2: Flag values are correctly forwarded with defaults
// **Validates: Requirements 2.4, 2.6, 2.7, 2.8, 2.9, 6.2**
test "property: flag values are correctly forwarded with defaults" {
    const S = struct {
        /// Search output for `pub const <name>: bool = true;` or `false;` and return the value.
        fn parseBoolConst(output: []const u8, name: []const u8) ?bool {
            // Build "pub const <name>: bool = true;"
            var true_needle: [128]u8 = undefined;
            const true_prefix = "pub const ";
            const true_mid = ": bool = true;";
            const true_len = true_prefix.len + name.len + true_mid.len;
            @memcpy(true_needle[0..true_prefix.len], true_prefix);
            @memcpy(true_needle[true_prefix.len..][0..name.len], name);
            @memcpy(true_needle[true_prefix.len + name.len ..][0..true_mid.len], true_mid);

            if (std.mem.indexOf(u8, output, true_needle[0..true_len]) != null) return true;

            // Build "pub const <name>: bool = false;"
            var false_needle: [128]u8 = undefined;
            const false_mid = ": bool = false;";
            const false_len = true_prefix.len + name.len + false_mid.len;
            @memcpy(false_needle[0..true_prefix.len], true_prefix);
            @memcpy(false_needle[true_prefix.len..][0..name.len], name);
            @memcpy(false_needle[true_prefix.len + name.len ..][0..false_mid.len], false_mid);

            if (std.mem.indexOf(u8, output, false_needle[0..false_len]) != null) return false;

            return null;
        }

        fn run(random: std.Random) anyerror!void {
            var ctx: Build_Context = .{};
            randomBuildContext(random, &ctx);
            var version_buf: [VERSION_BUF_SIZE]u8 = undefined;
            const version = randomVersionString(random, &version_buf);
            var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
            const output = try generateBuildOptionsToBuffer(&ctx, version, &buf);

            // Determine expected have_llvm: true iff enable-llvm or static-llvm is present
            const have_llvm_expected = ctx.options.getValue("enable-llvm") != null or
                ctx.options.getValue("static-llvm") != null;

            // Verify have_llvm
            const have_llvm_actual = parseBoolConst(output, "have_llvm") orelse return error.CapacityExceeded;
            if (have_llvm_actual != have_llvm_expected) {
                std.debug.print("have_llvm mismatch: expected={}, actual={}\n", .{ have_llvm_expected, have_llvm_actual });
                return error.CapacityExceeded;
            }

            // Simple boolean flags: (option_key, output_const_name, default)
            const Flag = struct { key: []const u8, name: []const u8, default: bool };
            const simple_flags = [_]Flag{
                .{ .key = "skip-non-native", .name = "skip_non_native", .default = false },
                .{ .key = "debug-allocator", .name = "debug_gpa", .default = false },
                .{ .key = "debug-extensions", .name = "enable_debug_extensions", .default = false },
                .{ .key = "log", .name = "enable_logging", .default = false },
                .{ .key = "link-snapshot", .name = "enable_link_snapshots", .default = false },
                .{ .key = "tracy", .name = "enable_tracy", .default = false },
                .{ .key = "tracy-callstack", .name = "enable_tracy_callstack", .default = false },
                .{ .key = "tracy-allocation", .name = "enable_tracy_allocation", .default = false },
                .{ .key = "value-tracing", .name = "value_tracing", .default = false },
            };

            for (simple_flags) |flag| {
                const expected = optBool(&ctx.options, flag.key, flag.default);
                const actual = parseBoolConst(output, flag.name) orelse {
                    std.debug.print("Missing bool const: {s}\n", .{flag.name});
                    return error.CapacityExceeded;
                };
                if (actual != expected) {
                    std.debug.print("Flag mismatch: {s} expected={}, actual={}\n", .{ flag.name, expected, actual });
                    return error.CapacityExceeded;
                }
            }

            // LLVM sub-flags: when have_llvm is false, all must be false regardless of -D flags
            const llvm_flags = [_]Flag{
                .{ .key = "llvm-has-m68k", .name = "llvm_has_m68k", .default = false },
                .{ .key = "llvm-has-csky", .name = "llvm_has_csky", .default = false },
                .{ .key = "llvm-has-arc", .name = "llvm_has_arc", .default = false },
                .{ .key = "llvm-has-xtensa", .name = "llvm_has_xtensa", .default = false },
            };

            for (llvm_flags) |flag| {
                const expected = if (have_llvm_expected) optBool(&ctx.options, flag.key, flag.default) else false;
                const actual = parseBoolConst(output, flag.name) orelse {
                    std.debug.print("Missing llvm bool const: {s}\n", .{flag.name});
                    return error.CapacityExceeded;
                };
                if (actual != expected) {
                    std.debug.print("LLVM flag mismatch: {s} expected={}, actual={} (have_llvm={})\n", .{ flag.name, expected, actual, have_llvm_expected });
                    return error.CapacityExceeded;
                }
            }
        }
    };
    harness.property("flag values correctly forwarded with defaults", S.run);
}

// Feature: sig-compiler-entry, Property 3: Semver struct is consistent with version string
// **Validates: Requirements 2.3, 7.3**
test "property: semver struct is consistent with version string" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // 1. Generate a random version string
            var version_buf: [VERSION_BUF_SIZE]u8 = undefined;
            const version = randomVersionString(random, &version_buf);

            // 2. Create a default Build_Context
            var ctx: Build_Context = .{};
            const sig_ver = "0.0.4-dev";
            @memcpy(ctx.sig_version[0..sig_ver.len], sig_ver);
            ctx.sig_version_len = sig_ver.len;

            // 3. Call generateBuildOptionsToBuffer
            var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
            const output = try generateBuildOptionsToBuffer(&ctx, version, &buf);

            // 4. Parse the version string to extract expected M, N, P, pre, build
            var exp_major: []const u8 = "0";
            var exp_minor: []const u8 = "0";
            var exp_patch: []const u8 = "0";
            var exp_pre: []const u8 = "";
            var exp_build: []const u8 = "";
            parseSemver(version, &exp_major, &exp_minor, &exp_patch, &exp_pre, &exp_build);

            // 5. Verify .major = M, .minor = N, .patch = P in the semver struct
            // Build needle: ".major = <M>,"
            var major_needle: [64]u8 = undefined;
            const major_n = std.fmt.bufPrint(&major_needle, ".major = {s},", .{exp_major}) catch return error.BufferTooSmall;
            if (std.mem.indexOf(u8, output, major_n) == null) {
                std.debug.print("Missing .major = {s} in output\nVersion: {s}\nOutput:\n{s}\n", .{ exp_major, version, output });
                return error.CapacityExceeded;
            }

            var minor_needle: [64]u8 = undefined;
            const minor_n = std.fmt.bufPrint(&minor_needle, ".minor = {s},", .{exp_minor}) catch return error.BufferTooSmall;
            if (std.mem.indexOf(u8, output, minor_n) == null) {
                std.debug.print("Missing .minor = {s} in output\nVersion: {s}\nOutput:\n{s}\n", .{ exp_minor, version, output });
                return error.CapacityExceeded;
            }

            var patch_needle: [64]u8 = undefined;
            const patch_n = std.fmt.bufPrint(&patch_needle, ".patch = {s},", .{exp_patch}) catch return error.BufferTooSmall;
            if (std.mem.indexOf(u8, output, patch_n) == null) {
                std.debug.print("Missing .patch = {s} in output\nVersion: {s}\nOutput:\n{s}\n", .{ exp_patch, version, output });
                return error.CapacityExceeded;
            }

            // 6. If the version has a pre-release part, verify .pre = "..." matches
            if (exp_pre.len > 0) {
                var pre_needle: [128]u8 = undefined;
                const pre_n = std.fmt.bufPrint(&pre_needle, ".pre = \"{s}\",", .{exp_pre}) catch return error.BufferTooSmall;
                if (std.mem.indexOf(u8, output, pre_n) == null) {
                    std.debug.print("Missing .pre = \"{s}\" in output\nVersion: {s}\nOutput:\n{s}\n", .{ exp_pre, version, output });
                    return error.CapacityExceeded;
                }
            }

            // 7. If the version has a build metadata part, verify .build = "..." matches
            if (exp_build.len > 0) {
                var build_needle: [128]u8 = undefined;
                const build_n = std.fmt.bufPrint(&build_needle, ".build = \"{s}\",", .{exp_build}) catch return error.BufferTooSmall;
                if (std.mem.indexOf(u8, output, build_n) == null) {
                    std.debug.print("Missing .build = \"{s}\" in output\nVersion: {s}\nOutput:\n{s}\n", .{ exp_build, version, output });
                    return error.CapacityExceeded;
                }
            }
        }
    };
    harness.property("semver struct consistent with version string", S.run);
}

// Feature: sig-compiler-entry, Property 4: Version string formatting
// **Validates: Requirements 5.2, 5.3**
test "property: version string formatting" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random version components
            const major = random.uintLessThan(u16, 100);
            const minor = random.uintLessThan(u16, 100);
            const patch = random.uintLessThan(u16, 100);
            const count = random.uintLessThan(u32, 100000);

            // Generate random 9-char hex hash
            var hash_buf: [9]u8 = undefined;
            const hex_chars = "0123456789abcdef";
            for (&hash_buf) |*c| {
                c.* = hex_chars[random.uintLessThan(usize, 16)];
            }
            const hash: []const u8 = &hash_buf;

            // Format base version "M.N.P"
            var base_buf: [64]u8 = undefined;
            const base_version = std.fmt.bufPrint(&base_buf, "{d}.{d}.{d}", .{ major, minor, patch }) catch return error.BufferTooSmall;

            // Format expected count string
            var count_buf: [16]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch return error.BufferTooSmall;

            // ── Test dev builds: should produce "M.N.P-dev.COUNT+HASH" ──
            {
                var ver_buf: [VERSION_BUF_SIZE]u8 = undefined;
                const result = resolveVersionStringFromParts(&ver_buf, base_version, true, count_str, hash);

                // Build expected string
                var expected_buf: [VERSION_BUF_SIZE]u8 = undefined;
                const expected = std.fmt.bufPrint(&expected_buf, "{s}-dev.{s}+{s}", .{ base_version, count_str, hash }) catch return error.BufferTooSmall;

                if (!std.mem.eql(u8, result, expected)) {
                    std.debug.print("Dev version mismatch:\n  expected: {s}\n  actual:   {s}\n", .{ expected, result });
                    return error.CapacityExceeded;
                }
            }

            // ── Test release builds (is_dev=false): should produce "M.N.P" ──
            {
                var ver_buf: [VERSION_BUF_SIZE]u8 = undefined;
                const result = resolveVersionStringFromParts(&ver_buf, base_version, false, count_str, hash);

                if (!std.mem.eql(u8, result, base_version)) {
                    std.debug.print("Release version mismatch:\n  expected: {s}\n  actual:   {s}\n", .{ base_version, result });
                    return error.CapacityExceeded;
                }
            }

            // ── Test null count/hash falls back to base version ──
            {
                var ver_buf: [VERSION_BUF_SIZE]u8 = undefined;
                const result = resolveVersionStringFromParts(&ver_buf, base_version, true, null, null);

                if (!std.mem.eql(u8, result, base_version)) {
                    std.debug.print("Null fallback mismatch:\n  expected: {s}\n  actual:   {s}\n", .{ base_version, result });
                    return error.CapacityExceeded;
                }
            }

            // ── Test null hash (count present) falls back to base version ──
            {
                var ver_buf: [VERSION_BUF_SIZE]u8 = undefined;
                const result = resolveVersionStringFromParts(&ver_buf, base_version, true, count_str, null);

                if (!std.mem.eql(u8, result, base_version)) {
                    std.debug.print("Null hash fallback mismatch:\n  expected: {s}\n  actual:   {s}\n", .{ base_version, result });
                    return error.CapacityExceeded;
                }
            }
        }
    };
    harness.property("version string formatting", S.run);
}

// Feature: sig-compiler-entry, Property 5: Deterministic output
// **Validates: Requirements 7.9**
test "property: deterministic output" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate a random build config
            var ctx: Build_Context = .{};
            randomBuildContext(random, &ctx);
            var version_buf: [VERSION_BUF_SIZE]u8 = undefined;
            const version = randomVersionString(random, &version_buf);

            // Call generateBuildOptionsToBuffer twice with identical inputs
            var buf1: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
            const output1 = try generateBuildOptionsToBuffer(&ctx, version, &buf1);

            var buf2: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
            const output2 = try generateBuildOptionsToBuffer(&ctx, version, &buf2);

            // Verify byte-for-byte identical output
            if (!std.mem.eql(u8, output1, output2)) {
                std.debug.print("Deterministic output failed!\n  len1={d}, len2={d}\n", .{ output1.len, output2.len });
                // Find first difference
                const min_len = @min(output1.len, output2.len);
                for (0..min_len) |i| {
                    if (output1[i] != output2[i]) {
                        std.debug.print("  First diff at byte {d}: '{c}' vs '{c}'\n", .{ i, output1[i], output2[i] });
                        break;
                    }
                }
                return error.CapacityExceeded;
            }
        }
    };
    harness.property("deterministic output", S.run);
}

// Feature: sig-compiler-entry, Property 6: mem_leak_frames conditional default
// **Validates: Requirements 2.10**
test "property: mem_leak_frames conditional default" {
    const S = struct {
        fn parseMemLeakFrames(output: []const u8) ?u32 {
            const prefix = "pub const mem_leak_frames: u32 = ";
            const start_idx = std.mem.indexOf(u8, output, prefix) orelse return null;
            const value_start = start_idx + prefix.len;
            // Find the semicolon that ends the value
            const semi_idx = std.mem.indexOfScalarPos(u8, output, value_start, ';') orelse return null;
            const value_str = output[value_start..semi_idx];
            return std.fmt.parseInt(u32, value_str, 10) catch null;
        }

        fn run(random: std.Random) anyerror!void {
            // Generate random optimize mode, strip flag, and debug-gpa flag
            var ctx: Build_Context = .{};
            ctx.optimize = randomOptimizeMode(random);

            const sig_ver = "0.0.4-dev";
            @memcpy(ctx.sig_version[0..sig_ver.len], sig_ver);
            ctx.sig_version_len = sig_ver.len;

            const is_strip = randomBool(random);
            const is_debug_gpa = randomBool(random);

            if (is_strip) {
                ctx.options.put("strip", "true") catch {};
            }
            if (is_debug_gpa) {
                ctx.options.put("debug-allocator", "true") catch {};
            }

            var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
            const output = try generateBuildOptionsToBuffer(&ctx, "0.16.0", &buf);

            const mem_leak = parseMemLeakFrames(output) orelse {
                std.debug.print("Failed to parse mem_leak_frames from output\n", .{});
                return error.CapacityExceeded;
            };

            const is_debug = ctx.optimize == .Debug;

            // Verify: 0 when strip is set, regardless of other settings
            if (is_strip) {
                if (mem_leak != 0) {
                    std.debug.print("mem_leak_frames should be 0 when strip is set, got {d}\n", .{mem_leak});
                    return error.CapacityExceeded;
                }
                return;
            }

            // Verify: 0 when not Debug mode
            if (!is_debug) {
                if (mem_leak != 0) {
                    std.debug.print("mem_leak_frames should be 0 for non-Debug mode ({s}), got {d}\n", .{ @tagName(ctx.optimize), mem_leak });
                    return error.CapacityExceeded;
                }
                return;
            }

            // Debug mode, not stripped
            if (is_debug_gpa) {
                // Verify: non-zero (4) when Debug and debug-gpa and not strip
                if (mem_leak != 4) {
                    std.debug.print("mem_leak_frames should be 4 for Debug+debug-gpa, got {d}\n", .{mem_leak});
                    return error.CapacityExceeded;
                }
            } else {
                // Debug mode without debug-gpa: should be 0
                if (mem_leak != 0) {
                    std.debug.print("mem_leak_frames should be 0 for Debug without debug-gpa, got {d}\n", .{mem_leak});
                    return error.CapacityExceeded;
                }
            }
        }
    };
    harness.property("mem_leak_frames conditional default", S.run);
}

// Feature: sig-compiler-entry, Property 7: Compiler command includes correct module dependencies
// **Validates: Requirements 3.2, 3.3, 3.4**
test "property: compiler command includes correct module dependencies" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random optimize mode
            const optimize = randomOptimizeMode(random);

            // Optionally generate a target triple
            const target_triples = [_][]const u8{
                "x86_64-linux-gnu",
                "aarch64-linux-gnu",
                "x86_64-windows-msvc",
                "wasm32-wasi",
                "riscv64-linux-gnu",
            };
            const has_target = randomBool(random);
            const target: ?[]const u8 = if (has_target)
                target_triples[random.uintLessThan(usize, target_triples.len)]
            else
                null;

            // Create build_options import entry
            var bo_import: Import_Entry = .{};
            const bo_name = "build_options";
            @memcpy(bo_import.name[0..bo_name.len], bo_name);
            bo_import.name_len = bo_name.len;
            const bo_path = ".zig-cache/build_options.zig";
            @memcpy(bo_import.path[0..bo_path.len], bo_path);
            bo_import.path_len = bo_path.len;

            // Create aro import entry
            var aro_import: Import_Entry = .{};
            const aro_name = "aro";
            @memcpy(aro_import.name[0..aro_name.len], aro_name);
            aro_import.name_len = aro_name.len;
            const aro_path = "lib/compiler/aro/aro.zig";
            @memcpy(aro_import.path[0..aro_path.len], aro_path);
            aro_import.path_len = aro_path.len;

            const imports = [_]Import_Entry{ bo_import, aro_import };

            // Build the command
            var cmd: Command_Buffer = .{};
            try buildCompileCommand(&cmd, .{
                .source_path = "src/main.zig",
                .output_name = "sig",
                .cache_dir = ".zig-cache",
                .optimize = optimize,
                .target = target,
                .imports = &imports,
                .compiler_path = "sig",
            });

            // ── Verify --dep build_options and --dep aro appear before -Mroot= ──
            var dep_bo_idx: ?usize = null;
            var dep_aro_idx: ?usize = null;
            var mroot_idx: ?usize = null;

            for (0..cmd.arg_count) |i| {
                const arg = cmd.getArg(i);
                if (std.mem.eql(u8, arg, "build_options")) {
                    // Check previous arg is --dep
                    if (i > 0 and std.mem.eql(u8, cmd.getArg(i - 1), "--dep")) {
                        dep_bo_idx = i;
                    }
                }
                if (std.mem.eql(u8, arg, "aro")) {
                    if (i > 0 and std.mem.eql(u8, cmd.getArg(i - 1), "--dep")) {
                        dep_aro_idx = i;
                    }
                }
                if (arg.len >= 7 and std.mem.eql(u8, arg[0..7], "-Mroot=")) {
                    mroot_idx = i;
                }
            }

            if (dep_bo_idx == null) {
                std.debug.print("Missing '--dep build_options' in command\n", .{});
                return error.CapacityExceeded;
            }
            if (dep_aro_idx == null) {
                std.debug.print("Missing '--dep aro' in command\n", .{});
                return error.CapacityExceeded;
            }
            if (mroot_idx == null) {
                std.debug.print("Missing '-Mroot=...' in command\n", .{});
                return error.CapacityExceeded;
            }

            // --dep args must come before -Mroot=
            if (dep_bo_idx.? >= mroot_idx.?) {
                std.debug.print("'--dep build_options' (idx {d}) must come before '-Mroot=' (idx {d})\n", .{ dep_bo_idx.?, mroot_idx.? });
                return error.CapacityExceeded;
            }
            if (dep_aro_idx.? >= mroot_idx.?) {
                std.debug.print("'--dep aro' (idx {d}) must come before '-Mroot=' (idx {d})\n", .{ dep_aro_idx.?, mroot_idx.? });
                return error.CapacityExceeded;
            }

            // ── Verify -Mbuild_options=... and -Maro=... are present ──
            var found_mbo = false;
            var found_maro = false;
            for (0..cmd.arg_count) |i| {
                const arg = cmd.getArg(i);
                if (arg.len >= 16 and std.mem.eql(u8, arg[0..16], "-Mbuild_options=")) {
                    found_mbo = true;
                }
                if (arg.len >= 5 and std.mem.eql(u8, arg[0..5], "-Maro=")) {
                    found_maro = true;
                }
            }

            if (!found_mbo) {
                std.debug.print("Missing '-Mbuild_options=...' in command\n", .{});
                return error.CapacityExceeded;
            }
            if (!found_maro) {
                std.debug.print("Missing '-Maro=...' in command\n", .{});
                return error.CapacityExceeded;
            }

            // ── Verify optimization flag matches the mode ──
            const expected_opt = switch (optimize) {
                .Debug => "Debug",
                .ReleaseSafe => "ReleaseSafe",
                .ReleaseFast => "ReleaseFast",
                .ReleaseSmall => "ReleaseSmall",
            };

            var found_opt = false;
            for (0..cmd.arg_count) |i| {
                const arg = cmd.getArg(i);
                if (std.mem.eql(u8, arg, expected_opt)) {
                    // Check previous arg is -O
                    if (i > 0 and std.mem.eql(u8, cmd.getArg(i - 1), "-O")) {
                        found_opt = true;
                    }
                }
            }

            if (!found_opt) {
                std.debug.print("Missing '-O {s}' in command\n", .{expected_opt});
                return error.CapacityExceeded;
            }

            // ── Verify target triple if present ──
            if (target) |expected_target| {
                var found_target = false;
                for (0..cmd.arg_count) |i| {
                    const arg = cmd.getArg(i);
                    if (std.mem.eql(u8, arg, expected_target)) {
                        if (i > 0 and std.mem.eql(u8, cmd.getArg(i - 1), "-target")) {
                            found_target = true;
                        }
                    }
                }
                if (!found_target) {
                    std.debug.print("Missing '-target {s}' in command\n", .{expected_target});
                    return error.CapacityExceeded;
                }
            }
        }
    };
    harness.property("compiler command includes correct module dependencies", S.run);
}
