// Unit tests for manifest AI resolution fields (Phase 3)
// Requirements: 22.3, 22.4, 22.5

const std = @import("std");
const testing = std.testing;
const sig_sync = @import("sig_sync");

const SyncEntry = sig_sync.SyncEntry;
const SyncManifest = sig_sync.SyncManifest;
const AiResolutionDetails = sig_sync.AiResolutionDetails;

// ── Test 1: Parse ai_resolved entry with ai_resolution_details ──────────

test "parse manifest with ai_resolved status and ai_resolution_details" {
    const json =
        \\{
        \\  "last_integrated_commit": "aabb000000000000000000000000000000000000",
        \\  "last_integration_timestamp": 1700010000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "ccdd000000000000000000000000000000000000",
        \\      "timestamp": 1700010000,
        \\      "status": "ai_resolved",
        \\      "conflicting_files": ["lib/sig/fmt.zig", "src/main.zig"],
        \\      "ai_resolution_details": {
        \\        "confidence": 87,
        \\        "explanation": "Upstream renamed function, sig block relocated alongside new name",
        \\        "resolved_file_count": 2
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    const manifest = sig_sync.parseManifest(json);

    try testing.expectEqual(@as(usize, 1), manifest.entry_count);

    const entry = &manifest.entries[0];
    try testing.expectEqual(SyncEntry.Status.ai_resolved, entry.status);
    try testing.expectEqualStrings("ccdd000000000000000000000000000000000000", entry.commit());
    try testing.expectEqual(@as(i64, 1700010000), entry.timestamp);

    // AI resolution details
    try testing.expect(entry.has_ai_details);
    try testing.expectEqual(@as(u8, 87), entry.ai_details.confidence);
    try testing.expectEqual(@as(u8, 2), entry.ai_details.resolved_file_count);
    try testing.expectEqualStrings(
        "Upstream renamed function, sig block relocated alongside new name",
        entry.ai_details.explanation(),
    );

    // Conflict files still parsed
    try testing.expectEqual(@as(usize, 2), entry.conflict_count);
    try testing.expectEqualStrings("lib/sig/fmt.zig", entry.conflictFile(0));
    try testing.expectEqualStrings("src/main.zig", entry.conflictFile(1));
}

// ── Test 2: Parse legacy manifest (no ai_resolution_details) ────────────

test "parse legacy manifest without ai_resolution_details has defaults" {
    const json =
        \\{
        \\  "last_integrated_commit": "1111000000000000000000000000000000000000",
        \\  "last_integration_timestamp": 1700020000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "2222000000000000000000000000000000000000",
        \\      "timestamp": 1700020000,
        \\      "status": "integrated",
        \\      "conflicting_files": null
        \\    },
        \\    {
        \\      "upstream_commit": "3333000000000000000000000000000000000000",
        \\      "timestamp": 1700021000,
        \\      "status": "conflict",
        \\      "conflicting_files": ["build.zig"]
        \\    },
        \\    {
        \\      "upstream_commit": "4444000000000000000000000000000000000000",
        \\      "timestamp": 1700022000,
        \\      "status": "skipped",
        \\      "conflicting_files": null
        \\    }
        \\  ]
        \\}
    ;
    const manifest = sig_sync.parseManifest(json);

    try testing.expectEqual(@as(usize, 3), manifest.entry_count);

    // All entries should have has_ai_details == false and default AI details
    for (manifest.entries[0..manifest.entry_count]) |*entry| {
        try testing.expect(!entry.has_ai_details);
        try testing.expectEqual(@as(u8, 0), entry.ai_details.confidence);
        try testing.expectEqual(@as(u8, 0), entry.ai_details.resolved_file_count);
        try testing.expectEqual(@as(usize, 0), entry.ai_details.explanation_len);
    }

    // Statuses preserved correctly
    try testing.expectEqual(SyncEntry.Status.integrated, manifest.entries[0].status);
    try testing.expectEqual(SyncEntry.Status.conflict, manifest.entries[1].status);
    try testing.expectEqual(SyncEntry.Status.skipped, manifest.entries[2].status);
}

// ── Test 3: Serialize ai_resolved entry emits ai_resolution_details ─────

test "serialize manifest with has_ai_details true emits ai_resolution_details" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("eeee000000000000000000000000000000000000");
    manifest.last_integration_timestamp = 1700030000;

    var entry = SyncEntry{};
    entry.setCommit("ffff000000000000000000000000000000000000");
    entry.timestamp = 1700030000;
    entry.status = .ai_resolved;
    entry.has_ai_details = true;
    entry.ai_details.confidence = 95;
    entry.ai_details.resolved_file_count = 3;
    entry.ai_details.setExplanation("Merged import lists and kept sig additions");
    entry.addConflictFile("lib/sig/io.zig");
    manifest.addEntry(entry);

    var buf: [8192]u8 = undefined;
    const serialized = try sig_sync.serializeManifest(&manifest, &buf);

    // Verify ai_resolution_details fields are present
    try testing.expect(std.mem.indexOf(u8, serialized, "\"ai_resolution_details\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"confidence\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"explanation\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"resolved_file_count\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"ai_resolved\"") != null);

    // Verify the actual values appear in the output
    try testing.expect(std.mem.indexOf(u8, serialized, "Merged import lists and kept sig additions") != null);

    // Round-trip: parse it back and verify
    const parsed = sig_sync.parseManifest(serialized);
    try testing.expectEqual(@as(usize, 1), parsed.entry_count);
    try testing.expect(parsed.entries[0].has_ai_details);
    try testing.expectEqual(@as(u8, 95), parsed.entries[0].ai_details.confidence);
    try testing.expectEqual(@as(u8, 3), parsed.entries[0].ai_details.resolved_file_count);
    try testing.expectEqualStrings(
        "Merged import lists and kept sig additions",
        parsed.entries[0].ai_details.explanation(),
    );
}

// ── Test 4: Serialize integrated entry omits ai_resolution_details ──────

test "serialize manifest with has_ai_details false omits ai_resolution_details" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("abab000000000000000000000000000000000000");
    manifest.last_integration_timestamp = 1700040000;

    var entry = SyncEntry{};
    entry.setCommit("cdcd000000000000000000000000000000000000");
    entry.timestamp = 1700040000;
    entry.status = .integrated;
    // has_ai_details defaults to false
    manifest.addEntry(entry);

    var buf: [8192]u8 = undefined;
    const serialized = try sig_sync.serializeManifest(&manifest, &buf);

    // Verify ai_resolution_details is NOT present
    try testing.expect(std.mem.indexOf(u8, serialized, "\"ai_resolution_details\"") == null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"confidence\"") == null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"explanation\"") == null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"resolved_file_count\"") == null);

    // Status should be "integrated", not "ai_resolved"
    try testing.expect(std.mem.indexOf(u8, serialized, "\"integrated\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"ai_resolved\"") == null);
}

// ── Validator Unit Tests ─────────────────────────────────────────────────
// Requirements: 24.2, 24.3

const sig_validator = @import("sig_validator");

// ── Test 5: Empty content passes all validation ─────────────────────────

test "empty content passes all validation" {
    const content: []const u8 = "";

    try testing.expect(sig_validator.validateResolution(content));
    try testing.expect(sig_validator.isValidUtf8(content));

    const result = sig_validator.validateResolvedContent(content);
    try testing.expect(result.valid);
    try testing.expect(!result.has_conflict_markers);
    try testing.expect(!result.has_invalid_utf8);
}

// ── Test 6: Clean ASCII content passes all validation ───────────────────

test "clean ASCII content passes all validation" {
    const content = "fn main() void {\n    return;\n}\n";

    try testing.expect(sig_validator.validateResolution(content));
    try testing.expect(sig_validator.isValidUtf8(content));

    const result = sig_validator.validateResolvedContent(content);
    try testing.expect(result.valid);
    try testing.expect(!result.has_conflict_markers);
    try testing.expect(!result.has_invalid_utf8);
}

// ── Test 7: Content with <<<<<<< fails validateResolution ───────────────

test "content with <<<<<<< conflict marker fails validateResolution" {
    const content = "line 1\n<<<<<<< HEAD\nline 2\n";

    try testing.expect(!sig_validator.validateResolution(content));

    const result = sig_validator.validateResolvedContent(content);
    try testing.expect(!result.valid);
    try testing.expect(result.has_conflict_markers);
}

// ── Test 8: Content with ======= fails validateResolution ───────────────

test "content with ======= conflict marker fails validateResolution" {
    const content = "line 1\n=======\nline 2\n";

    try testing.expect(!sig_validator.validateResolution(content));

    const result = sig_validator.validateResolvedContent(content);
    try testing.expect(!result.valid);
    try testing.expect(result.has_conflict_markers);
}

// ── Test 9: Content with >>>>>>> fails validateResolution ───────────────

test "content with >>>>>>> conflict marker fails validateResolution" {
    const content = "line 1\n>>>>>>> upstream/main\nline 2\n";

    try testing.expect(!sig_validator.validateResolution(content));

    const result = sig_validator.validateResolvedContent(content);
    try testing.expect(!result.valid);
    try testing.expect(result.has_conflict_markers);
}

// ── Test 10: Marker embedded in text fails ───────────────────────────────

test "conflict marker embedded in text fails validateResolution" {
    const content = "some text before <<<<<<<and after";

    try testing.expect(!sig_validator.validateResolution(content));

    const result = sig_validator.validateResolvedContent(content);
    try testing.expect(!result.valid);
    try testing.expect(result.has_conflict_markers);
}

// ── Test 11: Invalid UTF-8 byte 0xFF fails isValidUtf8 ──────────────────

test "invalid UTF-8 byte 0xFF fails isValidUtf8" {
    const content = [_]u8{ 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0xFF };

    try testing.expect(!sig_validator.isValidUtf8(&content));

    const result = sig_validator.validateResolvedContent(&content);
    try testing.expect(!result.valid);
    try testing.expect(result.has_invalid_utf8);
}

// ── Test 12: Truncated 2-byte UTF-8 sequence fails isValidUtf8 ──────────

test "truncated 2-byte UTF-8 sequence fails isValidUtf8" {
    // 0xC3 starts a 2-byte sequence but there's no continuation byte
    const content = [_]u8{ 0x41, 0xC3 };

    try testing.expect(!sig_validator.isValidUtf8(&content));

    const result = sig_validator.validateResolvedContent(&content);
    try testing.expect(!result.valid);
    try testing.expect(result.has_invalid_utf8);
}

// ── Test 13: validateResolvedContent combines both checks correctly ──────

test "validateResolvedContent combines marker and UTF-8 checks" {
    // Clean content: both checks pass
    {
        const clean = "const x = 42;\n";
        const result = sig_validator.validateResolvedContent(clean);
        try testing.expect(result.valid);
        try testing.expect(!result.has_conflict_markers);
        try testing.expect(!result.has_invalid_utf8);
    }

    // Only markers: marker check fails, UTF-8 passes
    {
        const markers_only = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> main\n";
        const result = sig_validator.validateResolvedContent(markers_only);
        try testing.expect(!result.valid);
        try testing.expect(result.has_conflict_markers);
        try testing.expect(!result.has_invalid_utf8);
    }

    // Only bad UTF-8: marker check passes, UTF-8 fails
    {
        const bad_utf8 = [_]u8{ 0x48, 0x69, 0xFE };
        const result = sig_validator.validateResolvedContent(&bad_utf8);
        try testing.expect(!result.valid);
        try testing.expect(!result.has_conflict_markers);
        try testing.expect(result.has_invalid_utf8);
    }

    // Both bad: markers AND invalid UTF-8
    {
        const both_bad = [_]u8{ '<', '<', '<', '<', '<', '<', '<', 0xFF };
        const result = sig_validator.validateResolvedContent(&both_bad);
        try testing.expect(!result.valid);
        try testing.expect(result.has_conflict_markers);
        try testing.expect(result.has_invalid_utf8);
    }
}


// ── Prompt Construction Unit Tests ──────────────────────────────────────
// Requirements: 20.1, 20.2, 20.3, 20.4, 20.5, 20.6

const sig_prompt = @import("sig_prompt");

fn containsStr(haystack: []const u8, needle: []const u8) bool {
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

// ── Test 14: .zig file includes zig-specific context ────────────────────

test "prompt for .zig file includes zig-specific context" {
    var buf: [32 * 1024]u8 = undefined;
    const prompt = try sig_prompt.buildPrompt(
        &buf,
        "lib/sig/fmt.zig",
        "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> upstream\n",
        "aaaa000000000000000000000000000000000000",
        "bbbb000000000000000000000000000000000000",
    );

    // Should mention .zig and diagnostics per mode
    try testing.expect(containsStr(prompt, ".zig"));
    try testing.expect(containsStr(prompt, "diagnostics"));
}

// ── Test 15: .sig file includes sig-specific strictness rules ───────────

test "prompt for .sig file includes sig-specific strictness rules" {
    var buf: [32 * 1024]u8 = undefined;
    const prompt = try sig_prompt.buildPrompt(
        &buf,
        "tools/sig_sync/main.sig",
        "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> upstream\n",
        "aaaa000000000000000000000000000000000000",
        "bbbb000000000000000000000000000000000000",
    );

    // Should mention .sig and compile error
    try testing.expect(containsStr(prompt, ".sig"));
    try testing.expect(containsStr(prompt, "compile error"));
}

// ── Test 16: prompt includes conflicted content verbatim ────────────────

test "prompt includes conflicted content verbatim" {
    const conflicted = "<<<<<<< HEAD\nfn foo() void {}\n=======\nfn foo(a: u32) void {}\n>>>>>>> upstream\n";
    var buf: [32 * 1024]u8 = undefined;
    const prompt = try sig_prompt.buildPrompt(
        &buf,
        "src/main.zig",
        conflicted,
        "cccc000000000000000000000000000000000000",
        "dddd000000000000000000000000000000000000",
    );

    try testing.expect(containsStr(prompt, conflicted));
}

// ── Test 17: prompt fits within buffer for typical conflict sizes ────────

test "prompt fits within 32KB buffer for typical conflict" {
    // A typical conflict is a few hundred bytes. 32KB should be plenty.
    const conflicted = "<<<<<<< HEAD\nconst x = 1;\n// [sig] bounded\nconst y = sigParse(buf);\n=======\nconst x = 2;\n>>>>>>> upstream\n";
    var buf: [32 * 1024]u8 = undefined;
    const prompt = try sig_prompt.buildPrompt(
        &buf,
        "lib/sig/parse.zig",
        conflicted,
        "eeee000000000000000000000000000000000000",
        "ffff000000000000000000000000000000000000",
    );

    // Should succeed and produce non-empty output
    try testing.expect(prompt.len > 0);
}

// ── Test 18: prompt returns BufferTooSmall on tiny buffer ────────────────

test "prompt returns BufferTooSmall on tiny buffer" {
    var buf: [16]u8 = undefined;
    const result = sig_prompt.buildPrompt(
        &buf,
        "lib/sig/fmt.zig",
        "some conflict content",
        "aaaa000000000000000000000000000000000000",
        "bbbb000000000000000000000000000000000000",
    );

    try testing.expectError(error.BufferTooSmall, result);
}

// ── Test 19: prompt contains commit hashes ──────────────────────────────

test "prompt contains both commit hashes" {
    const upstream = "1234abcd1234abcd1234abcd1234abcd1234abcd";
    const sig_commit = "5678ef005678ef005678ef005678ef005678ef00";
    var buf: [32 * 1024]u8 = undefined;
    const prompt = try sig_prompt.buildPrompt(
        &buf,
        "lib/sig/io.zig",
        "conflict",
        upstream,
        sig_commit,
    );

    try testing.expect(containsStr(prompt, upstream));
    try testing.expect(containsStr(prompt, sig_commit));
}

// ── Test 20: SYSTEM_PROMPT contains all required Sig conventions ────────

test "SYSTEM_PROMPT contains all required Sig conventions" {
    const sp = sig_prompt.SYSTEM_PROMPT;

    // Requirement 20.1: Sig adds code alongside upstream, never modifies
    try testing.expect(containsStr(sp, "never modifies upstream"));

    // Requirement 20.2: [sig] markers must be preserved
    try testing.expect(containsStr(sp, "[sig]"));
    try testing.expect(containsStr(sp, "preserved"));

    // Requirement 20.3: Sig code blocks stay adjacent
    try testing.expect(containsStr(sp, "adjacent"));

    // Requirement 20.4: Accept all upstream changes
    try testing.expect(containsStr(sp, "Accept ALL upstream changes"));

    // Requirement 20.5: Upstream-only conflicts accept upstream
    try testing.expect(containsStr(sp, "ONLY upstream code"));

    // Requirement 20.6: File extension context
    try testing.expect(containsStr(sp, ".zig"));
    try testing.expect(containsStr(sp, ".sig"));
}
