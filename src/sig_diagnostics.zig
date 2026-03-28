const std = @import("std");

// ──────────────────────────────────────────────
//  Types
// ──────────────────────────────────────────────

pub const Classification = enum {
    direct_allocation,
    transitive_allocation,
    unknown_memory_behavior,
};

pub const DiagnosticEntry = struct {
    file_path: []const u8,
    line: u32,
    column: u32,
    function_name: []const u8,
    classification: Classification,
    call_path: ?[]const []const u8,
};

pub const Mode = enum { default, strict };

// ──────────────────────────────────────────────
//  Sema-based analysis (placeholder)
// ──────────────────────────────────────────────

/// Placeholder for future Sema-based analysis.
/// Currently returns an empty slice; real implementation will walk
/// the Sema result call graph once compiler integration is wired up.
pub fn analyze(_: Mode) []const DiagnosticEntry {
    return &[_]DiagnosticEntry{};
}

// ──────────────────────────────────────────────
//  Source-text analysis
// ──────────────────────────────────────────────

/// Direct allocator call patterns.
const direct_patterns = [_][]const u8{
    "allocator.alloc(",
    "allocator.create(",
    "allocator.free(",
    "allocator.destroy(",
    "allocator.realloc(",
    "allocator.resize(",
    ".alloc(",
    ".create(",
    ".free(",
    ".destroy(",
    ".realloc(",
    ".resize(",
};

/// Patterns indicating a function accepts an allocator parameter (transitive).
const allocator_param_patterns = [_][]const u8{
    "std.mem.Allocator",
    "mem.Allocator",
    "Allocator",
};

/// Patterns indicating unknown / indeterminate memory behaviour.
const unknown_patterns = [_][]const u8{
    "anytype",
    "fn(",
    "*const fn(",
};

/// Analyzes source text for allocator usage patterns.
/// Returns diagnostic entries for detected allocation sites.
/// Caller owns the returned slice and all inner slices (allocated via `gpa`).
pub fn analyzeSource(
    gpa: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    mode: Mode,
) ![]DiagnosticEntry {
    _ = mode; // mode affects severity at reporting time, not detection

    var entries: std.ArrayList(DiagnosticEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            if (e.call_path) |cp| gpa.free(cp);
        }
        entries.deinit(gpa);
    }

    // Track the current function name so we can attribute findings.
    var current_function: []const u8 = "<top-level>";

    var line_num: u32 = 1;
    var i: usize = 0;

    while (i < source.len) {
        // Advance to next newline to process one line at a time.
        var line_end: usize = i;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

        const line = source[i..line_end];

        // Detect function declarations to track current function name.
        if (findFunctionName(line)) |name| {
            current_function = name;
        }

        // Check for direct allocation patterns.
        if (matchesAny(line, &direct_patterns)) |col_offset| {
            try entries.append(gpa, .{
                .file_path = file_path,
                .line = line_num,
                .column = @intCast(col_offset + 1),
                .function_name = current_function,
                .classification = .direct_allocation,
                .call_path = null,
            });
        } else if (matchesAllocatorParam(line, &allocator_param_patterns)) |col_offset| {
            // A function that accepts an Allocator parameter — transitive allocation.
            try entries.append(gpa, .{
                .file_path = file_path,
                .line = line_num,
                .column = @intCast(col_offset + 1),
                .function_name = current_function,
                .classification = .transitive_allocation,
                .call_path = try buildCallPath(gpa, current_function),
            });
        } else if (matchesUnknown(line, &unknown_patterns)) |col_offset| {
            try entries.append(gpa, .{
                .file_path = file_path,
                .line = line_num,
                .column = @intCast(col_offset + 1),
                .function_name = current_function,
                .classification = .unknown_memory_behavior,
                .call_path = null,
            });
        }

        // Move past the newline.
        i = line_end + 1;
        line_num += 1;
    }

    return entries.toOwnedSlice(gpa);
}

// ──────────────────────────────────────────────
//  Formatting
// ──────────────────────────────────────────────

/// Formats a DiagnosticEntry into a human-readable message.
/// Caller owns the returned slice.
pub fn formatDiagnostic(gpa: std.mem.Allocator, entry: DiagnosticEntry, mode: Mode) ![]u8 {
    const severity: []const u8 = switch (mode) {
        .default => "warning",
        .strict => "error",
    };

    const classification_str = switch (entry.classification) {
        .direct_allocation => "direct allocation",
        .transitive_allocation => "transitive allocation",
        .unknown_memory_behavior => "unknown memory behavior",
    };

    // Base message: "file:line:col: warning: direct allocation in 'funcName'"
    const base = try std.fmt.allocPrint(
        gpa,
        "{s}:{d}:{d}: {s}: {s} in '{s}'",
        .{
            entry.file_path,
            entry.line,
            entry.column,
            severity,
            classification_str,
            entry.function_name,
        },
    );

    if (entry.call_path) |cp| {
        // Append call path: " (via foo -> bar -> baz)"
        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(gpa);
        try path_buf.appendSlice(gpa, base);
        gpa.free(base);
        try path_buf.appendSlice(gpa, " (via ");
        for (cp, 0..) |segment, idx| {
            if (idx > 0) try path_buf.appendSlice(gpa, " -> ");
            try path_buf.appendSlice(gpa, segment);
        }
        try path_buf.appendSlice(gpa, ")");
        return path_buf.toOwnedSlice(gpa);
    }

    return base;
}

// ──────────────────────────────────────────────
//  Helpers
// ──────────────────────────────────────────────

/// Scans `line` for any of the given patterns. Returns the column offset of the
/// first match, or null if none found.
fn matchesAny(line: []const u8, patterns: []const []const u8) ?usize {
    for (patterns) |pat| {
        if (indexOf(line, pat)) |pos| return pos;
    }
    return null;
}

/// Checks whether a line contains an allocator parameter pattern, but only
/// within what looks like a function signature (contains `fn ` or is a parameter list).
fn matchesAllocatorParam(line: []const u8, patterns: []const []const u8) ?usize {
    const has_fn = indexOf(line, "fn ") != null;
    const has_paren = indexOf(line, "(") != null;
    if (!has_fn and !has_paren) return null;

    for (patterns) |pat| {
        if (indexOf(line, pat)) |pos| return pos;
    }
    return null;
}

/// Checks whether a line contains unknown-memory-behavior patterns.
/// Only flags `anytype` and function pointer patterns in parameter contexts.
fn matchesUnknown(line: []const u8, patterns: []const []const u8) ?usize {
    const has_fn = indexOf(line, "fn ") != null or indexOf(line, "fn(") != null;
    const has_paren = indexOf(line, "(") != null;
    if (!has_fn and !has_paren) return null;

    for (patterns) |pat| {
        if (indexOf(line, pat)) |pos| return pos;
    }
    return null;
}

/// Tries to extract a function name from a line like `fn fooBar(` or `pub fn fooBar(`.
fn findFunctionName(line: []const u8) ?[]const u8 {
    const fn_keyword = "fn ";
    const pos = indexOf(line, fn_keyword) orelse return null;
    const name_start = pos + fn_keyword.len;
    if (name_start >= line.len) return null;

    var name_end = name_start;
    while (name_end < line.len and isIdentChar(line[name_end])) : (name_end += 1) {}
    if (name_end == name_start) return null;
    return line[name_start..name_end];
}

/// Builds a simple call path slice for transitive allocations.
fn buildCallPath(gpa: std.mem.Allocator, function_name: []const u8) ![]const []const u8 {
    const path = try gpa.alloc([]const u8, 1);
    path[0] = function_name;
    return path;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

/// Simple byte-string search. Returns the index of the first occurrence of
/// `needle` in `haystack`, or null.
fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    const limit = haystack.len - needle.len + 1;
    var j: usize = 0;
    while (j < limit) : (j += 1) {
        if (std.mem.eql(u8, haystack[j..][0..needle.len], needle)) return j;
    }
    return null;
}

// ──────────────────────────────────────────────
//  Free helper
// ──────────────────────────────────────────────

/// Frees all memory associated with a slice of DiagnosticEntry returned by analyzeSource.
pub fn freeEntries(gpa: std.mem.Allocator, entries: []DiagnosticEntry) void {
    for (entries) |e| {
        if (e.call_path) |cp| gpa.free(cp);
    }
    gpa.free(entries);
}

// ──────────────────────────────────────────────
//  Inline tests
// ──────────────────────────────────────────────

test "detect direct allocation" {
    const source =
        \\fn doStuff() void {
        \\    const ptr = allocator.alloc(u8, 100);
        \\    _ = ptr;
        \\}
    ;
    const gpa = std.testing.allocator;
    const entries = try analyzeSource(gpa, source, "test.zig", .default);
    defer freeEntries(gpa, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(Classification.direct_allocation, entries[0].classification);
    try std.testing.expectEqual(@as(u32, 2), entries[0].line);
    try std.testing.expectEqualStrings("doStuff", entries[0].function_name);
}

test "detect transitive allocation via Allocator param" {
    const source =
        \\pub fn init(alloc: std.mem.Allocator) void {
        \\    _ = alloc;
        \\}
    ;
    const gpa = std.testing.allocator;
    const entries = try analyzeSource(gpa, source, "test.zig", .default);
    defer freeEntries(gpa, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(Classification.transitive_allocation, entries[0].classification);
    try std.testing.expect(entries[0].call_path != null);
}

test "detect unknown memory behavior" {
    const source =
        \\pub fn process(cb: fn(usize) void) void {
        \\    cb(42);
        \\}
    ;
    const gpa = std.testing.allocator;
    const entries = try analyzeSource(gpa, source, "test.zig", .default);
    defer freeEntries(gpa, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(Classification.unknown_memory_behavior, entries[0].classification);
}

test "format diagnostic default mode" {
    const entry = DiagnosticEntry{
        .file_path = "src/main.zig",
        .line = 10,
        .column = 5,
        .function_name = "init",
        .classification = .direct_allocation,
        .call_path = null,
    };
    const gpa = std.testing.allocator;
    const msg = try formatDiagnostic(gpa, entry, .default);
    defer gpa.free(msg);

    try std.testing.expectEqualStrings("src/main.zig:10:5: warning: direct allocation in 'init'", msg);
}

test "format diagnostic strict mode" {
    const entry = DiagnosticEntry{
        .file_path = "src/main.zig",
        .line = 10,
        .column = 5,
        .function_name = "init",
        .classification = .direct_allocation,
        .call_path = null,
    };
    const gpa = std.testing.allocator;
    const msg = try formatDiagnostic(gpa, entry, .strict);
    defer gpa.free(msg);

    try std.testing.expectEqualStrings("src/main.zig:10:5: error: direct allocation in 'init'", msg);
}

test "analyze placeholder returns empty" {
    const result = analyze(.default);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "no false positives on clean code" {
    const source =
        \\pub fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
    ;
    const gpa = std.testing.allocator;
    const entries = try analyzeSource(gpa, source, "clean.zig", .default);
    defer freeEntries(gpa, entries);

    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
