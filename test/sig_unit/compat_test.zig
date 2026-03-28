// Zig Compatibility Tests
// Feature: sig-memory-model, Property 16: Zig source compatibility
// Feature: sig-memory-model, Property 17: Allocator usage produces diagnostics, not rejection
//
// **Validates: Requirements 11.1, 11.2, 11.3**

const std = @import("std");
const testing = std.testing;
const sig_diag = @import("sig_diagnostics");
const harness = @import("harness");

// ============================================================================
// Task 12.1 — Standard Zig code compiles unmodified under Sig
// Requirements: 11.1, 11.2, 11.3, 11.4
// ============================================================================

test "pure Zig code without sig import produces zero diagnostics" {
    // Requirement 11.1: valid Zig source not importing sig compiles identically.
    // We verify the diagnostics layer sees nothing to flag.
    const source =
        \\const std = @import("std");
        \\
        \\pub fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\
        \\pub fn fibonacci(n: u32) u32 {
        \\    if (n <= 1) return n;
        \\    var a: u32 = 0;
        \\    var b: u32 = 1;
        \\    var i: u32 = 2;
        \\    while (i <= n) : (i += 1) {
        \\        const tmp = a + b;
        \\        a = b;
        \\        b = tmp;
        \\    }
        \\    return b;
        \\}
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(gpa, source, "pure_zig.zig", .default);
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "Zig code using std.mem.Allocator produces diagnostics per mode" {
    // Requirement 11.2: Allocator-based code compiles but produces diagnostics.
    const source =
        \\const std = @import("std");
        \\
        \\pub fn createList(alloc: std.mem.Allocator) ![]u8 {
        \\    return alloc.alloc(u8, 1024);
        \\}
    ;
    const gpa = testing.allocator;

    // Default mode: produces warnings (entries exist, formatted as warnings)
    const entries_default = try sig_diag.analyzeSource(gpa, source, "alloc_code.zig", .default);
    defer sig_diag.freeEntries(gpa, entries_default);
    try testing.expect(entries_default.len > 0);

    for (entries_default) |e| {
        const msg = try sig_diag.formatDiagnostic(gpa, e, .default);
        defer gpa.free(msg);
        try testing.expect(std.mem.indexOf(u8, msg, "warning") != null);
    }

    // Strict mode: same entries, formatted as errors
    const entries_strict = try sig_diag.analyzeSource(gpa, source, "alloc_code.zig", .strict);
    defer sig_diag.freeEntries(gpa, entries_strict);
    try testing.expect(entries_strict.len > 0);

    for (entries_strict) |e| {
        const msg = try sig_diag.formatDiagnostic(gpa, e, .strict);
        defer gpa.free(msg);
        try testing.expect(std.mem.indexOf(u8, msg, "error") != null);
    }
}

test "sig diagnostics module works alongside std in same compilation unit" {
    // Requirement 11.3: @import("sig") works alongside @import("std").
    // We demonstrate both std and sig_diag are usable in the same file.
    const gpa = testing.allocator;

    // Use std functionality
    var buf: [64]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{s} {s}", .{ "hello", "world" });
    try testing.expectEqualStrings("hello world", result);

    // Use sig_diag functionality in the same test
    const source =
        \\pub fn noop() void {}
    ;
    const entries = try sig_diag.analyzeSource(gpa, source, "mixed.zig", .default);
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "sig diagnostics does not interfere with standard Zig operations" {
    // Requirement 11.4: Sig preserves Zig's compilation semantics.
    // Standard operations work correctly even after diagnostics analysis.
    const gpa = testing.allocator;

    // Run diagnostics on some source
    const source =
        \\fn compute(x: i32) i32 {
        \\    return x * 2 + 1;
        \\}
    ;
    const entries = try sig_diag.analyzeSource(gpa, source, "compat.zig", .default);
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);

    // Standard Zig operations still work fine
    var buf: [64]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "value={d}", .{42});
    try testing.expectEqualStrings("value=42", result);

    // Array operations
    var arr = [_]u32{ 5, 3, 1, 4, 2 };
    std.mem.sort(u32, &arr, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4, 5 }, &arr);
}

// ============================================================================
// Task 12.2 — Property 16: Zig source compatibility
// **Validates: Requirements 11.1**
// ============================================================================

test "Property 16: clean Zig source produces zero diagnostics" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = testing.allocator;
            var buf: [1024]u8 = undefined;
            const source = genCleanZigSource(random, &buf);
            if (source.len == 0) return;

            const entries = try sig_diag.analyzeSource(
                gpa,
                source,
                "prop16.zig",
                .default,
            );
            defer sig_diag.freeEntries(gpa, entries);

            // Clean Zig source must produce zero diagnostics
            try testing.expectEqual(@as(usize, 0), entries.len);
        }
    };
    harness.property(
        "clean Zig source produces zero diagnostics",
        S.run,
    );
}

// ============================================================================
// Task 12.3 — Property 17: Allocator usage produces diagnostics, not rejection
// **Validates: Requirements 11.2**
// ============================================================================

test "Property 17: allocator usage produces diagnostics not rejection" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = testing.allocator;
            var buf: [1024]u8 = undefined;
            const source = genAllocatorSource(random, &buf);
            if (source.len == 0) return;

            // analyzeSource must succeed (not error/reject) — code is valid
            const entries = try sig_diag.analyzeSource(
                gpa,
                source,
                "prop17.zig",
                .default,
            );
            defer sig_diag.freeEntries(gpa, entries);

            // Must produce at least one diagnostic (not silently accept)
            try testing.expect(entries.len > 0);

            // Each entry must have valid fields
            for (entries) |e| {
                try testing.expect(e.line > 0);
                try testing.expect(e.function_name.len > 0);
                try testing.expectEqualStrings("prop17.zig", e.file_path);

                // Formatting must succeed in both modes (no rejection)
                const warn_msg = try sig_diag.formatDiagnostic(gpa, e, .default);
                defer gpa.free(warn_msg);
                try testing.expect(warn_msg.len > 0);

                const err_msg = try sig_diag.formatDiagnostic(gpa, e, .strict);
                defer gpa.free(err_msg);
                try testing.expect(err_msg.len > 0);
            }
        }
    };
    harness.property(
        "allocator usage produces diagnostics not rejection",
        S.run,
    );
}

// ============================================================================
// Task 12.4 — Unit tests for compatibility
// Requirements: 11.1, 11.2, 11.3
// ============================================================================

test "empty source produces no diagnostics" {
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(gpa, "", "empty.zig", .default);
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "source with only comments produces no diagnostics" {
    const source =
        \\// This is a comment
        \\// Another comment
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(gpa, source, "comments.zig", .default);
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "source with struct definition produces no diagnostics" {
    const source =
        \\const Point = struct {
        \\    x: f64,
        \\    y: f64,
        \\
        \\    pub fn distance(self: Point, other: Point) f64 {
        \\        const dx = self.x - other.x;
        \\        const dy = self.y - other.y;
        \\        return @sqrt(dx * dx + dy * dy);
        \\    }
        \\};
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(gpa, source, "struct.zig", .default);
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "source with stack-only memory is clean" {
    const source =
        \\pub fn process() void {
        \\    var buf: [256]u8 = undefined;
        \\    buf[0] = 42;
        \\    _ = buf;
        \\}
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(gpa, source, "stack.zig", .default);
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "direct allocator call detected in both modes" {
    const source =
        \\fn loadData() void {
        \\    const data = allocator.alloc(u8, 4096);
        \\    _ = data;
        \\}
    ;
    const gpa = testing.allocator;

    const default_entries = try sig_diag.analyzeSource(gpa, source, "load.zig", .default);
    defer sig_diag.freeEntries(gpa, default_entries);
    try testing.expect(default_entries.len > 0);

    const strict_entries = try sig_diag.analyzeSource(gpa, source, "load.zig", .strict);
    defer sig_diag.freeEntries(gpa, strict_entries);
    try testing.expect(strict_entries.len > 0);

    // Same number of entries regardless of mode
    try testing.expectEqual(default_entries.len, strict_entries.len);
}

test "mixed std and sig patterns: allocator flagged, pure math clean" {
    // A file with both clean and allocator-using functions
    const source =
        \\const std = @import("std");
        \\
        \\pub fn pureAdd(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\
        \\pub fn allocating(alloc: std.mem.Allocator) !void {
        \\    const buf = try alloc.alloc(u8, 64);
        \\    _ = buf;
        \\}
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(gpa, source, "mixed_patterns.zig", .default);
    defer sig_diag.freeEntries(gpa, entries);

    // Should have diagnostics for the allocating function, not for pureAdd
    try testing.expect(entries.len > 0);

    var has_allocating_fn = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.function_name, "allocating")) {
            has_allocating_fn = true;
        }
        // pureAdd should not appear in diagnostics
        try testing.expect(!std.mem.eql(u8, e.function_name, "pureAdd"));
    }
    try testing.expect(has_allocating_fn);
}

// ============================================================================
// Generators for property tests
// ============================================================================

/// Generates clean Zig source that uses no allocators — only pure computation,
/// stack variables, and standard control flow.
fn genCleanZigSource(random: std.Random, buf: []u8) []const u8 {
    const templates = [_][]const u8{
        "pub fn add(a: u32, b: u32) u32 {\n    return a + b;\n}\n",
        "pub fn max(a: i64, b: i64) i64 {\n    return if (a > b) a else b;\n}\n",
        "pub fn negate(x: i32) i32 {\n    return -x;\n}\n",
        "const LIMIT: usize = 1024;\npub fn isWithin(n: usize) bool {\n    return n < LIMIT;\n}\n",
        "pub fn swap(a: *u32, b: *u32) void {\n    const tmp = a.*;\n    a.* = b.*;\n    b.* = tmp;\n}\n",
        "pub fn identity(x: u8) u8 {\n    return x;\n}\n",
        "pub fn sum(items: []const u32) u64 {\n    var total: u64 = 0;\n    for (items) |v| total += v;\n    return total;\n}\n",
        "const Point = struct { x: f32, y: f32 };\n",
    };
    const t = templates[random.uintAtMost(usize, templates.len - 1)];
    if (t.len > buf.len) return buf[0..0];
    @memcpy(buf[0..t.len], t);
    return buf[0..t.len];
}

/// Generates Zig source that uses allocator-based APIs — should always
/// produce at least one diagnostic entry.
fn genAllocatorSource(random: std.Random, buf: []u8) []const u8 {
    const templates = [_][]const u8{
        "fn work() void {\n    const p = allocator.alloc(u8, 64);\n    _ = p;\n}\n",
        "fn build() void {\n    const obj = allocator.create(Node);\n    _ = obj;\n}\n",
        "fn cleanup() void {\n    allocator.free(ptr);\n}\n",
        "pub fn init(alloc: std.mem.Allocator) void {\n    _ = alloc;\n}\n",
        "pub fn setup(a: mem.Allocator) void {\n    _ = a;\n}\n",
        "fn resize() void {\n    const p = allocator.realloc(old, 256);\n    _ = p;\n}\n",
    };
    const t = templates[random.uintAtMost(usize, templates.len - 1)];
    if (t.len > buf.len) return buf[0..0];
    @memcpy(buf[0..t.len], t);
    return buf[0..t.len];
}
