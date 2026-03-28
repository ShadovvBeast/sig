const std = @import("std");
const testing = std.testing;
const sig_string = @import("sig_string");

// ── Unit Tests for concat, replace, SegmentedString ──────────────────────
// Requirements: 5.1, 5.2, 5.3, 5.4

// ── concat ───────────────────────────────────────────────────────────────

test "concat: ['hello', ' ', 'world'] produces 'hello world'" {
    var buf: [64]u8 = undefined;
    const slices: []const []const u8 = &.{ "hello", " ", "world" };
    const result = try sig_string.concat(&buf, slices);
    try testing.expectEqualStrings("hello world", result);
}

test "concat: empty slices produces ''" {
    var buf: [64]u8 = undefined;
    const slices: []const []const u8 = &.{};
    const result = try sig_string.concat(&buf, slices);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "concat: undersized buffer returns BufferTooSmall" {
    var buf: [5]u8 = undefined;
    const slices: []const []const u8 = &.{ "hello", " ", "world" };
    try testing.expectError(error.BufferTooSmall, sig_string.concat(&buf, slices));
}

// ── replace ──────────────────────────────────────────────────────────────

test "replace: 'hello world' replacing 'world' with 'zig' produces 'hello zig'" {
    var buf: [64]u8 = undefined;
    const result = try sig_string.replace(&buf, "hello world", "world", "zig");
    try testing.expectEqualStrings("hello zig", result);
}

test "replace: no matches copies haystack verbatim" {
    var buf: [64]u8 = undefined;
    const result = try sig_string.replace(&buf, "hello world", "xyz", "zig");
    try testing.expectEqualStrings("hello world", result);
}

test "replace: undersized buffer returns BufferTooSmall" {
    var buf: [3]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, sig_string.replace(&buf, "hello world", "world", "zig"));
}

// ── SegmentedString ──────────────────────────────────────────────────────

test "SegmentedString: append 'hello' then ' world', toSlice produces 'hello world'" {
    var ss = sig_string.SegmentedString(4, 32){};
    try ss.append("hello");
    try ss.append(" world");
    var buf: [64]u8 = undefined;
    const result = try ss.toSlice(&buf);
    try testing.expectEqualStrings("hello world", result);
}

test "SegmentedString: append exceeding capacity returns CapacityExceeded" {
    // 2 chunks × 4 bytes = 8 bytes total capacity
    var ss = sig_string.SegmentedString(2, 4){};
    try ss.append("1234"); // fills chunk 0
    try ss.append("5678"); // fills chunk 1
    try testing.expectError(error.CapacityExceeded, ss.append("x"));
}

test "SegmentedString: toSlice with undersized buffer returns BufferTooSmall" {
    var ss = sig_string.SegmentedString(4, 32){};
    try ss.append("hello world");
    var buf: [5]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, ss.toSlice(&buf));
}
