const std = @import("std");
const testing = std.testing;

// ── Unit Tests for benchmark output format ───────────────────────────────
// Requirements: 1.2, 1.3

/// Sample benchmark JSON matching the expected output schema from sig_bench.
const sample_single_benchmark =
    \\{
    \\  "suite": "fmt",
    \\  "benchmarks": [
    \\    {
    \\      "name": "formatInto_vs_bufPrint_small",
    \\      "sig_ns_per_op": 42,
    \\      "std_ns_per_op": 67,
    \\      "sig_peak_bytes": 128,
    \\      "std_peak_bytes": 4096
    \\    }
    \\  ]
    \\}
;

const sample_multiple_benchmarks =
    \\{
    \\  "suite": "io",
    \\  "benchmarks": [
    \\    {
    \\      "name": "readInto_vs_manual_read_small",
    \\      "sig_ns_per_op": 15,
    \\      "std_ns_per_op": 30,
    \\      "sig_peak_bytes": 512,
    \\      "std_peak_bytes": 512
    \\    },
    \\    {
    \\      "name": "readInto_vs_manual_read_large",
    \\      "sig_ns_per_op": 100,
    \\      "std_ns_per_op": 200,
    \\      "sig_peak_bytes": 8192,
    \\      "std_peak_bytes": 8192
    \\    }
    \\  ]
    \\}
;

const sample_empty_benchmarks =
    \\{
    \\  "suite": "containers",
    \\  "benchmarks": []
    \\}
;

const BenchmarkEntry = struct {
    name: []const u8,
    sig_ns_per_op: i64,
    std_ns_per_op: i64,
    sig_peak_bytes: i64,
    std_peak_bytes: i64,
};

const BenchmarkResult = struct {
    suite: []const u8,
    benchmarks: []const BenchmarkEntry,
};

// ── Test 1: Sample benchmark JSON can be parsed successfully ─────────────

test "benchmark JSON parses successfully" {
    const parsed = try std.json.parseFromSlice(BenchmarkResult, testing.allocator, sample_single_benchmark, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.suite.len > 0);
}

// ── Test 2: Parsed JSON has "suite" field as a string ────────────────────

test "benchmark JSON has suite field as a string" {
    const parsed = try std.json.parseFromSlice(BenchmarkResult, testing.allocator, sample_single_benchmark, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("fmt", parsed.value.suite);
}

// ── Test 3: Parsed JSON has "benchmarks" field as an array ───────────────

test "benchmark JSON has benchmarks field as an array" {
    const parsed = try std.json.parseFromSlice(BenchmarkResult, testing.allocator, sample_single_benchmark, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.benchmarks.len);
}

// ── Test 4: Each benchmark entry has required fields ─────────────────────

test "benchmark entry has all required fields with correct values" {
    const parsed = try std.json.parseFromSlice(BenchmarkResult, testing.allocator, sample_single_benchmark, .{});
    defer parsed.deinit();
    const entry = parsed.value.benchmarks[0];
    try testing.expectEqualStrings("formatInto_vs_bufPrint_small", entry.name);
    try testing.expectEqual(@as(i64, 42), entry.sig_ns_per_op);
    try testing.expectEqual(@as(i64, 67), entry.std_ns_per_op);
    try testing.expectEqual(@as(i64, 128), entry.sig_peak_bytes);
    try testing.expectEqual(@as(i64, 4096), entry.std_peak_bytes);
}

// ── Test 5: Field types are correct (name is string, numeric fields are integers) ──

test "benchmark entry field types: name is string, numeric fields are integers" {
    const parsed = try std.json.parseFromSlice(BenchmarkResult, testing.allocator, sample_single_benchmark, .{});
    defer parsed.deinit();
    const entry = parsed.value.benchmarks[0];
    // name is a string — verify it's non-empty
    try testing.expect(entry.name.len > 0);
    // numeric fields parsed as i64 — verify they are non-negative (valid timing/size values)
    try testing.expect(entry.sig_ns_per_op >= 0);
    try testing.expect(entry.std_ns_per_op >= 0);
    try testing.expect(entry.sig_peak_bytes >= 0);
    try testing.expect(entry.std_peak_bytes >= 0);
}

// ── Test 6: Multiple benchmark entries can be parsed ─────────────────────

test "benchmark JSON with multiple entries parses correctly" {
    const parsed = try std.json.parseFromSlice(BenchmarkResult, testing.allocator, sample_multiple_benchmarks, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("io", parsed.value.suite);
    try testing.expectEqual(@as(usize, 2), parsed.value.benchmarks.len);
    try testing.expectEqualStrings("readInto_vs_manual_read_small", parsed.value.benchmarks[0].name);
    try testing.expectEqualStrings("readInto_vs_manual_read_large", parsed.value.benchmarks[1].name);
}

// ── Test 7: Edge case — empty benchmarks array is valid ──────────────────

test "benchmark JSON with empty benchmarks array is valid" {
    const parsed = try std.json.parseFromSlice(BenchmarkResult, testing.allocator, sample_empty_benchmarks, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("containers", parsed.value.suite);
    try testing.expectEqual(@as(usize, 0), parsed.value.benchmarks.len);
}
