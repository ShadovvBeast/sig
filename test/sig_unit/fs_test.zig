// Unit tests for lib/sig/fs.zig
// Requirements: 15.1, 15.2, 15.3, 15.4, 15.5

const std = @import("std");
const testing = std.testing;
const sig_fs = @import("sig_fs");

// ── joinPath tests ───────────────────────────────────────────────────────

test "joinPath with two segments produces 'a/b'" {
    var buf: [64]u8 = undefined;
    const result = try sig_fs.joinPath(&buf, &.{ "a", "b" });
    try testing.expectEqualStrings("a" ++ &[_]u8{std.fs.path.sep} ++ "b", result);
}

test "joinPath with single segment returns that segment" {
    var buf: [64]u8 = undefined;
    const result = try sig_fs.joinPath(&buf, &.{"hello"});
    try testing.expectEqualStrings("hello", result);
}

test "joinPath with empty segments list returns empty" {
    var buf: [64]u8 = undefined;
    const empty: []const []const u8 = &.{};
    const result = try sig_fs.joinPath(&buf, empty);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "joinPath with three segments" {
    var buf: [64]u8 = undefined;
    const sep = &[_]u8{std.fs.path.sep};
    const result = try sig_fs.joinPath(&buf, &.{ "usr", "local", "bin" });
    try testing.expectEqualStrings("usr" ++ sep ++ "local" ++ sep ++ "bin", result);
}

test "joinPath strips trailing separators from segments" {
    var buf: [64]u8 = undefined;
    const sep = &[_]u8{std.fs.path.sep};
    const seg_with_sep = "foo" ++ sep;
    const result = try sig_fs.joinPath(&buf, &.{ seg_with_sep, "bar" });
    try testing.expectEqualStrings("foo" ++ sep ++ "bar", result);
}

test "joinPath returns BufferTooSmall for undersized buffer" {
    var buf: [3]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, sig_fs.joinPath(&buf, &.{ "hello", "world" }));
}

test "joinPath with zero-length buffer and non-empty segments returns BufferTooSmall" {
    var buf: [0]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, sig_fs.joinPath(&buf, &.{"a"}));
}

// ── DirEntry tests ───────────────────────────────────────────────────────

test "DirEntry.name returns correct slice" {
    var entry = sig_fs.DirEntry{ .kind = .file };
    const src = "test.txt";
    @memcpy(entry.name_buf[0..src.len], src);
    entry.name_len = src.len;
    try testing.expectEqualStrings("test.txt", entry.name());
}

test "DirEntry default name_len is zero" {
    const entry = sig_fs.DirEntry{ .kind = .directory };
    try testing.expectEqual(@as(usize, 0), entry.name_len);
    try testing.expectEqual(@as(usize, 0), entry.name().len);
}
