const std = @import("std");
const testing = std.testing;
const sig_sync = @import("sig_sync");

const SyncEntry = sig_sync.SyncEntry;
const SyncManifest = sig_sync.SyncManifest;

// ── Unit Tests for Sig_Sync manifest serialization, conflict detection, entry recording ──
// Requirements: 10.2, 10.3, 10.4

// ── Serialization / Deserialization ──────────────────────────────────────

test "parseManifest with known single integrated entry" {
    const json =
        \\{
        \\  "last_integrated_commit": "deadbeef1234567890abcdef1234567890abcdef",
        \\  "last_integration_timestamp": 1710000000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "deadbeef1234567890abcdef1234567890abcdef",
        \\      "timestamp": 1710000000,
        \\      "status": "integrated",
        \\      "conflicting_files": null
        \\    }
        \\  ]
        \\}
    ;
    const parsed = try sig_sync.parseManifestOwned(testing.allocator, json);
    defer parsed.deinit();
    const m = parsed.value;

    try testing.expectEqualStrings("deadbeef1234567890abcdef1234567890abcdef", m.last_integrated_commit);
    try testing.expectEqual(@as(i64, 1710000000), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 1), m.entries.len);
    try testing.expectEqualStrings("deadbeef1234567890abcdef1234567890abcdef", m.entries[0].upstream_commit);
    try testing.expectEqual(SyncEntry.Status.integrated, m.entries[0].status);
    try testing.expect(m.entries[0].conflicting_files == null);
}

test "serializeManifest produces valid JSON that round-trips" {
    const allocator = testing.allocator;
    const original = SyncManifest{
        .last_integrated_commit = "aabbccdd00112233445566778899aabbccddeeff",
        .last_integration_timestamp = 1720000000,
        .entries = &.{
            .{
                .upstream_commit = "aabbccdd00112233445566778899aabbccddeeff",
                .timestamp = 1720000000,
                .status = .integrated,
                .conflicting_files = null,
            },
        },
    };

    const json = try sig_sync.serializeManifest(allocator, original);
    defer allocator.free(json);

    const parsed = try sig_sync.parseManifestOwned(allocator, json);
    defer parsed.deinit();
    const m = parsed.value;

    try testing.expectEqualStrings("aabbccdd00112233445566778899aabbccddeeff", m.last_integrated_commit);
    try testing.expectEqual(@as(i64, 1720000000), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 1), m.entries.len);
    try testing.expectEqual(SyncEntry.Status.integrated, m.entries[0].status);
}

// ── Conflict Detection ──────────────────────────────────────────────────

test "conflict entry has non-empty conflicting_files list" {
    const json =
        \\{
        \\  "last_integrated_commit": "1111111111111111111111111111111111111111",
        \\  "last_integration_timestamp": 1700000000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "2222222222222222222222222222222222222222",
        \\      "timestamp": 1700001000,
        \\      "status": "conflict",
        \\      "conflicting_files": ["lib/sig/fmt.zig", "src/main.zig", "build.zig"]
        \\    }
        \\  ]
        \\}
    ;
    const parsed = try sig_sync.parseManifestOwned(testing.allocator, json);
    defer parsed.deinit();
    const entry = parsed.value.entries[0];

    try testing.expectEqual(SyncEntry.Status.conflict, entry.status);
    try testing.expect(entry.conflicting_files != null);
    const files = entry.conflicting_files.?;
    try testing.expectEqual(@as(usize, 3), files.len);
    try testing.expectEqualStrings("lib/sig/fmt.zig", files[0]);
    try testing.expectEqualStrings("src/main.zig", files[1]);
    try testing.expectEqualStrings("build.zig", files[2]);
}

test "integrated entry has null conflicting_files" {
    const json =
        \\{
        \\  "last_integrated_commit": "aaaa000000000000000000000000000000000000",
        \\  "last_integration_timestamp": 1700000000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "aaaa000000000000000000000000000000000000",
        \\      "timestamp": 1700000000,
        \\      "status": "integrated",
        \\      "conflicting_files": null
        \\    }
        \\  ]
        \\}
    ;
    const parsed = try sig_sync.parseManifestOwned(testing.allocator, json);
    defer parsed.deinit();
    const entry = parsed.value.entries[0];

    try testing.expectEqual(SyncEntry.Status.integrated, entry.status);
    try testing.expect(entry.conflicting_files == null);
}

test "conflict entry round-trips through serialize/parse with files preserved" {
    const allocator = testing.allocator;
    const files: []const []const u8 = &.{ "lib/sig/io.zig", "tools/sig_sync/main.zig" };
    const manifest = SyncManifest{
        .last_integrated_commit = "cccccccccccccccccccccccccccccccccccccccc",
        .last_integration_timestamp = 1700005000,
        .entries = &.{
            .{
                .upstream_commit = "dddddddddddddddddddddddddddddddddddddddd"[0..40],
                .timestamp = 1700005000,
                .status = .conflict,
                .conflicting_files = files,
            },
        },
    };

    const json = try sig_sync.serializeManifest(allocator, manifest);
    defer allocator.free(json);

    const parsed = try sig_sync.parseManifestOwned(allocator, json);
    defer parsed.deinit();
    const entry = parsed.value.entries[0];

    try testing.expectEqual(SyncEntry.Status.conflict, entry.status);
    try testing.expect(entry.conflicting_files != null);
    const parsed_files = entry.conflicting_files.?;
    try testing.expectEqual(@as(usize, 2), parsed_files.len);
    try testing.expectEqualStrings("lib/sig/io.zig", parsed_files[0]);
    try testing.expectEqualStrings("tools/sig_sync/main.zig", parsed_files[1]);
}

// ── Entry Recording — all fields preserved ──────────────────────────────

test "all SyncEntry fields preserved through serialize/parse round trip" {
    const allocator = testing.allocator;
    const files: []const []const u8 = &.{"src/Compilation.zig"};
    const manifest = SyncManifest{
        .last_integrated_commit = "abcdef0123456789abcdef0123456789abcdef01",
        .last_integration_timestamp = 1699999999,
        .entries = &.{
            .{
                .upstream_commit = "1234567890abcdef1234567890abcdef12345678",
                .timestamp = 1699999000,
                .status = .integrated,
                .conflicting_files = null,
            },
            .{
                .upstream_commit = "abcdef0123456789abcdef0123456789abcdef01",
                .timestamp = 1699999500,
                .status = .conflict,
                .conflicting_files = files,
            },
            .{
                .upstream_commit = "fedcba9876543210fedcba9876543210fedcba98",
                .timestamp = 1699999999,
                .status = .skipped,
                .conflicting_files = null,
            },
        },
    };

    const json = try sig_sync.serializeManifest(allocator, manifest);
    defer allocator.free(json);

    const parsed = try sig_sync.parseManifestOwned(allocator, json);
    defer parsed.deinit();
    const m = parsed.value;

    // Top-level fields
    try testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", m.last_integrated_commit);
    try testing.expectEqual(@as(i64, 1699999999), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 3), m.entries.len);

    // Entry 0: integrated
    try testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", m.entries[0].upstream_commit);
    try testing.expectEqual(@as(i64, 1699999000), m.entries[0].timestamp);
    try testing.expectEqual(SyncEntry.Status.integrated, m.entries[0].status);
    try testing.expect(m.entries[0].conflicting_files == null);

    // Entry 1: conflict
    try testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", m.entries[1].upstream_commit);
    try testing.expectEqual(@as(i64, 1699999500), m.entries[1].timestamp);
    try testing.expectEqual(SyncEntry.Status.conflict, m.entries[1].status);
    try testing.expect(m.entries[1].conflicting_files != null);
    try testing.expectEqual(@as(usize, 1), m.entries[1].conflicting_files.?.len);
    try testing.expectEqualStrings("src/Compilation.zig", m.entries[1].conflicting_files.?[0]);

    // Entry 2: skipped
    try testing.expectEqualStrings("fedcba9876543210fedcba9876543210fedcba98", m.entries[2].upstream_commit);
    try testing.expectEqual(@as(i64, 1699999999), m.entries[2].timestamp);
    try testing.expectEqual(SyncEntry.Status.skipped, m.entries[2].status);
    try testing.expect(m.entries[2].conflicting_files == null);
}

// ── Edge Cases ──────────────────────────────────────────────────────────

test "empty manifest parses to defaults" {
    const m = try sig_sync.parseManifest(testing.allocator, "");
    try testing.expectEqualStrings("", m.last_integrated_commit);
    try testing.expectEqual(@as(i64, 0), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 0), m.entries.len);
}

test "empty manifest serializes and round-trips" {
    const allocator = testing.allocator;
    const manifest = SyncManifest{};

    const json = try sig_sync.serializeManifest(allocator, manifest);
    defer allocator.free(json);

    const parsed = try sig_sync.parseManifestOwned(allocator, json);
    defer parsed.deinit();
    const m = parsed.value;

    try testing.expectEqualStrings("", m.last_integrated_commit);
    try testing.expectEqual(@as(i64, 0), m.last_integration_timestamp);
    try testing.expectEqual(@as(usize, 0), m.entries.len);
}

test "single entry manifest round-trips correctly" {
    const allocator = testing.allocator;
    const manifest = SyncManifest{
        .last_integrated_commit = "0000000000000000000000000000000000000001",
        .last_integration_timestamp = 1,
        .entries = &.{
            .{
                .upstream_commit = "0000000000000000000000000000000000000001",
                .timestamp = 1,
                .status = .skipped,
                .conflicting_files = null,
            },
        },
    };

    const json = try sig_sync.serializeManifest(allocator, manifest);
    defer allocator.free(json);

    const parsed = try sig_sync.parseManifestOwned(allocator, json);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    try testing.expectEqual(SyncEntry.Status.skipped, parsed.value.entries[0].status);
}

test "many entries manifest round-trips preserving count" {
    const allocator = testing.allocator;
    var entries_buf: [10]SyncEntry = undefined;
    for (&entries_buf, 0..) |*e, i| {
        e.* = .{
            .upstream_commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .timestamp = @as(i64, @intCast(i)) * 1000,
            .status = if (i % 3 == 0) .integrated else if (i % 3 == 1) .conflict else .skipped,
            .conflicting_files = if (i % 3 == 1) @as([]const []const u8, &.{"file.zig"}) else null,
        };
    }

    const manifest = SyncManifest{
        .last_integrated_commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .last_integration_timestamp = 9000,
        .entries = &entries_buf,
    };

    const json = try sig_sync.serializeManifest(allocator, manifest);
    defer allocator.free(json);

    const parsed = try sig_sync.parseManifestOwned(allocator, json);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 10), parsed.value.entries.len);
}

test "large commit hash (all f's) round-trips" {
    const allocator = testing.allocator;
    const big_hash = "ffffffffffffffffffffffffffffffffffffffff";
    const manifest = SyncManifest{
        .last_integrated_commit = big_hash,
        .last_integration_timestamp = 2147483647,
        .entries = &.{
            .{
                .upstream_commit = big_hash,
                .timestamp = 2147483647,
                .status = .integrated,
                .conflicting_files = null,
            },
        },
    };

    const json = try sig_sync.serializeManifest(allocator, manifest);
    defer allocator.free(json);

    const parsed = try sig_sync.parseManifestOwned(allocator, json);
    defer parsed.deinit();

    try testing.expectEqualStrings(big_hash, parsed.value.last_integrated_commit);
    try testing.expectEqualStrings(big_hash, parsed.value.entries[0].upstream_commit);
}

// ── Mixed Statuses ──────────────────────────────────────────────────────

test "multiple entries with mixed statuses preserve all fields" {
    const json =
        \\{
        \\  "last_integrated_commit": "aaaa000000000000000000000000000000000000",
        \\  "last_integration_timestamp": 1700003000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "aaaa000000000000000000000000000000000000",
        \\      "timestamp": 1700001000,
        \\      "status": "integrated",
        \\      "conflicting_files": null
        \\    },
        \\    {
        \\      "upstream_commit": "bbbb000000000000000000000000000000000000",
        \\      "timestamp": 1700002000,
        \\      "status": "conflict",
        \\      "conflicting_files": ["lib/sig/containers.zig"]
        \\    },
        \\    {
        \\      "upstream_commit": "cccc000000000000000000000000000000000000",
        \\      "timestamp": 1700003000,
        \\      "status": "skipped",
        \\      "conflicting_files": null
        \\    }
        \\  ]
        \\}
    ;
    const parsed = try sig_sync.parseManifestOwned(testing.allocator, json);
    defer parsed.deinit();
    const m = parsed.value;

    try testing.expectEqual(@as(usize, 3), m.entries.len);
    try testing.expectEqual(SyncEntry.Status.integrated, m.entries[0].status);
    try testing.expectEqual(SyncEntry.Status.conflict, m.entries[1].status);
    try testing.expectEqual(SyncEntry.Status.skipped, m.entries[2].status);

    // Only the conflict entry has files
    try testing.expect(m.entries[0].conflicting_files == null);
    try testing.expect(m.entries[1].conflicting_files != null);
    try testing.expectEqual(@as(usize, 1), m.entries[1].conflicting_files.?.len);
    try testing.expect(m.entries[2].conflicting_files == null);
}

// ── JSON Structure Verification ─────────────────────────────────────────

test "serialized manifest JSON contains expected top-level keys" {
    const allocator = testing.allocator;
    const manifest = SyncManifest{
        .last_integrated_commit = "0123456789abcdef0123456789abcdef01234567",
        .last_integration_timestamp = 1700000000,
        .entries = &.{
            .{
                .upstream_commit = "0123456789abcdef0123456789abcdef01234567",
                .timestamp = 1700000000,
                .status = .integrated,
                .conflicting_files = null,
            },
        },
    };

    const json = try sig_sync.serializeManifest(allocator, manifest);
    defer allocator.free(json);

    // Verify expected JSON keys are present
    try testing.expect(std.mem.indexOf(u8, json, "\"last_integrated_commit\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"last_integration_timestamp\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"entries\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"upstream_commit\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"timestamp\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"conflicting_files\"") != null);
}

test "serialized manifest contains status string values not enum integers" {
    const allocator = testing.allocator;
    const files: []const []const u8 = &.{"a.zig"};
    const manifest = SyncManifest{
        .last_integrated_commit = "0000000000000000000000000000000000000000",
        .last_integration_timestamp = 0,
        .entries = &.{
            .{ .upstream_commit = "1111111111111111111111111111111111111111", .timestamp = 1, .status = .integrated, .conflicting_files = null },
            .{ .upstream_commit = "2222222222222222222222222222222222222222", .timestamp = 2, .status = .conflict, .conflicting_files = files },
            .{ .upstream_commit = "3333333333333333333333333333333333333333", .timestamp = 3, .status = .skipped, .conflicting_files = null },
        },
    };

    const json = try sig_sync.serializeManifest(allocator, manifest);
    defer allocator.free(json);

    // Status values are serialized as human-readable strings
    try testing.expect(std.mem.indexOf(u8, json, "\"integrated\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"conflict\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"skipped\"") != null);
}

test "invalid JSON input returns default manifest" {
    const m = try sig_sync.parseManifest(testing.allocator, "{invalid json!!}");
    try testing.expectEqual(@as(usize, 0), m.entries.len);
    try testing.expectEqualStrings("", m.last_integrated_commit);
}
