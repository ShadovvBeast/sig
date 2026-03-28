const std = @import("std");
const testing = std.testing;
const readme = @import("sig_readme");

const Writer = std.Io.Writer;
const SyncManifest = readme.SyncManifest;

/// Helper: generate README output with given manifest and suites.
fn generateReadme(manifest: SyncManifest, suites: []const readme.BenchmarkSuite) ![]const u8 {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try readme.writeReadme(&aw.writer, manifest, suites);
    return try testing.allocator.dupe(u8, aw.written());
}

// ── Unit Tests ───────────────────────────────────────────────────────────

test "README contains 'Memory is not a guess' tagline" {
    const output = try generateReadme(SyncManifest{}, &.{});
    defer testing.allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, output, "Memory is not a guess") != null);
}

test "README renders benchmark table from sample JSON data" {
    const benchmarks = [_]readme.BenchmarkEntry{
        .{
            .name = "formatInto_vs_bufPrint_small",
            .sig_ns_per_op = 42,
            .std_ns_per_op = 67,
            .sig_peak_bytes = 128,
            .std_peak_bytes = 4096,
        },
        .{
            .name = "readInto_4KB",
            .sig_ns_per_op = 1200,
            .std_ns_per_op = 2100,
            .sig_peak_bytes = 4096,
            .std_peak_bytes = 8192,
        },
    };
    const suites = [_]readme.BenchmarkSuite{
        .{ .suite = "Formatting", .benchmarks = benchmarks[0..1] },
        .{ .suite = "I/O Reads", .benchmarks = benchmarks[1..2] },
    };
    const output = try generateReadme(SyncManifest{}, &suites);
    defer testing.allocator.free(output);

    // Suite headers present
    try testing.expect(std.mem.indexOf(u8, output, "### Formatting") != null);
    try testing.expect(std.mem.indexOf(u8, output, "### I/O Reads") != null);
    // Benchmark names present
    try testing.expect(std.mem.indexOf(u8, output, "formatInto_vs_bufPrint_small") != null);
    try testing.expect(std.mem.indexOf(u8, output, "readInto_4KB") != null);
    // Sig values rendered bold
    try testing.expect(std.mem.indexOf(u8, output, "**42**") != null);
    try testing.expect(std.mem.indexOf(u8, output, "**1200**") != null);
    // Std values present
    try testing.expect(std.mem.indexOf(u8, output, "67") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2100") != null);
    // Table header row present
    try testing.expect(std.mem.indexOf(u8, output, "Sig (ns/op)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Zig (ns/op)") != null);
}

test "README sync status includes commit hash and timestamp" {
    const commit = "deadbeef1234567890abcdef1234567890abcdef";
    const manifest = SyncManifest{
        .last_integrated_commit = commit,
        .last_integration_timestamp = 1700000000,
    };
    const output = try generateReadme(manifest, &.{});
    defer testing.allocator.free(output);

    // Full commit hash appears
    try testing.expect(std.mem.indexOf(u8, output, commit) != null);
    // Timestamp appears
    try testing.expect(std.mem.indexOf(u8, output, "1700000000") != null);
    // Short hash link to upstream
    try testing.expect(std.mem.indexOf(u8, output, "deadbee") != null);
    try testing.expect(std.mem.indexOf(u8, output, "https://github.com/ziglang/zig/commit/") != null);
}

test "README contains all required sections" {
    const manifest = SyncManifest{
        .last_integrated_commit = "abc1234567890def1234567890abcdef12345678",
        .last_integration_timestamp = 1700000000,
    };
    const output = try generateReadme(manifest, &.{});
    defer testing.allocator.free(output);

    const required_sections = [_][]const u8{
        "## Why Sig?",
        "## Benchmarks",
        "## The Spoon Model",
        "## Sync Status",
        "## Getting Started",
        "## Memory Model at a Glance",
        "## Error Model",
        "## Contributing",
        "## License",
    };
    for (required_sections) |section| {
        try testing.expect(std.mem.indexOf(u8, output, section) != null);
    }
}

// ── Property 21: README reflects current sync and benchmark state ────────
// Validates: Requirements 1.7, 1.9

test "Property 21: sync commit hash from manifest appears in generated README" {
    // For any sync manifest with a commit hash, the generated README shall
    // contain that exact commit hash string.
    const commit = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const manifest = SyncManifest{
        .last_integrated_commit = commit,
        .last_integration_timestamp = 1710000000,
    };
    const output = try generateReadme(manifest, &.{});
    defer testing.allocator.free(output);

    // The full commit hash must appear in the output (Req 1.7)
    try testing.expect(std.mem.indexOf(u8, output, commit) != null);
    // The timestamp must appear in the output (Req 1.7)
    try testing.expect(std.mem.indexOf(u8, output, "1710000000") != null);
}

test "Property 21: benchmark numeric values from input appear in generated README" {
    // For any benchmark result set, the generated README shall contain the
    // numeric values from the benchmark results (Req 1.9).
    const benchmarks = [_]readme.BenchmarkEntry{
        .{
            .name = "test_operation_alpha",
            .sig_ns_per_op = 777,
            .std_ns_per_op = 1234,
            .sig_peak_bytes = 512,
            .std_peak_bytes = 2048,
        },
    };
    const suites = [_]readme.BenchmarkSuite{
        .{ .suite = "TestSuite", .benchmarks = &benchmarks },
    };
    const output = try generateReadme(SyncManifest{}, &suites);
    defer testing.allocator.free(output);

    // Benchmark operation name must appear
    try testing.expect(std.mem.indexOf(u8, output, "test_operation_alpha") != null);
    // Sig ns/op value must appear (rendered bold)
    try testing.expect(std.mem.indexOf(u8, output, "**777**") != null);
    // Std ns/op value must appear
    try testing.expect(std.mem.indexOf(u8, output, "1234") != null);
    // Suite name must appear as header
    try testing.expect(std.mem.indexOf(u8, output, "### TestSuite") != null);
}

test "Property 21: different manifest data produces different sync sections" {
    // Verifies that the README actually reflects the *current* state, not
    // hardcoded values — two different manifests produce different outputs.
    const commit_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const commit_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    const output_a = try generateReadme(.{
        .last_integrated_commit = commit_a,
        .last_integration_timestamp = 1000000001,
    }, &.{});
    defer testing.allocator.free(output_a);

    const output_b = try generateReadme(.{
        .last_integrated_commit = commit_b,
        .last_integration_timestamp = 1000000002,
    }, &.{});
    defer testing.allocator.free(output_b);

    // Each output contains its own commit, not the other's
    try testing.expect(std.mem.indexOf(u8, output_a, commit_a) != null);
    try testing.expect(std.mem.indexOf(u8, output_a, commit_b) == null);
    try testing.expect(std.mem.indexOf(u8, output_b, commit_b) != null);
    try testing.expect(std.mem.indexOf(u8, output_b, commit_a) == null);

    // Timestamps differ
    try testing.expect(std.mem.indexOf(u8, output_a, "1000000001") != null);
    try testing.expect(std.mem.indexOf(u8, output_b, "1000000002") != null);
}
