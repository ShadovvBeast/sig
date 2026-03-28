const std = @import("std");
const testing = std.testing;
const sig_fmt = @import("fmt");

// ── Unit Tests for formatInto and measureFormat ──────────────────────────
// Requirements: 2.1, 2.2, 2.3, 2.4

test "formatInto produces correct output for 'hello {d}' with 42" {
    var buf: [64]u8 = undefined;
    const result = try sig_fmt.formatInto(&buf, "hello {d}", .{42});
    try testing.expectEqualStrings("hello 42", result);
}

test "measureFormat returns 8 for 'hello {d}' with 42" {
    const len = sig_fmt.measureFormat("hello {d}", .{42});
    try testing.expectEqual(@as(usize, 8), len);
}

test "formatInto with empty format string produces empty output" {
    var buf: [16]u8 = undefined;
    const result = try sig_fmt.formatInto(&buf, "", .{});
    try testing.expectEqual(@as(usize, 0), result.len);
    try testing.expectEqualStrings("", result);
}

test "formatInto with zero-length buffer and non-empty format returns BufferTooSmall" {
    var buf: [0]u8 = undefined;
    const result = sig_fmt.formatInto(&buf, "x", .{});
    try testing.expectError(error.BufferTooSmall, result);
}

test "formatInto with exact-size buffer succeeds" {
    const expected = "hello 42";
    var buf: [8]u8 = undefined;
    const result = try sig_fmt.formatInto(&buf, "hello {d}", .{42});
    try testing.expectEqualStrings(expected, result);
}

test "measureFormat returns 0 for empty format string" {
    const len = sig_fmt.measureFormat("", .{});
    try testing.expectEqual(@as(usize, 0), len);
}
