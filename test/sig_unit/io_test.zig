const std = @import("std");
const testing = std.testing;
const sig_io = @import("sig_io");

// ── Unit Tests for readInto, readAtMost, StreamReader ────────────────────
// Requirements: 3.1, 3.2, 3.3, 3.4, 3.5

/// A minimal reader backed by a byte slice.
const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn read(self: *SliceReader, buf: []u8) error{}!usize {
        if (self.pos >= self.data.len) return 0;
        const remaining = self.data.len - self.pos;
        const n = @min(remaining, buf.len);
        @memcpy(buf[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

// ── readInto tests ───────────────────────────────────────────────────────

test "readInto with 'hello' data and 10-byte buffer returns 'hello'" {
    var reader = SliceReader{ .data = "hello" };
    var buf: [10]u8 = undefined;
    const result = try sig_io.readInto(&reader, &buf);
    try testing.expectEqualStrings("hello", result);
    try testing.expectEqual(@as(usize, 5), result.len);
}

test "readInto with 'hello' data and 3-byte buffer returns BufferTooSmall" {
    var reader = SliceReader{ .data = "hello" };
    var buf: [3]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, sig_io.readInto(&reader, &buf));
}

test "readInto with empty data and any buffer returns empty slice" {
    var reader = SliceReader{ .data = "" };
    var buf: [16]u8 = undefined;
    const result = try sig_io.readInto(&reader, &buf);
    try testing.expectEqual(@as(usize, 0), result.len);
}

// ── readAtMost tests ─────────────────────────────────────────────────────

test "readAtMost with 'hello world' and max_bytes=5 returns 'hello'" {
    var reader = SliceReader{ .data = "hello world" };
    var buf: [64]u8 = undefined;
    const result = try sig_io.readAtMost(&reader, &buf, 5);
    try testing.expectEqualStrings("hello", result);
}

test "readAtMost with 'hi' and max_bytes=10 returns 'hi'" {
    var reader = SliceReader{ .data = "hi" };
    var buf: [64]u8 = undefined;
    const result = try sig_io.readAtMost(&reader, &buf, 10);
    try testing.expectEqualStrings("hi", result);
}

// ── StreamReader tests ───────────────────────────────────────────────────

test "StreamReader with 4-byte chunks reading 'hello world' returns correct chunks" {
    var reader = SliceReader{ .data = "hello world" };
    var stream = sig_io.StreamReader(4){};

    const chunk1 = stream.next(&reader).?;
    try testing.expectEqualStrings("hell", chunk1);

    const chunk2 = stream.next(&reader).?;
    try testing.expectEqualStrings("o wo", chunk2);

    const chunk3 = stream.next(&reader).?;
    try testing.expectEqualStrings("rld", chunk3);

    try testing.expectEqual(@as(?[]const u8, null), stream.next(&reader));
}

test "StreamReader with empty data returns null immediately" {
    var reader = SliceReader{ .data = "" };
    var stream = sig_io.StreamReader(4){};
    try testing.expectEqual(@as(?[]const u8, null), stream.next(&reader));
}
