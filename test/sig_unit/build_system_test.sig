// Unit tests for the Sig Build System name derivation and discovery logic.
//
// These tests verify specific known inputs for the string transformations
// used by the build system discovery functions in build.sig:
// - std.fs.path.stem() for extension stripping
// - Underscore-to-hyphen replacement for tool step names
// - "sig_" prefix for tool extra import names
// - Suffix matching for file discovery
//
// Requirements: 2.2, 5.2, 6.5, 10.1

const std = @import("std");
const testing = std.testing;

// ── Test 1: stem strips .zig extension ──────────────────────────────────

test "stem strips .zig extension from fmt.zig" {
    const stem = std.fs.path.stem("fmt.zig");
    try testing.expectEqualStrings("fmt", stem);
}

test "stem strips .zig extension from sig_diagnostics.zig" {
    const stem = std.fs.path.stem("sig_diagnostics.zig");
    try testing.expectEqualStrings("sig_diagnostics", stem);
}

// ── Test 2: stem strips .sig extension ──────────────────────────────────

test "stem strips .sig extension from fmt_properties.sig" {
    const stem = std.fs.path.stem("fmt_properties.sig");
    try testing.expectEqualStrings("fmt_properties", stem);
}

test "stem strips .sig extension from harness.sig" {
    const stem = std.fs.path.stem("harness.sig");
    try testing.expectEqualStrings("harness", stem);
}

// ── Test 3: tool step name derivation ───────────────────────────────────

fn deriveStepName(dir_name: []const u8, buf: []u8) []u8 {
    const prefix = "run-";
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..dir_name.len], dir_name);
    const raw = buf[0 .. prefix.len + dir_name.len];
    for (raw) |*c| {
        if (c.* == '_') c.* = '-';
    }
    return raw;
}

test "tool step name: sig_sync -> run-sig-sync" {
    var buf: [128]u8 = undefined;
    const step = deriveStepName("sig_sync", &buf);
    try testing.expectEqualStrings("run-sig-sync", step);
}

test "tool step name: sig_conflict_resolver -> run-sig-conflict-resolver" {
    var buf: [128]u8 = undefined;
    const step = deriveStepName("sig_conflict_resolver", &buf);
    try testing.expectEqualStrings("run-sig-conflict-resolver", step);
}

test "tool step name: sig_sync_watcher -> run-sig-sync-watcher" {
    var buf: [128]u8 = undefined;
    const step = deriveStepName("sig_sync_watcher", &buf);
    try testing.expectEqualStrings("run-sig-sync-watcher", step);
}

test "tool step name: sig_coverage -> run-sig-coverage" {
    var buf: [128]u8 = undefined;
    const step = deriveStepName("sig_coverage", &buf);
    try testing.expectEqualStrings("run-sig-coverage", step);
}

test "tool step name: sig_readme -> run-sig-readme" {
    var buf: [128]u8 = undefined;
    const step = deriveStepName("sig_readme", &buf);
    try testing.expectEqualStrings("run-sig-readme", step);
}

// ── Test 4: edge cases — single char and multiple underscores ───────────

test "stem handles single-character filename" {
    const stem = std.fs.path.stem("a.zig");
    try testing.expectEqualStrings("a", stem);
}

test "stem handles single-character .sig filename" {
    const stem = std.fs.path.stem("x.sig");
    try testing.expectEqualStrings("x", stem);
}

test "stem handles filename with multiple underscores" {
    const stem = std.fs.path.stem("my_long_module_name.zig");
    try testing.expectEqualStrings("my_long_module_name", stem);
}

test "tool step name with many underscores replaces all" {
    var buf: [128]u8 = undefined;
    const step = deriveStepName("sig_a_b_c_d", &buf);
    try testing.expectEqualStrings("run-sig-a-b-c-d", step);
    // Verify no underscores remain
    for (step) |c| {
        try testing.expect(c != '_');
    }
}

// ── Test 5: suffix matching ─────────────────────────────────────────────

test "suffix matching: _properties.sig matches _properties suffix" {
    const filename = "fmt_properties.sig";
    const ext = ".sig";
    const suffix = "_properties";

    try testing.expect(std.mem.endsWith(u8, filename, ext));
    const without_ext = filename[0 .. filename.len - ext.len];
    try testing.expect(std.mem.endsWith(u8, without_ext, suffix));
}

test "suffix matching: _test.sig matches _test suffix" {
    const filename = "fmt_test.sig";
    const ext = ".sig";
    const suffix = "_test";

    try testing.expect(std.mem.endsWith(u8, filename, ext));
    const without_ext = filename[0 .. filename.len - ext.len];
    try testing.expect(std.mem.endsWith(u8, without_ext, suffix));
}

test "suffix matching: plain .sig does not match _properties suffix" {
    const filename = "harness.sig";
    const ext = ".sig";
    const suffix = "_properties";

    try testing.expect(std.mem.endsWith(u8, filename, ext));
    const without_ext = filename[0 .. filename.len - ext.len];
    try testing.expect(!std.mem.endsWith(u8, without_ext, suffix));
}

test "suffix matching: _bench.sig matches _bench suffix" {
    const filename = "fmt_bench.sig";
    const ext = ".sig";
    const suffix = "_bench";

    try testing.expect(std.mem.endsWith(u8, filename, ext));
    const without_ext = filename[0 .. filename.len - ext.len];
    try testing.expect(std.mem.endsWith(u8, without_ext, suffix));
}

// ── Test 6: tool extra import naming ────────────────────────────────────

test "tool extra: validator.sig -> import name sig_validator" {
    const stem = std.fs.path.stem("validator.sig");
    try testing.expectEqualStrings("validator", stem);

    // Build import name: "sig_" + stem
    const prefix = "sig_";
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..stem.len], stem);
    const import_name = buf[0 .. prefix.len + stem.len];

    try testing.expectEqualStrings("sig_validator", import_name);
}

test "tool extra: prompt.sig -> import name sig_prompt" {
    const stem = std.fs.path.stem("prompt.sig");
    try testing.expectEqualStrings("prompt", stem);

    const prefix = "sig_";
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..stem.len], stem);
    const import_name = buf[0 .. prefix.len + stem.len];

    try testing.expectEqualStrings("sig_prompt", import_name);
}

// ── Test 7: tool description derivation ─────────────────────────────────

fn deriveDescription(dir_name: []const u8, buf: []u8) []u8 {
    const prefix = "Run ";
    const suffix_str = " tool";
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..dir_name.len], dir_name);
    pos += dir_name.len;
    @memcpy(buf[pos..][0..suffix_str.len], suffix_str);
    pos += suffix_str.len;
    return buf[0..pos];
}

test "tool description: sig_sync -> Run sig_sync tool" {
    var buf: [128]u8 = undefined;
    const desc = deriveDescription("sig_sync", &buf);
    try testing.expectEqualStrings("Run sig_sync tool", desc);
}

test "tool description: sig_conflict_resolver -> Run sig_conflict_resolver tool" {
    var buf: [128]u8 = undefined;
    const desc = deriveDescription("sig_conflict_resolver", &buf);
    try testing.expectEqualStrings("Run sig_conflict_resolver tool", desc);
}

// ── Test 8: .zig module discovery name derivation ───────────────────────

test "module discovery: sig.zig -> sig" {
    try testing.expectEqualStrings("sig", std.fs.path.stem("sig.zig"));
}

test "module discovery: containers.zig -> containers" {
    try testing.expectEqualStrings("containers", std.fs.path.stem("containers.zig"));
}

test "module discovery: sig_diagnostics_integration.zig -> sig_diagnostics_integration" {
    try testing.expectEqualStrings("sig_diagnostics_integration", std.fs.path.stem("sig_diagnostics_integration.zig"));
}
