const std = @import("std");
const testing = std.testing;
const sig_diag = @import("sig_diagnostics");

// Unit Tests for Sig_Diagnostics
// Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 9.1, 9.2, 13.3

test "analyzeSource: detects direct allocator.alloc call" {
    const source =
        \\fn doStuff() void {
        \\    const ptr = allocator.alloc(u8, 100);
        \\    _ = ptr;
        \\}
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(
        gpa,
        source,
        "test.zig",
        .default,
    );
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(
        sig_diag.Classification.direct_allocation,
        entries[0].classification,
    );
    try testing.expectEqualStrings("test.zig", entries[0].file_path);
    try testing.expectEqual(@as(u32, 2), entries[0].line);
    try testing.expectEqualStrings("doStuff", entries[0].function_name);
    try testing.expect(entries[0].call_path == null);
}

test "analyzeSource: detects transitive via Allocator param" {
    const source =
        \\pub fn init(alloc: std.mem.Allocator) void {
        \\    _ = alloc;
        \\}
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(
        gpa,
        source,
        "lib.zig",
        .default,
    );
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(
        sig_diag.Classification.transitive_allocation,
        entries[0].classification,
    );
    try testing.expectEqualStrings("lib.zig", entries[0].file_path);
    try testing.expectEqual(@as(u32, 1), entries[0].line);
    try testing.expect(entries[0].call_path != null);
    const cp = entries[0].call_path.?;
    try testing.expect(cp.len > 0);
}

test "analyzeSource: detects unknown memory behavior via fn pointer" {
    const source =
        \\pub fn process(cb: fn(usize) void) void {
        \\    cb(42);
        \\}
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(
        gpa,
        source,
        "generic.zig",
        .default,
    );
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(
        sig_diag.Classification.unknown_memory_behavior,
        entries[0].classification,
    );
    try testing.expectEqualStrings("generic.zig", entries[0].file_path);
}

test "analyzeSource: clean code produces no diagnostics" {
    const source =
        \\pub fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(
        gpa,
        source,
        "clean.zig",
        .default,
    );
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "formatDiagnostic: default mode produces warning severity" {
    const entry = sig_diag.DiagnosticEntry{
        .file_path = "src/main.zig",
        .line = 10,
        .column = 5,
        .function_name = "init",
        .classification = .direct_allocation,
        .call_path = null,
    };
    const gpa = testing.allocator;
    const msg = try sig_diag.formatDiagnostic(gpa, entry, .default);
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "warning") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "10") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "direct allocation") != null);
}

test "formatDiagnostic: strict mode produces error severity" {
    const entry = sig_diag.DiagnosticEntry{
        .file_path = "src/main.zig",
        .line = 10,
        .column = 5,
        .function_name = "init",
        .classification = .direct_allocation,
        .call_path = null,
    };
    const gpa = testing.allocator;
    const msg = try sig_diag.formatDiagnostic(gpa, entry, .strict);
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "error") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "warning") == null);
}

test "analyzeSource: call_path non-null for transitive, null for direct" {
    const source =
        \\pub fn create(alloc: std.mem.Allocator) void {
        \\    const p = allocator.alloc(u8, 10);
        \\    _ = alloc;
        \\    _ = p;
        \\}
    ;
    const gpa = testing.allocator;
    const entries = try sig_diag.analyzeSource(
        gpa,
        source,
        "mixed.zig",
        .default,
    );
    defer sig_diag.freeEntries(gpa, entries);
    try testing.expect(entries.len >= 2);
    var found_transitive = false;
    var found_direct = false;
    for (entries) |e| {
        switch (e.classification) {
            .transitive_allocation => {
                found_transitive = true;
                try testing.expect(e.call_path != null);
            },
            .direct_allocation => {
                found_direct = true;
                try testing.expect(e.call_path == null);
            },
            .unknown_memory_behavior => {},
        }
    }
    try testing.expect(found_transitive);
    try testing.expect(found_direct);
}
