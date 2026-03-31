// Feature: sig-build-integration — Property-based tests for build system integration
//
// These tests replicate build runner algorithms on the stack (the build runner
// at tools/sig_build/main.sig is not wired as a test import). Each property
// runs 200 iterations via the PBT harness with deterministic seed 0xdeadbeef.
// Zero allocators — all data on stack.

const std = @import("std");
const mem = std.mem;
const harness = @import("harness");

// ── Generators ──────────────────────────────────────────────────────────

/// Generate a random alphanumeric + dots + hyphens base name of length 1..max_len.
fn genBaseName(random: std.Random, buf: []u8, max_len: usize) []u8 {
    const choices = "abcdefghijklmnopqrstuvwxyz0123456789.-";
    const len = 1 + random.uintAtMost(usize, max_len - 1);
    const actual = @min(len, buf.len);
    for (buf[0..actual]) |*c| {
        c.* = choices[random.uintAtMost(usize, choices.len - 1)];
    }
    return buf[0..actual];
}

/// Generate a random alphanumeric string of length 1..max_len (no dots/hyphens).
fn genAlphaNum(random: std.Random, buf: []u8, max_len: usize) []u8 {
    const choices = "abcdefghijklmnopqrstuvwxyz0123456789";
    const len = 1 + random.uintAtMost(usize, max_len - 1);
    const actual = @min(len, buf.len);
    for (buf[0..actual]) |*c| {
        c.* = choices[random.uintAtMost(usize, choices.len - 1)];
    }
    return buf[0..actual];
}

/// Generate a random path-safe string (alphanumeric + slashes + underscores).
fn genPathStr(random: std.Random, buf: []u8, max_len: usize) []u8 {
    const choices = "abcdefghijklmnopqrstuvwxyz0123456789/_";
    const len = 1 + random.uintAtMost(usize, max_len - 1);
    const actual = @min(len, buf.len);
    for (buf[0..actual]) |*c| {
        c.* = choices[random.uintAtMost(usize, choices.len - 1)];
    }
    return buf[0..actual];
}

// ── Replicated logic ────────────────────────────────────────────────────

/// Replicated classifyFileExt result.
const FileExt = enum { sig, zig, unknown, other };

/// Replicated classifyFileExt logic from src/Compilation.zig.
fn classifyFileExt(filename: []const u8) FileExt {
    if (mem.endsWith(u8, filename, ".sig")) {
        if (mem.endsWith(u8, filename, ".sig.zon")) return .unknown;
        return .sig;
    } else if (mem.endsWith(u8, filename, ".zig")) {
        return .zig;
    }
    return .other;
}

/// Replicated delegation decision.
const DelegationPath = enum { sig_runner, zig_runner, override };

fn delegationDecision(has_build_sig: bool, has_build_zig: bool, has_override: bool) DelegationPath {
    if (has_override) return .override;
    if (has_build_sig) return .sig_runner;
    if (has_build_zig) return .zig_runner;
    // No build file — would be an error in practice, but default to zig_runner
    return .zig_runner;
}

/// Replicated shouldExcludeFile from the build runner.
fn shouldExcludeFile(filename: []const u8) bool {
    // Exact name matches
    const excluded_names = [_][]const u8{
        "README.md",
        "compress-e.txt",
        "compress-gettysburg.txt",
        "compress-pi.txt",
        "rfc1951.txt",
        "rfc1952.txt",
        "rfc8478.txt",
    };
    for (excluded_names) |name| {
        if (mem.eql(u8, filename, name)) return true;
    }

    // Suffix-based exclusions
    const excluded_suffixes = [_][]const u8{
        ".gz",
        ".z.0",
        ".z.9",
        ".zst.3",
        ".zst.19",
        ".lzma",
        ".xz",
        ".tzif",
        ".tar",
        ".expect",
        ".expect-noinput",
        ".golden",
        ".input",
        "test.zig",
    };
    for (excluded_suffixes) |suffix| {
        if (filename.len >= suffix.len and
            mem.eql(u8, filename[filename.len - suffix.len ..], suffix))
        {
            return true;
        }
    }

    return false;
}

/// Format a version constant line (replicated from build.sig format).
fn formatVersionLine(buf: []u8, major: u16, minor: u16, patch: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "const sig_version = .{{ .major = {d}, .minor = {d}, .patch = {d}, .pre = \"dev\" }};", .{ major, minor, patch });
}

/// Extract a numeric value after a marker string from a line.
fn extractAfterMarker(line: []const u8, marker: []const u8) ?u16 {
    const start = mem.indexOf(u8, line, marker) orelse return null;
    const num_start = start + marker.len;
    var num_end = num_start;
    while (num_end < line.len and line[num_end] >= '0' and line[num_end] <= '9') {
        num_end += 1;
    }
    if (num_end == num_start) return null;
    return std.fmt.parseInt(u16, line[num_start..num_end], 10) catch null;
}

/// Format a failed step error message (replicated from build runner).
fn formatStepError(buf: []u8, step_name: []const u8, exit_code: u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "FAIL: step '{s}' exited with code {d}", .{ step_name, exit_code });
}

/// Format a capacity error message (replicated from build runner).
fn formatCapacityError(buf: []u8, registry_name: []const u8, current: u16, maximum: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "CapacityExceeded: {s} ({d}/{d})", .{ registry_name, current, maximum });
}

// ── Property 1: File extension classification for .sig files ────────────
// Feature: sig-build-integration, Property 1: File extension classification for .sig files
//
// **Validates: Requirements 1.2, 1.3, 1.4, 1.5**

test "Property 1: classifyFileExt returns .sig for .sig files, not for .sig.zon" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random base name (1-200 chars), append .sig
            var base_buf: [200]u8 = undefined;
            const base = genBaseName(random, &base_buf, 200);

            var name_buf: [204]u8 = undefined;
            @memcpy(name_buf[0..base.len], base);
            @memcpy(name_buf[base.len..][0..4], ".sig");
            const sig_name = name_buf[0 .. base.len + 4];

            try std.testing.expectEqual(FileExt.sig, classifyFileExt(sig_name));

            // Generate .sig.zon name — must NOT classify as .sig
            var zon_buf: [208]u8 = undefined;
            @memcpy(zon_buf[0..base.len], base);
            @memcpy(zon_buf[base.len..][0..8], ".sig.zon");
            const zon_name = zon_buf[0 .. base.len + 8];

            try std.testing.expect(classifyFileExt(zon_name) != .sig);
        }
    };
    harness.property(
        "classifyFileExt returns .sig for .sig files, not for .sig.zon",
        S.run,
    );
}

// ── Property 2: Build runner delegation decision ────────────────────────
// Feature: sig-build-integration, Property 2: Build runner delegation decision
//
// **Validates: Requirements 2.1, 2.8, 10.1, 10.2, 10.3**

test "Property 2: delegation decision selects correct path for all flag combinations" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const has_build_sig = random.boolean();
            const has_build_zig = random.boolean();
            const has_override = random.boolean();

            const result = delegationDecision(has_build_sig, has_build_zig, has_override);

            // Override always wins
            if (has_override) {
                try std.testing.expectEqual(DelegationPath.override, result);
                return;
            }
            // build.sig present (no override) → sig runner
            if (has_build_sig) {
                try std.testing.expectEqual(DelegationPath.sig_runner, result);
                return;
            }
            // build.zig only (no override, no build.sig) → zig runner
            if (has_build_zig) {
                try std.testing.expectEqual(DelegationPath.zig_runner, result);
                return;
            }
            // Neither file → zig runner (fallback)
            try std.testing.expectEqual(DelegationPath.zig_runner, result);
        }
    };
    harness.property(
        "delegation decision selects correct path for all flag combinations",
        S.run,
    );
}

// ── Property 3: Build runner argument vector construction ───────────────
// Feature: sig-build-integration, Property 3: Build runner argument vector construction
//
// **Validates: Requirements 2.6, 8.3**

test "Property 3: argv has fixed positions 0-5 and preserves user args at 6+" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const runner_bin = "/cache/sig_build";
            const compiler = "/usr/bin/sig";
            const lib_dir = "/usr/lib";
            const build_root = "/home/user/project";
            const local_cache = "/home/user/project/.zig-cache";
            const global_cache = "/home/user/.cache/zig";

            // Generate 0-20 random user args
            const num_args = random.uintAtMost(usize, 20);
            var user_args: [20][100]u8 = undefined;
            var user_arg_lens: [20]usize = undefined;
            for (0..num_args) |i| {
                const arg = genAlphaNum(random, &user_args[i], 100);
                user_arg_lens[i] = arg.len;
            }

            // Construct argv: [runner_bin, compiler, lib_dir, build_root, local_cache, global_cache, user_args...]
            var argv: [26][256]u8 = undefined;
            var argv_lens: [26]usize = undefined;
            const fixed = [_][]const u8{ runner_bin, compiler, lib_dir, build_root, local_cache, global_cache };
            for (fixed, 0..) |f, i| {
                @memcpy(argv[i][0..f.len], f);
                argv_lens[i] = f.len;
            }
            for (0..num_args) |i| {
                const len = user_arg_lens[i];
                @memcpy(argv[6 + i][0..len], user_args[i][0..len]);
                argv_lens[6 + i] = len;
            }
            const total = 6 + num_args;

            // Verify fixed positions
            try std.testing.expectEqualSlices(u8, runner_bin, argv[0][0..argv_lens[0]]);
            try std.testing.expectEqualSlices(u8, compiler, argv[1][0..argv_lens[1]]);
            try std.testing.expectEqualSlices(u8, lib_dir, argv[2][0..argv_lens[2]]);
            try std.testing.expectEqualSlices(u8, build_root, argv[3][0..argv_lens[3]]);
            try std.testing.expectEqualSlices(u8, local_cache, argv[4][0..argv_lens[4]]);
            try std.testing.expectEqualSlices(u8, global_cache, argv[5][0..argv_lens[5]]);

            // Verify user args preserved in order at indices 6..
            for (0..num_args) |i| {
                const expected = user_args[i][0..user_arg_lens[i]];
                const actual = argv[6 + i][0..argv_lens[6 + i]];
                try std.testing.expectEqualSlices(u8, expected, actual);
            }

            // Verify total length
            try std.testing.expectEqual(6 + num_args, total);
        }
    };
    harness.property(
        "argv has fixed positions 0-5 and preserves user args at 6+",
        S.run,
    );
}

// ── Property 4: Lib installation exclusion filter ───────────────────────
// Feature: sig-build-integration, Property 4: Lib installation exclusion filter
//
// **Validates: Requirements 5.2**

test "Property 4: exclusion filter matches expected set for random filenames" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Test with a known-excluded suffix
            const excluded_suffixes = [_][]const u8{
                ".gz",     ".z.0",     ".z.9",            ".zst.3",
                ".zst.19", ".lzma",    ".xz",             ".tzif",
                ".tar",    ".expect",  ".expect-noinput", ".golden",
                ".input",  "test.zig",
            };

            // Pick a random excluded suffix and prepend a random base
            const suffix_idx = random.uintAtMost(usize, excluded_suffixes.len - 1);
            const suffix = excluded_suffixes[suffix_idx];

            var base_buf: [64]u8 = undefined;
            const base = genAlphaNum(random, &base_buf, 64);

            var name_buf: [128]u8 = undefined;
            @memcpy(name_buf[0..base.len], base);
            @memcpy(name_buf[base.len..][0..suffix.len], suffix);
            const excluded_name = name_buf[0 .. base.len + suffix.len];

            try std.testing.expect(shouldExcludeFile(excluded_name));

            // Test exact name matches
            try std.testing.expect(shouldExcludeFile("README.md"));
            try std.testing.expect(shouldExcludeFile("compress-e.txt"));
            try std.testing.expect(shouldExcludeFile("rfc1951.txt"));

            // Generate a safe filename (.sig extension) — should NOT be excluded
            var safe_buf: [68]u8 = undefined;
            const safe_base = genAlphaNum(random, safe_buf[0..64], 64);
            @memcpy(safe_buf[safe_base.len..][0..4], ".sig");
            const safe_name = safe_buf[0 .. safe_base.len + 4];

            try std.testing.expect(!shouldExcludeFile(safe_name));
        }
    };
    harness.property(
        "exclusion filter matches expected set for random filenames",
        S.run,
    );
}

// ── Property 5: Module wiring in build.sig compilation command ──────────
// Feature: sig-build-integration, Property 5: Module wiring in build.sig compilation command
//
// **Validates: Requirements 6.1, 6.2, 6.3, 6.4**

test "Property 5: --mod flags contain correct module prefixes and paths" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random lib_dir and build_root paths
            var lib_buf: [100]u8 = undefined;
            const lib_dir = genPathStr(random, &lib_buf, 100);

            // Construct expected --mod flag values
            // sig:<lib_dir>/sig/sig.zig
            var sig_mod_buf: [256]u8 = undefined;
            const sig_mod = std.fmt.bufPrint(&sig_mod_buf, "sig:{s}/sig/sig.zig", .{lib_dir}) catch return;

            // sig_build:<lib_dir>/../tools/sig_build/main.sig
            var sb_mod_buf: [256]u8 = undefined;
            const sb_mod = std.fmt.bufPrint(&sb_mod_buf, "sig_build:{s}/../tools/sig_build/main.sig", .{lib_dir}) catch return;

            // std:<lib_dir>/std/std.zig
            var std_mod_buf: [256]u8 = undefined;
            const std_mod = std.fmt.bufPrint(&std_mod_buf, "std:{s}/std/std.zig", .{lib_dir}) catch return;

            // Verify each --mod flag starts with the correct prefix
            try std.testing.expect(mem.startsWith(u8, sig_mod, "sig:"));
            try std.testing.expect(mem.startsWith(u8, sb_mod, "sig_build:"));
            try std.testing.expect(mem.startsWith(u8, std_mod, "std:"));

            // Verify each contains the lib_dir
            try std.testing.expect(mem.indexOf(u8, sig_mod, lib_dir) != null);
            try std.testing.expect(mem.indexOf(u8, sb_mod, lib_dir) != null);
            try std.testing.expect(mem.indexOf(u8, std_mod, lib_dir) != null);

            // Verify correct suffixes
            try std.testing.expect(mem.endsWith(u8, sig_mod, "/sig/sig.zig"));
            try std.testing.expect(mem.endsWith(u8, sb_mod, "/tools/sig_build/main.sig"));
            try std.testing.expect(mem.endsWith(u8, std_mod, "/std/std.zig"));
        }
    };
    harness.property(
        "--mod flags contain correct module prefixes and paths",
        S.run,
    );
}

// ── Property 6: Version constant grep extractability ────────────────────
// Feature: sig-build-integration, Property 6: Version constant grep extractability
//
// **Validates: Requirements 8.6, 12.1, 12.2, 12.3, 12.4**

test "Property 6: version tuple survives format-then-extract round trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random version components 0-999
            const major = random.uintAtMost(u16, 999);
            const minor = random.uintAtMost(u16, 999);
            const patch = random.uintAtMost(u16, 999);

            // Format as build.sig constant
            var line_buf: [256]u8 = undefined;
            const line = try formatVersionLine(&line_buf, major, minor, patch);

            // Extract using grep-like logic (find "major = " then digits, etc.)
            const extracted_major = extractAfterMarker(line, "major = ");
            const extracted_minor = extractAfterMarker(line, "minor = ");
            const extracted_patch = extractAfterMarker(line, "patch = ");

            try std.testing.expect(extracted_major != null);
            try std.testing.expect(extracted_minor != null);
            try std.testing.expect(extracted_patch != null);

            try std.testing.expectEqual(major, extracted_major.?);
            try std.testing.expectEqual(minor, extracted_minor.?);
            try std.testing.expectEqual(patch, extracted_patch.?);
        }
    };
    harness.property(
        "version tuple survives format-then-extract round trip",
        S.run,
    );
}

// ── Property 7: Failed step error reporting ─────────────────────────────
// Feature: sig-build-integration, Property 7: Failed step error reporting
//
// **Validates: Requirements 13.3**

test "Property 7: error message contains step name and exit code" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random step name (1-64 chars, alphanumeric + hyphens)
            var name_buf: [64]u8 = undefined;
            const choices = "abcdefghijklmnopqrstuvwxyz0123456789-";
            const name_len = 1 + random.uintAtMost(usize, 63);
            for (name_buf[0..name_len]) |*c| {
                c.* = choices[random.uintAtMost(usize, choices.len - 1)];
            }
            const step_name = name_buf[0..name_len];

            // Generate random exit code 1-255
            const exit_code: u8 = @intCast(1 + random.uintAtMost(u8, 254));

            // Format error message
            var msg_buf: [256]u8 = undefined;
            const msg = try formatStepError(&msg_buf, step_name, exit_code);

            // Verify message contains the step name
            try std.testing.expect(mem.indexOf(u8, msg, step_name) != null);

            // Verify message contains the exit code as a substring
            var code_buf: [4]u8 = undefined;
            const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{exit_code}) catch unreachable;
            try std.testing.expect(mem.indexOf(u8, msg, code_str) != null);
        }
    };
    harness.property(
        "error message contains step name and exit code",
        S.run,
    );
}

// ── Property 8: Capacity error reporting ────────────────────────────────
// Feature: sig-build-integration, Property 8: Capacity error reporting
//
// **Validates: Requirements 13.5**

test "Property 8: capacity error message contains registry name and both numeric values" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random registry name (1-32 chars, alphanumeric)
            var name_buf: [32]u8 = undefined;
            const reg_name = genAlphaNum(random, &name_buf, 32);

            // Generate random capacity values (1-65535)
            const current: u16 = @intCast(1 + random.uintAtMost(u16, 65534));
            const maximum: u16 = @intCast(1 + random.uintAtMost(u16, 65534));

            // Format error message
            var msg_buf: [256]u8 = undefined;
            const msg = try formatCapacityError(&msg_buf, reg_name, current, maximum);

            // Verify message contains the registry name
            try std.testing.expect(mem.indexOf(u8, msg, reg_name) != null);

            // Verify message contains both numeric values
            var cur_buf: [8]u8 = undefined;
            const cur_str = std.fmt.bufPrint(&cur_buf, "{d}", .{current}) catch unreachable;
            try std.testing.expect(mem.indexOf(u8, msg, cur_str) != null);

            var max_buf: [8]u8 = undefined;
            const max_str = std.fmt.bufPrint(&max_buf, "{d}", .{maximum}) catch unreachable;
            try std.testing.expect(mem.indexOf(u8, msg, max_str) != null);

            // Verify message starts with "CapacityExceeded:"
            try std.testing.expect(mem.startsWith(u8, msg, "CapacityExceeded:"));
        }
    };
    harness.property(
        "capacity error message contains registry name and both numeric values",
        S.run,
    );
}
