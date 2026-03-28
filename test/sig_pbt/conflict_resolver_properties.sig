// Feature: sig-memory-model, Property 34: AI-resolved manifest round-trip
//
// For any manifest with `ai_resolved` entries, serialize-then-parse shall
// preserve all fields including ai_resolution_details. Pre-Phase 3 manifests
// (no ai_resolved entries) shall parse with default AI details.
//
// **Validates: Requirements 22.3, 22.4, 22.5**

const std = @import("std");
const harness = @import("harness");
const sig_sync = @import("sig_sync");

const SyncEntry = sig_sync.SyncEntry;
const SyncManifest = sig_sync.SyncManifest;
const AiResolutionDetails = sig_sync.AiResolutionDetails;

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

const hex_chars = "0123456789abcdef";

/// Generate a random 40-character hex commit hash into a fixed buffer.
fn genCommitHash(random: std.Random, buf: *[40]u8) void {
    for (buf) |*c| {
        c.* = hex_chars[random.uintAtMost(usize, hex_chars.len - 1)];
    }
}

/// Generate a random SyncEntry.Status including ai_resolved.
fn genStatus(random: std.Random) SyncEntry.Status {
    return switch (random.uintAtMost(u8, 3)) {
        0 => .integrated,
        1 => .conflict,
        2 => .skipped,
        3 => .ai_resolved,
        else => unreachable,
    };
}

/// Pool of file paths for conflict entries.
const path_pool = [_][]const u8{
    "lib/sig/fmt.zig",
    "src/main.zig",
    "lib/sig/io.zig",
    "tools/sig_sync/main.sig",
    "lib/sig/containers.zig",
};

/// Explanation fragments for AI resolution details.
const explanation_pool = [_][]const u8{
    "Accepted upstream changes",
    "Repositioned sig block after upstream refactor",
    "Merged import lists and kept sig additions",
    "Trivial whitespace conflict auto-resolved",
    "Upstream renamed function, sig block relocated",
};

/// Generate a random SyncEntry with all fields populated on the stack.
fn genSyncEntry(random: std.Random) SyncEntry {
    var entry = SyncEntry{};

    // Random commit hash
    var hash_buf: [40]u8 = undefined;
    genCommitHash(random, &hash_buf);
    entry.setCommit(&hash_buf);

    // Positive timestamp
    entry.timestamp = @as(i64, @intCast(random.uintAtMost(u32, 2000000000)));
    entry.status = genStatus(random);

    // Conflict entries get random conflicting files
    if (entry.status == .conflict or entry.status == .ai_resolved) {
        const file_count = 1 + random.uintAtMost(usize, 3);
        var i: usize = 0;
        while (i < file_count) : (i += 1) {
            entry.addConflictFile(path_pool[random.uintAtMost(usize, path_pool.len - 1)]);
        }
    }

    // ai_resolved entries get AI details
    if (entry.status == .ai_resolved) {
        entry.has_ai_details = true;
        entry.ai_details.confidence = @intCast(random.uintAtMost(u8, 100));
        entry.ai_details.resolved_file_count = @intCast(1 + random.uintAtMost(u8, 7));
        const expl = explanation_pool[random.uintAtMost(usize, explanation_pool.len - 1)];
        entry.ai_details.setExplanation(expl);
    }

    return entry;
}

/// Generate a random SyncEntry that is NOT ai_resolved (pre-Phase 3).
fn genPrePhase3Entry(random: std.Random) SyncEntry {
    var entry = SyncEntry{};

    var hash_buf: [40]u8 = undefined;
    genCommitHash(random, &hash_buf);
    entry.setCommit(&hash_buf);

    entry.timestamp = @as(i64, @intCast(random.uintAtMost(u32, 2000000000)));

    // Only integrated, conflict, or skipped
    entry.status = switch (random.uintAtMost(u8, 2)) {
        0 => .integrated,
        1 => .conflict,
        2 => .skipped,
        else => unreachable,
    };

    if (entry.status == .conflict) {
        const file_count = 1 + random.uintAtMost(usize, 3);
        var i: usize = 0;
        while (i < file_count) : (i += 1) {
            entry.addConflictFile(path_pool[random.uintAtMost(usize, path_pool.len - 1)]);
        }
    }

    return entry;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn expectEntryEqual(original: *const SyncEntry, parsed: *const SyncEntry) !void {
    // Commit hash
    try std.testing.expectEqualStrings(original.commit(), parsed.commit());

    // Timestamp
    try std.testing.expectEqual(original.timestamp, parsed.timestamp);

    // Status
    try std.testing.expectEqual(original.status, parsed.status);

    // AI details
    try std.testing.expectEqual(original.has_ai_details, parsed.has_ai_details);
    if (original.has_ai_details) {
        try std.testing.expectEqual(original.ai_details.confidence, parsed.ai_details.confidence);
        try std.testing.expectEqual(original.ai_details.resolved_file_count, parsed.ai_details.resolved_file_count);
        try std.testing.expectEqualStrings(original.ai_details.explanation(), parsed.ai_details.explanation());
    }
}

// ---------------------------------------------------------------------------
// Property 34: AI-resolved manifest round-trip
// ---------------------------------------------------------------------------

test "Property 34: serialize-then-parse preserves all fields including ai_resolution_details" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Build a manifest with 1..8 random entries (mixed statuses)
            var manifest = SyncManifest{};
            var last_hash: [40]u8 = undefined;
            genCommitHash(random, &last_hash);
            manifest.setLastCommit(&last_hash);
            manifest.last_integration_timestamp = @as(i64, @intCast(random.uintAtMost(u32, 2000000000)));

            const entry_count = 1 + random.uintAtMost(usize, 7);
            var i: usize = 0;
            while (i < entry_count) : (i += 1) {
                manifest.addEntry(genSyncEntry(random));
            }

            // Serialize into a stack buffer
            var buf: [512 * 1024]u8 = undefined;
            const serialized = sig_sync.serializeManifest(&manifest, &buf) catch |err| {
                std.debug.print("serializeManifest failed: {}\n", .{err});
                return err;
            };

            // Parse back
            const parsed = sig_sync.parseManifest(serialized);

            // Verify top-level fields
            try std.testing.expectEqualStrings(manifest.lastCommit(), parsed.lastCommit());
            try std.testing.expectEqual(manifest.last_integration_timestamp, parsed.last_integration_timestamp);
            try std.testing.expectEqual(manifest.entry_count, parsed.entry_count);

            // Verify each entry
            var j: usize = 0;
            while (j < manifest.entry_count) : (j += 1) {
                try expectEntryEqual(&manifest.entries[j], &parsed.entries[j]);
            }
        }
    };
    harness.property(
        "serialize-then-parse preserves all fields including ai_resolution_details",
        S.run,
    );
}

test "Property 34: pre-Phase 3 manifests parse with default AI details" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Build a manifest with ONLY pre-Phase 3 entries (no ai_resolved)
            var manifest = SyncManifest{};
            var last_hash: [40]u8 = undefined;
            genCommitHash(random, &last_hash);
            manifest.setLastCommit(&last_hash);
            manifest.last_integration_timestamp = @as(i64, @intCast(random.uintAtMost(u32, 2000000000)));

            const entry_count = 1 + random.uintAtMost(usize, 7);
            var i: usize = 0;
            while (i < entry_count) : (i += 1) {
                manifest.addEntry(genPrePhase3Entry(random));
            }

            // Serialize
            var buf: [512 * 1024]u8 = undefined;
            const serialized = sig_sync.serializeManifest(&manifest, &buf) catch |err| {
                std.debug.print("serializeManifest failed: {}\n", .{err});
                return err;
            };

            // Parse back
            const parsed = sig_sync.parseManifest(serialized);

            try std.testing.expectEqual(manifest.entry_count, parsed.entry_count);

            // Every entry should have has_ai_details == false and default AI details
            var j: usize = 0;
            while (j < parsed.entry_count) : (j += 1) {
                const entry = &parsed.entries[j];
                try std.testing.expect(!entry.has_ai_details);
                try std.testing.expectEqual(@as(u8, 0), entry.ai_details.confidence);
                try std.testing.expectEqual(@as(u8, 0), entry.ai_details.resolved_file_count);
                try std.testing.expectEqual(@as(usize, 0), entry.ai_details.explanation_len);

                // Status should never be ai_resolved
                try std.testing.expect(entry.status != .ai_resolved);
            }
        }
    };
    harness.property(
        "pre-Phase 3 manifests parse with default AI details",
        S.run,
    );
}

// ---------------------------------------------------------------------------
// Feature: sig-memory-model, Property 35: Resolved content validation
//
// For any resolved content, the validator shall reject content containing
// conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) or invalid UTF-8.
//
// **Validates: Requirements 24.2, 24.3**
// ---------------------------------------------------------------------------

const sig_validator = @import("sig_validator");

// ---------------------------------------------------------------------------
// Generators for Property 35
// ---------------------------------------------------------------------------

/// Pool of printable ASCII characters for generating clean content.
/// Excludes `<`, `=`, `>` to guarantee no conflict markers can form.
const ascii_pool = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 \t\n.,;:!?-_/()[]{}@#$%^&*+~`|";

/// Generate random ASCII content (no conflict markers) into a stack buffer.
/// Returns the filled slice.
fn genCleanAscii(random: std.Random, buf: []u8) []u8 {
    if (buf.len == 0) return buf[0..0];
    const len = 1 + random.uintAtMost(usize, buf.len - 1);
    for (buf[0..len]) |*c| {
        c.* = ascii_pool[random.uintAtMost(usize, ascii_pool.len - 1)];
    }
    return buf[0..len];
}

/// The three conflict marker patterns.
const conflict_markers = [_][]const u8{
    "<<<<<<<",
    "=======",
    ">>>>>>>",
};

/// Generate content with a conflict marker injected at a random position.
/// Returns the total length written into buf.
fn genContentWithMarker(random: std.Random, buf: []u8) []u8 {
    // Pick a marker
    const marker = conflict_markers[random.uintAtMost(usize, conflict_markers.len - 1)];

    // Generate a prefix length (0..buf.len - marker.len)
    const max_prefix = if (buf.len > marker.len) buf.len - marker.len else 0;
    const prefix_len = random.uintAtMost(usize, max_prefix);

    // Fill prefix with clean ASCII
    for (buf[0..prefix_len]) |*c| {
        c.* = ascii_pool[random.uintAtMost(usize, ascii_pool.len - 1)];
    }

    // Copy marker
    @memcpy(buf[prefix_len .. prefix_len + marker.len], marker);

    // Fill suffix with clean ASCII
    const after_marker = prefix_len + marker.len;
    const suffix_max = buf.len - after_marker;
    const suffix_len = random.uintAtMost(usize, suffix_max);
    for (buf[after_marker .. after_marker + suffix_len]) |*c| {
        c.* = ascii_pool[random.uintAtMost(usize, ascii_pool.len - 1)];
    }

    return buf[0 .. after_marker + suffix_len];
}

/// Generate valid UTF-8 content by emitting random codepoints in the valid ranges.
/// Returns the filled slice.
fn genValidUtf8(random: std.Random, buf: []u8) []u8 {
    var pos: usize = 0;
    // Generate 1..64 random valid codepoints
    const count = 1 + random.uintAtMost(usize, 63);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        // Pick a codepoint range: ASCII, 2-byte, 3-byte, or 4-byte
        const range = random.uintAtMost(u8, 3);
        switch (range) {
            0 => {
                // ASCII: U+0000..U+007F (1 byte)
                if (pos + 1 > buf.len) break;
                buf[pos] = @intCast(random.uintAtMost(u7, 0x7F));
                pos += 1;
            },
            1 => {
                // 2-byte: U+0080..U+07FF
                if (pos + 2 > buf.len) break;
                const cp = 0x80 + random.uintAtMost(u16, 0x07FF - 0x80);
                buf[pos] = @intCast(0xC0 | (cp >> 6));
                buf[pos + 1] = @intCast(0x80 | (cp & 0x3F));
                pos += 2;
            },
            2 => {
                // 3-byte: U+0800..U+FFFF (excluding surrogates U+D800..U+DFFF)
                if (pos + 3 > buf.len) break;
                var cp = 0x0800 + random.uintAtMost(u16, 0xFFFF - 0x0800);
                // Skip surrogates
                if (cp >= 0xD800 and cp <= 0xDFFF) {
                    cp = 0xE000; // Jump past surrogates
                }
                buf[pos] = @intCast(0xE0 | (cp >> 12));
                buf[pos + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                buf[pos + 2] = @intCast(0x80 | (cp & 0x3F));
                pos += 3;
            },
            3 => {
                // 4-byte: U+10000..U+10FFFF
                if (pos + 4 > buf.len) break;
                const cp: u21 = 0x10000 + random.uintAtMost(u21, 0x10FFFF - 0x10000);
                buf[pos] = @intCast(0xF0 | (cp >> 18));
                buf[pos + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
                buf[pos + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                buf[pos + 3] = @intCast(0x80 | (cp & 0x3F));
                pos += 4;
            },
            else => unreachable,
        }
    }
    return buf[0..pos];
}

/// Generate content with invalid UTF-8 bytes injected.
/// Returns the filled slice.
fn genInvalidUtf8(random: std.Random, buf: []u8) []u8 {
    if (buf.len < 2) {
        // Minimum: one invalid byte
        buf[0] = 0xFF;
        return buf[0..1];
    }

    // Fill with some valid ASCII first
    const prefix_len = random.uintAtMost(usize, buf.len - 1);
    for (buf[0..prefix_len]) |*c| {
        c.* = @intCast(0x20 + random.uintAtMost(u8, 0x5E)); // printable ASCII
    }

    // Inject an invalid byte pattern at the current position
    const strategy = random.uintAtMost(u8, 3);
    var pos = prefix_len;
    switch (strategy) {
        0 => {
            // Bare 0xFF — always invalid
            buf[pos] = 0xFF;
            pos += 1;
        },
        1 => {
            // Bare 0xFE — always invalid
            buf[pos] = 0xFE;
            pos += 1;
        },
        2 => {
            // Truncated 2-byte sequence: leading byte with no continuation
            buf[pos] = 0xC2; // valid 2-byte lead
            pos += 1;
            // No continuation byte — end of content
        },
        3 => {
            // Truncated 3-byte sequence: leading byte + 1 continuation only
            if (pos + 2 <= buf.len) {
                buf[pos] = 0xE0; // valid 3-byte lead
                buf[pos + 1] = 0xA0; // valid continuation
                pos += 2;
                // Missing third byte — end of content
            } else {
                buf[pos] = 0xFF;
                pos += 1;
            }
        },
        else => unreachable,
    }

    return buf[0..pos];
}

// ---------------------------------------------------------------------------
// Property 35 Tests
// ---------------------------------------------------------------------------

test "Property 35: clean ASCII content passes validation" {
    // Feature: sig-memory-model, Property 35: Resolved content validation
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var buf: [512]u8 = undefined;
            const content = genCleanAscii(random, &buf);

            // validateResolution should return true (no markers)
            try std.testing.expect(sig_validator.validateResolution(content));

            // validateResolvedContent should have valid=true
            const result = sig_validator.validateResolvedContent(content);
            try std.testing.expect(result.valid);
            try std.testing.expect(!result.has_conflict_markers);
            try std.testing.expect(!result.has_invalid_utf8);
        }
    };
    harness.property(
        "clean ASCII content passes validation",
        S.run,
    );
}

test "Property 35: content with injected conflict marker fails validation" {
    // Feature: sig-memory-model, Property 35: Resolved content validation
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var buf: [512]u8 = undefined;
            const content = genContentWithMarker(random, &buf);

            // validateResolution should return false (marker present)
            try std.testing.expect(!sig_validator.validateResolution(content));

            // validateResolvedContent should flag conflict markers
            const result = sig_validator.validateResolvedContent(content);
            try std.testing.expect(!result.valid);
            try std.testing.expect(result.has_conflict_markers);
        }
    };
    harness.property(
        "content with injected conflict marker fails validation",
        S.run,
    );
}

test "Property 35: valid UTF-8 content passes UTF-8 validation" {
    // Feature: sig-memory-model, Property 35: Resolved content validation
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var buf: [512]u8 = undefined;
            const content = genValidUtf8(random, &buf);

            // isValidUtf8 should return true
            try std.testing.expect(sig_validator.isValidUtf8(content));
        }
    };
    harness.property(
        "valid UTF-8 content passes UTF-8 validation",
        S.run,
    );
}

test "Property 35: invalid UTF-8 content fails validation" {
    // Feature: sig-memory-model, Property 35: Resolved content validation
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var buf: [512]u8 = undefined;
            const content = genInvalidUtf8(random, &buf);

            // isValidUtf8 should return false
            try std.testing.expect(!sig_validator.isValidUtf8(content));

            // validateResolvedContent should flag invalid UTF-8
            const result = sig_validator.validateResolvedContent(content);
            try std.testing.expect(result.has_invalid_utf8);
        }
    };
    harness.property(
        "invalid UTF-8 content fails validation",
        S.run,
    );
}


// ---------------------------------------------------------------------------
// Feature: sig-memory-model, Property 32: Prompt contains all Sig conventions
//
// For any file path and conflicted content, the built prompt shall contain:
//   - [sig] marker preservation instructions
//   - "accept all upstream changes" instruction
//   - File extension context (.zig or .sig)
//   - The actual conflicted content
//   - The file path
//
// **Validates: Requirements 20.1, 20.2, 20.3, 20.4, 20.5, 20.6**
// ---------------------------------------------------------------------------

const sig_prompt = @import("sig_prompt");

/// Pool of file paths with mixed extensions for prompt testing.
const prompt_path_pool = [_][]const u8{
    "lib/sig/fmt.zig",
    "tools/sig_sync/main.sig",
    "src/Compilation.zig",
    "lib/sig/containers.zig",
    "tools/sig_conflict_resolver/validator.sig",
    "build.zig",
    "test/sig_pbt/harness.sig",
};

/// Pool of sample conflicted content fragments.
const conflict_pool = [_][]const u8{
    "<<<<<<< HEAD\npub fn parse() void {}\n=======\npub fn parse(a: Allocator) void {}\n>>>>>>> upstream\n",
    "<<<<<<< HEAD\n// [sig] bounded read\nreadInto(buf);\n=======\nread(allocator);\n>>>>>>> upstream\n",
    "no conflict here, just normal code\n",
    "<<<<<<< HEAD\nconst x = 1;\n=======\nconst x = 2;\n>>>>>>> upstream\n",
};

fn containsSubstring(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (haystack[i + j] != needle[j]) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

test "Property 32: prompt contains [sig] marker preservation instructions" {
    // Feature: sig-memory-model, Property 32: Prompt contains all Sig conventions
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const file_path = prompt_path_pool[random.uintAtMost(usize, prompt_path_pool.len - 1)];
            const content = conflict_pool[random.uintAtMost(usize, conflict_pool.len - 1)];

            var commit_a: [40]u8 = undefined;
            genCommitHash(random, &commit_a);
            var commit_b: [40]u8 = undefined;
            genCommitHash(random, &commit_b);

            var buf: [32 * 1024]u8 = undefined;
            const prompt = sig_prompt.buildPrompt(&buf, file_path, content, &commit_a, &commit_b) catch |err| {
                std.debug.print("buildPrompt failed: {}\n", .{err});
                return err;
            };

            // Must contain [sig] marker preservation instructions
            try std.testing.expect(containsSubstring(prompt, "[sig]"));
            try std.testing.expect(containsSubstring(prompt, "marker"));
        }
    };
    harness.property(
        "prompt contains [sig] marker preservation instructions",
        S.run,
    );
}

test "Property 32: prompt contains accept all upstream changes instruction" {
    // Feature: sig-memory-model, Property 32: Prompt contains all Sig conventions
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const file_path = prompt_path_pool[random.uintAtMost(usize, prompt_path_pool.len - 1)];
            const content = conflict_pool[random.uintAtMost(usize, conflict_pool.len - 1)];

            var commit_a: [40]u8 = undefined;
            genCommitHash(random, &commit_a);
            var commit_b: [40]u8 = undefined;
            genCommitHash(random, &commit_b);

            var buf: [32 * 1024]u8 = undefined;
            const prompt = try sig_prompt.buildPrompt(&buf, file_path, content, &commit_a, &commit_b);

            // Must instruct to accept all upstream changes
            try std.testing.expect(containsSubstring(prompt, "upstream"));
            try std.testing.expect(containsSubstring(prompt, "Accept"));
        }
    };
    harness.property(
        "prompt contains accept all upstream changes instruction",
        S.run,
    );
}

test "Property 32: prompt contains file extension context" {
    // Feature: sig-memory-model, Property 32: Prompt contains all Sig conventions
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const file_path = prompt_path_pool[random.uintAtMost(usize, prompt_path_pool.len - 1)];
            const content = conflict_pool[random.uintAtMost(usize, conflict_pool.len - 1)];

            var commit_a: [40]u8 = undefined;
            genCommitHash(random, &commit_a);
            var commit_b: [40]u8 = undefined;
            genCommitHash(random, &commit_b);

            var buf: [32 * 1024]u8 = undefined;
            const prompt = try sig_prompt.buildPrompt(&buf, file_path, content, &commit_a, &commit_b);

            // Must contain file extension context (.zig or .sig)
            const has_zig_ctx = containsSubstring(prompt, ".zig");
            const has_sig_ctx = containsSubstring(prompt, ".sig");
            try std.testing.expect(has_zig_ctx or has_sig_ctx);
        }
    };
    harness.property(
        "prompt contains file extension context",
        S.run,
    );
}

test "Property 32: prompt contains the actual conflicted content" {
    // Feature: sig-memory-model, Property 32: Prompt contains all Sig conventions
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const file_path = prompt_path_pool[random.uintAtMost(usize, prompt_path_pool.len - 1)];
            const content = conflict_pool[random.uintAtMost(usize, conflict_pool.len - 1)];

            var commit_a: [40]u8 = undefined;
            genCommitHash(random, &commit_a);
            var commit_b: [40]u8 = undefined;
            genCommitHash(random, &commit_b);

            var buf: [32 * 1024]u8 = undefined;
            const prompt = try sig_prompt.buildPrompt(&buf, file_path, content, &commit_a, &commit_b);

            // Must contain the actual conflicted content verbatim
            try std.testing.expect(containsSubstring(prompt, content));
        }
    };
    harness.property(
        "prompt contains the actual conflicted content",
        S.run,
    );
}

test "Property 32: prompt contains the file path" {
    // Feature: sig-memory-model, Property 32: Prompt contains all Sig conventions
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const file_path = prompt_path_pool[random.uintAtMost(usize, prompt_path_pool.len - 1)];
            const content = conflict_pool[random.uintAtMost(usize, conflict_pool.len - 1)];

            var commit_a: [40]u8 = undefined;
            genCommitHash(random, &commit_a);
            var commit_b: [40]u8 = undefined;
            genCommitHash(random, &commit_b);

            var buf: [32 * 1024]u8 = undefined;
            const prompt = try sig_prompt.buildPrompt(&buf, file_path, content, &commit_a, &commit_b);

            // Must contain the file path
            try std.testing.expect(containsSubstring(prompt, file_path));
        }
    };
    harness.property(
        "prompt contains the file path",
        S.run,
    );
}
