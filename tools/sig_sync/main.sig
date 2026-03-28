const std = @import("std");
const sig = @import("sig");
const sig_fmt = sig.fmt;
const sig_json = sig.json;
const sig_fs = sig.fs;

/// Sig_Sync — Upstream Zig Synchronization Tool (zero allocators)
///
/// All memory is stack-allocated or caller-provided. No Allocator anywhere.
/// Uses sig.json for manifest parsing/serialization, sig.fmt for string
/// formatting, sig.fs for file I/O.

// ── Capacity Constants ───────────────────────────────────────────────────

const MAX_ENTRIES = 64;
const MAX_COMMITS = 256;
const MAX_CONFLICT_FILES = 8;
const GIT_BUF_SIZE = 256 * 1024; // 256 KB for git stdout
const MANIFEST_BUF_SIZE = 512 * 1024; // 512 KB for manifest JSON

// ── Data Models (all inline, no pointers to heap) ────────────────────────

pub const AiResolutionDetails = struct {
    confidence: u8 = 0, // 0–100 integer
    explanation_buf: [512]u8 = undefined,
    explanation_len: usize = 0,
    resolved_file_count: u8 = 0,

    pub fn explanation(self: *const AiResolutionDetails) []const u8 {
        return self.explanation_buf[0..self.explanation_len];
    }

    pub fn setExplanation(self: *AiResolutionDetails, text: []const u8) void {
        const len = @min(text.len, 512);
        @memcpy(self.explanation_buf[0..len], text[0..len]);
        self.explanation_len = len;
    }
};

pub const SyncEntry = struct {
    upstream_commit: [40]u8 = [_]u8{0} ** 40,
    commit_len: usize = 0,
    timestamp: i64 = 0,
    status: Status = .integrated,
    conflict_bufs: [MAX_CONFLICT_FILES][256]u8 = undefined,
    conflict_lens: [MAX_CONFLICT_FILES]usize = [_]usize{0} ** MAX_CONFLICT_FILES,
    conflict_count: usize = 0,
    has_ai_details: bool = false,
    ai_details: AiResolutionDetails = AiResolutionDetails{},

    pub const Status = enum { integrated, conflict, skipped, ai_resolved };

    pub fn commit(self: *const SyncEntry) []const u8 {
        return self.upstream_commit[0..self.commit_len];
    }

    pub fn setCommit(self: *SyncEntry, hash: []const u8) void {
        const len = @min(hash.len, 40);
        @memcpy(self.upstream_commit[0..len], hash[0..len]);
        self.commit_len = len;
    }

    pub fn addConflictFile(self: *SyncEntry, path: []const u8) void {
        if (self.conflict_count >= MAX_CONFLICT_FILES) return;
        const len = @min(path.len, 256);
        @memcpy(self.conflict_bufs[self.conflict_count][0..len], path[0..len]);
        self.conflict_lens[self.conflict_count] = len;
        self.conflict_count += 1;
    }

    pub fn conflictFile(self: *const SyncEntry, i: usize) []const u8 {
        return self.conflict_bufs[i][0..self.conflict_lens[i]];
    }
};

pub const SyncManifest = struct {
    last_integrated_commit: [40]u8 = [_]u8{0} ** 40,
    last_commit_len: usize = 0,
    last_integration_timestamp: i64 = 0,
    entries: [MAX_ENTRIES]SyncEntry = undefined,
    entry_count: usize = 0,

    pub fn lastCommit(self: *const SyncManifest) []const u8 {
        return self.last_integrated_commit[0..self.last_commit_len];
    }

    pub fn setLastCommit(self: *SyncManifest, hash: []const u8) void {
        const len = @min(hash.len, 40);
        @memcpy(self.last_integrated_commit[0..len], hash[0..len]);
        self.last_commit_len = len;
    }

    pub fn addEntry(self: *SyncManifest, entry: SyncEntry) void {
        if (self.entry_count >= MAX_ENTRIES) return;
        self.entries[self.entry_count] = entry;
        self.entry_count += 1;
    }
};

// ── Manifest Parsing (using sig.json, zero allocators) ───────────────────

pub fn parseManifest(json_bytes: []const u8) SyncManifest {
    var manifest = SyncManifest{};
    if (json_bytes.len == 0) return manifest;

    // Extract top-level fields.
    var commit_buf: [40]u8 = undefined;
    const commit = sig_json.extractString(json_bytes, "last_integrated_commit", &commit_buf) catch "";
    if (commit.len > 0) manifest.setLastCommit(commit);

    manifest.last_integration_timestamp = sig_json.extractInt(json_bytes, "last_integration_timestamp") catch 0;

    // Parse entries array — find "entries" : [ ... ]
    // Walk through each { ... } block in the array.
    const entries_start = std.mem.indexOf(u8, json_bytes, "\"entries\"") orelse return manifest;
    const arr_start = std.mem.indexOfPos(u8, json_bytes, entries_start, "[") orelse return manifest;
    var pos = arr_start + 1;

    while (pos < json_bytes.len and manifest.entry_count < MAX_ENTRIES) {
        // Find next '{'.
        const obj_start = std.mem.indexOfPos(u8, json_bytes, pos, "{") orelse break;
        // Find matching '}'.
        const obj_end = std.mem.indexOfPos(u8, json_bytes, obj_start, "}") orelse break;
        const obj = json_bytes[obj_start .. obj_end + 1];

        var entry = SyncEntry{};

        var ec_buf: [40]u8 = undefined;
        const ec = sig_json.extractString(obj, "upstream_commit", &ec_buf) catch "";
        if (ec.len > 0) entry.setCommit(ec);

        entry.timestamp = sig_json.extractInt(obj, "timestamp") catch 0;

        var status_buf: [16]u8 = undefined;
        const status_str = sig_json.extractString(obj, "status", &status_buf) catch "integrated";
        if (std.mem.eql(u8, status_str, "conflict")) {
            entry.status = .conflict;
        } else if (std.mem.eql(u8, status_str, "skipped")) {
            entry.status = .skipped;
        } else if (std.mem.eql(u8, status_str, "ai_resolved")) {
            entry.status = .ai_resolved;
        } else {
            entry.status = .integrated;
        }

        // Parse conflicting_files array if present.
        const cf_key_pos = std.mem.indexOf(u8, obj, "\"conflicting_files\"");
        if (cf_key_pos) |cfp| {
            const cf_rest = obj[cfp..];
            const cf_arr = std.mem.indexOf(u8, cf_rest, "[");
            if (cf_arr) |ca| {
                const cf_end = std.mem.indexOfPos(u8, cf_rest, ca, "]") orelse obj.len;
                const arr_slice = cf_rest[ca .. cf_end + 1];
                // Extract strings from the array.
                var fi: usize = 0;
                var si: usize = 0;
                while (si < arr_slice.len and entry.conflict_count < MAX_CONFLICT_FILES) {
                    if (arr_slice[si] == '"') {
                        si += 1;
                        fi = si;
                        while (si < arr_slice.len and arr_slice[si] != '"') : (si += 1) {}
                        const file_name = arr_slice[fi..si];
                        entry.addConflictFile(file_name);
                        si += 1;
                    } else {
                        si += 1;
                    }
                }
            }
        }

        manifest.addEntry(entry);
        pos = obj_end + 1;
    }

    return manifest;
}

// ── Manifest Serialization (using sig.json.Writer, zero allocators) ──────

pub fn serializeManifest(manifest: *const SyncManifest, buf: []u8) SigError![]const u8 {
    var w = sig_json.Writer.init(buf);

    try w.beginObject();

    try w.objectField("last_integrated_commit");
    try w.writeString(manifest.lastCommit());

    try w.objectField("last_integration_timestamp");
    try w.writeInt(manifest.last_integration_timestamp);

    try w.objectField("entries");
    try w.beginArray();

    var i: usize = 0;
    while (i < manifest.entry_count) : (i += 1) {
        const entry = &manifest.entries[i];
        try w.beginObject();

        try w.objectField("upstream_commit");
        try w.writeString(entry.commit());

        try w.objectField("timestamp");
        try w.writeInt(entry.timestamp);

        try w.objectField("status");
        try w.writeString(switch (entry.status) {
            .integrated => "integrated",
            .conflict => "conflict",
            .skipped => "skipped",
            .ai_resolved => "ai_resolved",
        });

        try w.objectField("conflicting_files");
        if (entry.conflict_count > 0) {
            try w.beginArray();
            var j: usize = 0;
            while (j < entry.conflict_count) : (j += 1) {
                try w.writeString(entry.conflictFile(j));
            }
            try w.endArray();
        } else {
            try w.writeNull();
        }

        try w.endObject();
    }

    try w.endArray();
    try w.endObject();

    // Add trailing newline.
    if (w.pos < buf.len) {
        buf[w.pos] = '\n';
        w.pos += 1;
    }

    return w.written();
}

const SigError = sig.SigError;

// ── Git Helpers (fixed buffers, no allocator) ────────────────────────────

const GitResult = struct {
    exit_code: u8 = 0,
    stdout_buf: [GIT_BUF_SIZE]u8 = undefined,
    stdout_len: usize = 0,

    pub fn stdout(self: *const GitResult) []const u8 {
        return self.stdout_buf[0..self.stdout_len];
    }
};

/// Run a git command, capture stdout into a fixed buffer.
fn runGit(io: std.Io, argv: []const []const u8) !GitResult {
    var result = GitResult{};

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.SpawnFailed;
    defer child.kill(io);

    // Read stdout into fixed buffer using sig-style read loop.
    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);
    while (result.stdout_len < GIT_BUF_SIZE) {
        const n = reader.interface.readSliceShort(result.stdout_buf[result.stdout_len..]) catch break;
        if (n == 0) break;
        result.stdout_len += n;
    }

    const term = child.wait(io) catch return error.SpawnFailed;
    result.exit_code = switch (term) {
        .exited => |code| code,
        else => 1,
    };

    return result;
}

pub fn fetchUpstream(io: std.Io, remote: []const u8) !void {
    const result = try runGit(io, &.{ "git", "fetch", remote });
    if (result.exit_code != 0) return error.FetchFailed;
}

/// Get new commit hashes since `since_commit`. Returns count.
/// Hashes are written into `out_hashes` (each is 40 bytes).
pub fn getNewCommits(
    io: std.Io,
    remote: []const u8,
    branch: []const u8,
    since_commit: []const u8,
    out_hashes: [][40]u8,
) !usize {
    // Build range string into a stack buffer.
    var range_buf: [256]u8 = undefined;
    const range = if (since_commit.len > 0)
        sig_fmt.formatInto(&range_buf, "{s}..{s}/{s}", .{ since_commit, remote, branch }) catch return error.BufferTooSmall
    else
        sig_fmt.formatInto(&range_buf, "{s}/{s}", .{ remote, branch }) catch return error.BufferTooSmall;

    const result = try runGit(io, &.{ "git", "log", "--reverse", "--format=%H", range });
    if (result.exit_code != 0) return error.LogFailed;

    const trimmed = std.mem.trim(u8, result.stdout(), " \n\r");
    if (trimmed.len == 0) return 0;

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        const hash = std.mem.trim(u8, line, " \r");
        if (hash.len == 40 and count < out_hashes.len) {
            @memcpy(&out_hashes[count], hash[0..40]);
            count += 1;
        }
    }
    return count;
}

pub fn getCommitTimestamp(io: std.Io, commit_hash: []const u8) !i64 {
    const result = try runGit(io, &.{ "git", "show", "-s", "--format=%ct", commit_hash });
    if (result.exit_code != 0) return 0;
    const trimmed = std.mem.trim(u8, result.stdout(), " \n\r");
    return std.fmt.parseInt(i64, trimmed, 10) catch 0;
}

pub fn cherryPickCommit(io: std.Io, commit_hash: []const u8) !SyncEntry {
    const timestamp = getCommitTimestamp(io, commit_hash) catch 0;

    const result = try runGit(io, &.{ "git", "cherry-pick", "--no-commit", commit_hash });

    if (result.exit_code == 0) {
        // Build commit message into stack buffer.
        var msg_buf: [128]u8 = undefined;
        const msg = sig_fmt.formatInto(&msg_buf, "sig-sync: integrate upstream {s}", .{commit_hash}) catch "sig-sync: integrate upstream";

        const commit_result = try runGit(io, &.{ "git", "commit", "--no-edit", "-m", msg });

        if (commit_result.exit_code != 0) {
            _ = runGit(io, &.{ "git", "reset", "HEAD" }) catch {};
            var entry = SyncEntry{};
            entry.setCommit(commit_hash);
            entry.timestamp = timestamp;
            entry.status = .skipped;
            return entry;
        }

        var entry = SyncEntry{};
        entry.setCommit(commit_hash);
        entry.timestamp = timestamp;
        entry.status = .integrated;
        return entry;
    }

    // Conflict — gather conflicting files.
    var entry = SyncEntry{};
    entry.setCommit(commit_hash);
    entry.timestamp = timestamp;
    entry.status = .conflict;

    const diff_result = runGit(io, &.{ "git", "diff", "--name-only", "--diff-filter=U" }) catch {
        _ = runGit(io, &.{ "git", "cherry-pick", "--abort" }) catch {};
        return entry;
    };

    if (diff_result.exit_code == 0) {
        const trimmed = std.mem.trim(u8, diff_result.stdout(), " \n\r");
        if (trimmed.len > 0) {
            var lines = std.mem.splitScalar(u8, trimmed, '\n');
            while (lines.next()) |line| {
                const file = std.mem.trim(u8, line, " \r");
                if (file.len > 0) entry.addConflictFile(file);
            }
        }
    }

    _ = runGit(io, &.{ "git", "cherry-pick", "--abort" }) catch {};
    return entry;
}

// ── Sync Logic ───────────────────────────────────────────────────────────

pub const SyncOptions = struct {
    remote: []const u8 = "origin",
    branch: []const u8 = "master",
    manifest_path: []const u8 = "tools/sig_sync/manifest.json",
    dry_run: bool = false,
};

pub fn runSync(io: std.Io, options: SyncOptions) !SyncManifest {
    // 1. Load existing manifest into a stack buffer.
    var manifest_file_buf: [MANIFEST_BUF_SIZE]u8 = undefined;
    const manifest_json = sig_fs.readFile(io, options.manifest_path, &manifest_file_buf) catch "";
    var manifest = parseManifest(manifest_json);

    // 2. Fetch upstream.
    if (!options.dry_run) {
        fetchUpstream(io, options.remote) catch {
            logError(io, "Failed to fetch upstream");
            return manifest;
        };
    }

    // 3. Get new commits.
    var commit_hashes: [MAX_COMMITS][40]u8 = undefined;
    const commit_count = getNewCommits(io, options.remote, options.branch, manifest.lastCommit(), &commit_hashes) catch {
        logError(io, "Failed to get new commits");
        return manifest;
    };

    if (commit_count == 0) {
        logInfo(io, "No new upstream commits to integrate.");
        return manifest;
    }

    var fmt_buf: [128]u8 = undefined;
    logFmt(io, &fmt_buf, "Found {d} new upstream commit(s).", .{commit_count});

    // 4. Process each commit.
    var halt = false;
    var i: usize = 0;
    while (i < commit_count) : (i += 1) {
        if (halt) break;
        const hash: []const u8 = &commit_hashes[i];

        if (options.dry_run) {
            const ts = getCommitTimestamp(io, hash) catch 0;
            var entry = SyncEntry{};
            entry.setCommit(hash);
            entry.timestamp = ts;
            entry.status = .skipped;
            manifest.addEntry(entry);
            continue;
        }

        const entry = cherryPickCommit(io, hash) catch {
            var skip_entry = SyncEntry{};
            skip_entry.setCommit(hash);
            skip_entry.status = .skipped;
            manifest.addEntry(skip_entry);
            continue;
        };

        manifest.addEntry(entry);

        switch (entry.status) {
            .integrated => {
                manifest.setLastCommit(entry.commit());
                manifest.last_integration_timestamp = entry.timestamp;
            },
            .ai_resolved => {
                manifest.setLastCommit(entry.commit());
                manifest.last_integration_timestamp = entry.timestamp;
            },
            .conflict => {
                halt = true;
            },
            .skipped => {},
        }
    }

    // 5. Write manifest.
    var serialize_buf: [MANIFEST_BUF_SIZE]u8 = undefined;
    const serialized = serializeManifest(&manifest, &serialize_buf) catch {
        logError(io, "Failed to serialize manifest");
        return manifest;
    };
    sig_fs.writeFile(io, options.manifest_path, serialized) catch {
        logError(io, "Failed to write manifest");
    };

    return manifest;
}

// ── Logging (stack buffers only) ─────────────────────────────────────────

fn logInfo(io: std.Io, msg: []const u8) void {
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &.{});
    const w = &stderr_writer.interface;
    w.writeAll("[sig-sync] ") catch {};
    w.writeAll(msg) catch {};
    w.writeAll("\n") catch {};
}

fn logError(io: std.Io, msg: []const u8) void {
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &.{});
    const w = &stderr_writer.interface;
    w.writeAll("[sig-sync] ERROR: ") catch {};
    w.writeAll(msg) catch {};
    w.writeAll("\n") catch {};
}

fn logFmt(io: std.Io, buf: []u8, comptime fmt_str: []const u8, args: anytype) void {
    const msg = sig_fmt.formatInto(buf, fmt_str, args) catch return;
    logInfo(io, msg);
}

// ── Main ─────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Parse args from argv iterator — no allocator needed.
    var options = SyncOptions{};
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip argv[0] (program name)
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--remote")) {
            if (args_iter.next()) |val| options.remote = val;
        } else if (std.mem.eql(u8, arg, "--branch")) {
            if (args_iter.next()) |val| options.branch = val;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            if (args_iter.next()) |val| options.manifest_path = val;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        }
    }

    const manifest = try runSync(io, options);

    var write_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &write_buf);
    const w = &stdout_writer.interface;
    var buf: [256]u8 = undefined;
    const summary = sig_fmt.formatInto(&buf, "Sync complete. {d} entries in manifest.\n", .{manifest.entry_count}) catch "Sync complete.\n";
    try w.writeAll(summary);
    if (manifest.last_commit_len > 0) {
        const detail = sig_fmt.formatInto(&buf, "Last integrated: {s}\n", .{manifest.lastCommit()}) catch "";
        try w.writeAll(detail);
    }
}

// ── Tests (zero allocators) ──────────────────────────────────────────────

test "parseManifest empty input returns default" {
    const manifest = parseManifest("");
    try std.testing.expectEqual(@as(usize, 0), manifest.entry_count);
    try std.testing.expectEqual(@as(usize, 0), manifest.last_commit_len);
    try std.testing.expectEqual(@as(i64, 0), manifest.last_integration_timestamp);
}

test "parseManifest valid JSON" {
    const json =
        \\{
        \\  "last_integrated_commit": "abc1234567890def1234567890abcdef12345678",
        \\  "last_integration_timestamp": 1700000000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "abc1234567890def1234567890abcdef12345678",
        \\      "timestamp": 1700000000,
        \\      "status": "integrated",
        \\      "conflicting_files": null
        \\    }
        \\  ]
        \\}
    ;
    const manifest = parseManifest(json);
    try std.testing.expectEqualStrings("abc1234567890def1234567890abcdef12345678", manifest.lastCommit());
    try std.testing.expectEqual(@as(i64, 1700000000), manifest.last_integration_timestamp);
    try std.testing.expectEqual(@as(usize, 1), manifest.entry_count);
    try std.testing.expectEqualStrings("abc1234567890def1234567890abcdef12345678", manifest.entries[0].commit());
    try std.testing.expectEqual(SyncEntry.Status.integrated, manifest.entries[0].status);
}

test "parseManifest with conflict entry" {
    const json =
        \\{
        \\  "last_integrated_commit": "aaa0000000000000000000000000000000000000",
        \\  "last_integration_timestamp": 1700000000,
        \\  "entries": [
        \\    {
        \\      "upstream_commit": "bbb0000000000000000000000000000000000000",
        \\      "timestamp": 1700001000,
        \\      "status": "conflict",
        \\      "conflicting_files": ["lib/sig/fmt.zig", "src/main.zig"]
        \\    }
        \\  ]
        \\}
    ;
    const manifest = parseManifest(json);
    try std.testing.expectEqual(@as(usize, 1), manifest.entry_count);
    try std.testing.expectEqual(SyncEntry.Status.conflict, manifest.entries[0].status);
    try std.testing.expectEqual(@as(usize, 2), manifest.entries[0].conflict_count);
    try std.testing.expectEqualStrings("lib/sig/fmt.zig", manifest.entries[0].conflictFile(0));
    try std.testing.expectEqualStrings("src/main.zig", manifest.entries[0].conflictFile(1));
}

test "parseManifest invalid JSON returns default" {
    const manifest = parseManifest("not json at all");
    try std.testing.expectEqual(@as(usize, 0), manifest.entry_count);
    try std.testing.expectEqual(@as(usize, 0), manifest.last_commit_len);
}

test "serializeManifest round trip" {
    var manifest = SyncManifest{};
    manifest.setLastCommit("abc1234567890def1234567890abcdef12345678");
    manifest.last_integration_timestamp = 1700000000;
    var entry = SyncEntry{};
    entry.setCommit("abc1234567890def1234567890abcdef12345678");
    entry.timestamp = 1700000000;
    entry.status = .integrated;
    manifest.addEntry(entry);

    var buf: [8192]u8 = undefined;
    const serialized = try serializeManifest(&manifest, &buf);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "abc1234567890def1234567890abcdef12345678") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "1700000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "integrated") != null);

    // Parse it back.
    const parsed = parseManifest(serialized);
    try std.testing.expectEqualStrings("abc1234567890def1234567890abcdef12345678", parsed.lastCommit());
    try std.testing.expectEqual(@as(i64, 1700000000), parsed.last_integration_timestamp);
    try std.testing.expectEqual(@as(usize, 1), parsed.entry_count);
}

test "SyncEntry status values" {
    const integrated: SyncEntry.Status = .integrated;
    const conflict_status: SyncEntry.Status = .conflict;
    const skipped: SyncEntry.Status = .skipped;
    const ai_resolved: SyncEntry.Status = .ai_resolved;
    try std.testing.expect(integrated != conflict_status);
    try std.testing.expect(integrated != skipped);
    try std.testing.expect(integrated != ai_resolved);
    try std.testing.expect(conflict_status != skipped);
    try std.testing.expect(conflict_status != ai_resolved);
    try std.testing.expect(skipped != ai_resolved);
}

test "SyncManifest default values" {
    const manifest = SyncManifest{};
    try std.testing.expectEqual(@as(usize, 0), manifest.last_commit_len);
    try std.testing.expectEqual(@as(i64, 0), manifest.last_integration_timestamp);
    try std.testing.expectEqual(@as(usize, 0), manifest.entry_count);
}

test "SyncOptions default values" {
    const options = SyncOptions{};
    try std.testing.expectEqualStrings("origin", options.remote);
    try std.testing.expectEqualStrings("master", options.branch);
    try std.testing.expectEqualStrings("tools/sig_sync/manifest.json", options.manifest_path);
    try std.testing.expect(!options.dry_run);
}
