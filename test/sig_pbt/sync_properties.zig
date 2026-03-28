// Feature: sig-memory-model, Property 15: Sync manifest integrity
//
// For any sequence of upstream commits processed by Sig_Sync, the resulting
// manifest shall contain one SyncEntry per processed commit with a valid
// 40-character hex commit hash and a status of integrated, conflict, or
// skipped. Non-conflicting commits shall have status integrated. Conflicting
// commits shall have status conflict with a non-empty conflicting_files list.
//
// **Validates: Requirements 10.2, 10.3, 10.4**

const std = @import("std");
const harness = @import("harness");
const sig_sync = @import("sig_sync");

const SyncEntry = sig_sync.SyncEntry;
const SyncManifest = sig_sync.SyncManifest;

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

const hex_chars = "0123456789abcdef";

/// Generate a random 40-character hex commit hash.
fn genCommitHash(random: std.Random, buf: *[40]u8) void {
    for (buf) |*c| {
        c.* = hex_chars[random.uintAtMost(usize, hex_chars.len - 1)];
    }
}

/// Returns true if `hash` is exactly 40 hex characters.
fn isValidCommitHash(hash: []const u8) bool {
    if (hash.len != 40) return false;
    for (hash) |c| {
        if (!isHexChar(c)) return false;
    }
    return true;
}

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Generate a random SyncEntry.Status.
fn genStatus(random: std.Random) SyncEntry.Status {
    return switch (random.uintAtMost(u8, 2)) {
        0 => .integrated,
        1 => .conflict,
        2 => .skipped,
        else => unreachable,
    };
}

/// Generate a random list of conflicting file paths.
fn genConflictingFiles(random: std.Random, allocator: std.mem.Allocator) ![]const []const u8 {
    const count = 1 + random.uintAtMost(usize, 4); // 1..5 files
    const files = try allocator.alloc([]const u8, count);
    const path_pool = [_][]const u8{
        "lib/sig/fmt.zig",
        "src/main.zig",
        "lib/sig/io.zig",
        "tools/sig_sync/main.zig",
        "lib/sig/containers.zig",
        "src/Compilation.zig",
        "lib/sig/string.zig",
    };
    for (files) |*f| {
        f.* = path_pool[random.uintAtMost(usize, path_pool.len - 1)];
    }
    return files;
}

/// Generate a random SyncEntry with proper invariants:
/// - conflict entries have non-empty conflicting_files
/// - non-conflict entries have null conflicting_files
fn genSyncEntry(random: std.Random, allocator: std.mem.Allocator, hash_buf: *[40]u8) !SyncEntry {
    genCommitHash(random, hash_buf);
    const status = genStatus(random);
    const timestamp = random.int(i64) & 0x7FFFFFFF; // positive timestamp

    const conflicting_files: ?[]const []const u8 = switch (status) {
        .conflict => try genConflictingFiles(random, allocator),
        .integrated, .skipped => null,
    };

    return SyncEntry{
        .upstream_commit = hash_buf,
        .timestamp = timestamp,
        .status = status,
        .conflicting_files = conflicting_files,
    };
}

// ---------------------------------------------------------------------------
// Property 15: Sync manifest integrity
// ---------------------------------------------------------------------------

test "Property 15: serialize-parse round trip preserves one entry per commit" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;

            // Generate 1..8 random entries
            const entry_count = 1 + random.uintAtMost(usize, 7);
            var entries = try gpa.alloc(SyncEntry, entry_count);
            defer gpa.free(entries);

            // We need stable storage for the hash strings
            var hash_bufs = try gpa.alloc([40]u8, entry_count);
            defer gpa.free(hash_bufs);

            // Track allocated conflicting_files for cleanup
            var conflict_allocs = try gpa.alloc(?[]const []const u8, entry_count);
            defer gpa.free(conflict_allocs);

            for (0..entry_count) |i| {
                entries[i] = try genSyncEntry(random, gpa, &hash_bufs[i]);
                conflict_allocs[i] = entries[i].conflicting_files;
            }
            defer {
                for (conflict_allocs) |maybe_files| {
                    if (maybe_files) |files| {
                        gpa.free(files);
                    }
                }
            }

            // Build manifest
            const manifest = SyncManifest{
                .last_integrated_commit = &hash_bufs[0],
                .last_integration_timestamp = entries[0].timestamp,
                .entries = entries,
            };

            // Serialize to JSON
            const json = try sig_sync.serializeManifest(gpa, manifest);
            defer gpa.free(json);

            // Parse back
            const parsed_result = try sig_sync.parseManifestOwned(gpa, json);
            defer parsed_result.deinit();
            const parsed = parsed_result.value;

            // Verify: one entry per commit
            try std.testing.expectEqual(entry_count, parsed.entries.len);
        }
    };
    harness.property(
        "serialize-parse round trip preserves one entry per commit",
        S.run,
    );
}

test "Property 15: every entry has a valid 40-char hex commit hash" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;

            const entry_count = 1 + random.uintAtMost(usize, 7);
            var entries = try gpa.alloc(SyncEntry, entry_count);
            defer gpa.free(entries);

            var hash_bufs = try gpa.alloc([40]u8, entry_count);
            defer gpa.free(hash_bufs);

            var conflict_allocs = try gpa.alloc(?[]const []const u8, entry_count);
            defer gpa.free(conflict_allocs);

            for (0..entry_count) |i| {
                entries[i] = try genSyncEntry(random, gpa, &hash_bufs[i]);
                conflict_allocs[i] = entries[i].conflicting_files;
            }
            defer {
                for (conflict_allocs) |maybe_files| {
                    if (maybe_files) |files| {
                        gpa.free(files);
                    }
                }
            }

            const manifest = SyncManifest{
                .last_integrated_commit = &hash_bufs[0],
                .last_integration_timestamp = entries[0].timestamp,
                .entries = entries,
            };

            const json = try sig_sync.serializeManifest(gpa, manifest);
            defer gpa.free(json);

            const parsed_result = try sig_sync.parseManifestOwned(gpa, json);
            defer parsed_result.deinit();
            const parsed = parsed_result.value;

            // Verify: each entry has a valid 40-char hex commit hash
            for (parsed.entries) |entry| {
                try std.testing.expect(isValidCommitHash(entry.upstream_commit));
            }
        }
    };
    harness.property(
        "every entry has a valid 40-char hex commit hash",
        S.run,
    );
}

test "Property 15: status is one of integrated, conflict, or skipped" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;

            const entry_count = 1 + random.uintAtMost(usize, 7);
            var entries = try gpa.alloc(SyncEntry, entry_count);
            defer gpa.free(entries);

            var hash_bufs = try gpa.alloc([40]u8, entry_count);
            defer gpa.free(hash_bufs);

            var conflict_allocs = try gpa.alloc(?[]const []const u8, entry_count);
            defer gpa.free(conflict_allocs);

            for (0..entry_count) |i| {
                entries[i] = try genSyncEntry(random, gpa, &hash_bufs[i]);
                conflict_allocs[i] = entries[i].conflicting_files;
            }
            defer {
                for (conflict_allocs) |maybe_files| {
                    if (maybe_files) |files| {
                        gpa.free(files);
                    }
                }
            }

            const manifest = SyncManifest{
                .last_integrated_commit = &hash_bufs[0],
                .last_integration_timestamp = entries[0].timestamp,
                .entries = entries,
            };

            const json = try sig_sync.serializeManifest(gpa, manifest);
            defer gpa.free(json);

            const parsed_result = try sig_sync.parseManifestOwned(gpa, json);
            defer parsed_result.deinit();
            const parsed = parsed_result.value;

            // Verify: status is one of the three valid values
            for (parsed.entries) |entry| {
                const valid = entry.status == .integrated or
                    entry.status == .conflict or
                    entry.status == .skipped;
                try std.testing.expect(valid);
            }
        }
    };
    harness.property(
        "status is one of integrated, conflict, or skipped",
        S.run,
    );
}

test "Property 15: conflict entries have non-empty conflicting_files, others have null" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;

            const entry_count = 1 + random.uintAtMost(usize, 7);
            var entries = try gpa.alloc(SyncEntry, entry_count);
            defer gpa.free(entries);

            var hash_bufs = try gpa.alloc([40]u8, entry_count);
            defer gpa.free(hash_bufs);

            var conflict_allocs = try gpa.alloc(?[]const []const u8, entry_count);
            defer gpa.free(conflict_allocs);

            for (0..entry_count) |i| {
                entries[i] = try genSyncEntry(random, gpa, &hash_bufs[i]);
                conflict_allocs[i] = entries[i].conflicting_files;
            }
            defer {
                for (conflict_allocs) |maybe_files| {
                    if (maybe_files) |files| {
                        gpa.free(files);
                    }
                }
            }

            const manifest = SyncManifest{
                .last_integrated_commit = &hash_bufs[0],
                .last_integration_timestamp = entries[0].timestamp,
                .entries = entries,
            };

            const json = try sig_sync.serializeManifest(gpa, manifest);
            defer gpa.free(json);

            const parsed_result = try sig_sync.parseManifestOwned(gpa, json);
            defer parsed_result.deinit();
            const parsed = parsed_result.value;

            for (parsed.entries) |entry| {
                switch (entry.status) {
                    .conflict => {
                        // Conflict entries must have non-empty conflicting_files
                        try std.testing.expect(entry.conflicting_files != null);
                        try std.testing.expect(entry.conflicting_files.?.len > 0);
                    },
                    .integrated, .skipped => {
                        // Non-conflict entries must have null conflicting_files
                        try std.testing.expect(entry.conflicting_files == null);
                    },
                }
            }
        }
    };
    harness.property(
        "conflict entries have non-empty conflicting_files, others have null",
        S.run,
    );
}
