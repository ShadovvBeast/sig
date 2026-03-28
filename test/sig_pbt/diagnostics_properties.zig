// Feature: sig-memory-model, Property 13: Diagnostics detection and classification
// Feature: sig-memory-model, Property 14: Diagnostic mode severity
// Feature: sig-memory-model, Property 20: Non-canonical pattern detection
//
// **Validates: Requirements 8.1, 8.2, 8.3, 8.4, 8.5, 9.1, 9.2, 9.3, 9.5, 13.3**

const std = @import("std");
const harness = @import("harness");
const sig_diag = @import("sig_diagnostics");

// ---------------------------------------------------------------------------
// Source snippet generators
// ---------------------------------------------------------------------------

fn genDirectAllocSource(random: std.Random, buf: []u8) []const u8 {
    const patterns = [_][]const u8{
        "allocator.alloc(u8, 64)",
        "allocator.create(Node)",
        "allocator.free(ptr)",
        "allocator.destroy(obj)",
        "allocator.realloc(ptr, 128)",
    };
    const pat = patterns[random.uintAtMost(usize, patterns.len - 1)];
    const names = [_][]const u8{ "doWork", "process", "handle", "execute", "run" };
    const name = names[random.uintAtMost(usize, names.len - 1)];
    return std.fmt.bufPrint(
        buf,
        "fn {s}() void {{\n    const x = {s};\n    _ = x;\n}}\n",
        .{ name, pat },
    ) catch buf[0..0];
}

fn genTransitiveSource(random: std.Random, buf: []u8) []const u8 {
    const params = [_][]const u8{
        "alloc: std.mem.Allocator",
        "a: mem.Allocator",
        "allocator: Allocator",
    };
    const param = params[random.uintAtMost(usize, params.len - 1)];
    const names = [_][]const u8{ "init", "setup", "create", "build", "make" };
    const name = names[random.uintAtMost(usize, names.len - 1)];
    return std.fmt.bufPrint(
        buf,
        "pub fn {s}({s}) void {{\n    _ = alloc;\n}}\n",
        .{ name, param },
    ) catch buf[0..0];
}

fn genUnknownSource(random: std.Random, buf: []u8) []const u8 {
    const snippets = [_][]const u8{
        "pub fn process(cb: fn(usize) void) void {\n    cb(42);\n}\n",
        "pub fn apply(f: *const fn(u8) u8) void {\n    _ = f;\n}\n",
    };
    const s = snippets[random.uintAtMost(usize, snippets.len - 1)];
    if (s.len > buf.len) return buf[0..0];
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

fn genNonCanonicalSource(random: std.Random, buf: []u8) []const u8 {
    const choice = random.uintAtMost(u8, 2);
    return switch (choice) {
        0 => genDirectAllocSource(random, buf),
        1 => genTransitiveSource(random, buf),
        2 => genUnknownSource(random, buf),
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Property 13: Diagnostics detection and classification
// ---------------------------------------------------------------------------

test "Property 13: direct allocation sources produce direct_allocation entries" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const source = genDirectAllocSource(random, &buf);
            if (source.len == 0) return;
            const entries = try sig_diag.analyzeSource(
                gpa,
                source,
                "prop13.zig",
                .default,
            );
            defer sig_diag.freeEntries(gpa, entries);
            // Must detect at least one entry (Req 8.1)
            try std.testing.expect(entries.len > 0);
            for (entries) |e| {
                try std.testing.expectEqualStrings("prop13.zig", e.file_path);
                try std.testing.expect(e.line > 0);
                try std.testing.expect(e.function_name.len > 0);
                if (e.classification == .direct_allocation) {
                    try std.testing.expect(e.call_path == null);
                }
            }
        }
    };
    harness.property(
        "direct allocation sources produce direct_allocation entries",
        S.run,
    );
}

test "Property 13: transitive sources produce transitive entries with call_path" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const source = genTransitiveSource(random, &buf);
            if (source.len == 0) return;
            const entries = try sig_diag.analyzeSource(
                gpa,
                source,
                "prop13t.zig",
                .default,
            );
            defer sig_diag.freeEntries(gpa, entries);
            try std.testing.expect(entries.len > 0);
            var found_transitive = false;
            for (entries) |e| {
                try std.testing.expectEqualStrings("prop13t.zig", e.file_path);
                try std.testing.expect(e.line > 0);
                try std.testing.expect(e.function_name.len > 0);
                if (e.classification == .transitive_allocation) {
                    found_transitive = true;
                    try std.testing.expect(e.call_path != null);
                    try std.testing.expect(e.call_path.?.len > 0);
                }
            }
            try std.testing.expect(found_transitive);
        }
    };
    harness.property(
        "transitive sources produce transitive entries with call_path",
        S.run,
    );
}

test "Property 13: unknown behavior sources produce unknown entries" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const source = genUnknownSource(random, &buf);
            if (source.len == 0) return;
            const entries = try sig_diag.analyzeSource(
                gpa,
                source,
                "prop13u.zig",
                .default,
            );
            defer sig_diag.freeEntries(gpa, entries);
            try std.testing.expect(entries.len > 0);
            var found_unknown = false;
            for (entries) |e| {
                try std.testing.expectEqualStrings("prop13u.zig", e.file_path);
                try std.testing.expect(e.line > 0);
                if (e.classification == .unknown_memory_behavior) {
                    found_unknown = true;
                }
            }
            try std.testing.expect(found_unknown);
        }
    };
    harness.property(
        "unknown behavior sources produce unknown entries",
        S.run,
    );
}

// ---------------------------------------------------------------------------
// Property 14: Diagnostic mode severity
// ---------------------------------------------------------------------------

test "Property 14: default mode formats all entries as warnings" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const source = genNonCanonicalSource(random, &buf);
            if (source.len == 0) return;
            const entries = try sig_diag.analyzeSource(
                gpa,
                source,
                "prop14.zig",
                .default,
            );
            defer sig_diag.freeEntries(gpa, entries);
            for (entries) |e| {
                const msg = try sig_diag.formatDiagnostic(gpa, e, .default);
                defer gpa.free(msg);
                try std.testing.expect(
                    std.mem.indexOf(u8, msg, "warning") != null,
                );
                try std.testing.expect(
                    std.mem.indexOf(u8, msg, "error") == null,
                );
                const has_class =
                    (std.mem.indexOf(u8, msg, "direct allocation") != null) or
                    (std.mem.indexOf(u8, msg, "transitive allocation") != null) or
                    (std.mem.indexOf(u8, msg, "unknown memory behavior") != null);
                try std.testing.expect(has_class);
                try std.testing.expect(
                    std.mem.indexOf(u8, msg, "prop14.zig") != null,
                );
            }
        }
    };
    harness.property(
        "default mode formats all entries as warnings",
        S.run,
    );
}

test "Property 14: strict mode formats all entries as errors" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const source = genNonCanonicalSource(random, &buf);
            if (source.len == 0) return;
            const entries = try sig_diag.analyzeSource(
                gpa,
                source,
                "prop14s.zig",
                .strict,
            );
            defer sig_diag.freeEntries(gpa, entries);
            for (entries) |e| {
                const msg = try sig_diag.formatDiagnostic(gpa, e, .strict);
                defer gpa.free(msg);
                try std.testing.expect(
                    std.mem.indexOf(u8, msg, "error") != null,
                );
                const has_class =
                    (std.mem.indexOf(u8, msg, "direct allocation") != null) or
                    (std.mem.indexOf(u8, msg, "transitive allocation") != null) or
                    (std.mem.indexOf(u8, msg, "unknown memory behavior") != null);
                try std.testing.expect(has_class);
                try std.testing.expect(
                    std.mem.indexOf(u8, msg, "prop14s.zig") != null,
                );
            }
        }
    };
    harness.property(
        "strict mode formats all entries as errors",
        S.run,
    );
}

test "Property 14: same entries produce warning in default, error in strict" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            const entry = sig_diag.DiagnosticEntry{
                .file_path = "test.zig",
                .line = 5,
                .column = 1,
                .function_name = "foo",
                .classification = .direct_allocation,
                .call_path = null,
            };
            const default_msg = try sig_diag.formatDiagnostic(
                gpa,
                entry,
                .default,
            );
            defer gpa.free(default_msg);
            const strict_msg = try sig_diag.formatDiagnostic(
                gpa,
                entry,
                .strict,
            );
            defer gpa.free(strict_msg);
            try std.testing.expect(
                std.mem.indexOf(u8, default_msg, "warning") != null,
            );
            try std.testing.expect(
                std.mem.indexOf(u8, strict_msg, "error") != null,
            );
        }
    };
    harness.property(
        "same entries produce warning in default, error in strict",
        S.run,
    );
}

// ---------------------------------------------------------------------------
// Property 20: Non-canonical pattern detection
// ---------------------------------------------------------------------------

test "Property 20: non-canonical patterns always produce at least one diagnostic" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const source = genNonCanonicalSource(random, &buf);
            if (source.len == 0) return;
            const entries = try sig_diag.analyzeSource(
                gpa,
                source,
                "prop20.zig",
                .default,
            );
            defer sig_diag.freeEntries(gpa, entries);
            try std.testing.expect(entries.len > 0);
        }
    };
    harness.property(
        "non-canonical patterns always produce at least one diagnostic",
        S.run,
    );
}
