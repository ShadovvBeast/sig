const std = @import("std");
const testing = std.testing;
const sig_parse = @import("sig_parse");

// ── Unit Tests for streaming parser, pretty-printer ──────────────────────
// Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7

// ── parseInto ────────────────────────────────────────────────────────────

test "parseInto: 'name=zig\\nversion=1\\n' produces ParsedKv with count=2" {
    var buf: [64]u8 = undefined;
    const result = try sig_parse.parseInto("name=zig\nversion=1\n", &buf);
    try testing.expectEqual(@as(usize, 2), result.count);
}

test "parseInto: empty input produces count=0" {
    var buf: [64]u8 = undefined;
    const result = try sig_parse.parseInto("", &buf);
    try testing.expectEqual(@as(usize, 0), result.count);
}

test "parseInto: undersized buffer returns BufferTooSmall" {
    var buf: [5]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, sig_parse.parseInto("name=zig\nversion=1\n", &buf));
}

// ── ParsedKv.pairs ──────────────────────────────────────────────────────

test "ParsedKv.pairs: extracts correct key-value pairs" {
    var buf: [64]u8 = undefined;
    const parsed = try sig_parse.parseInto("name=zig\nversion=1\n", &buf);
    var pair_buf: [4]sig_parse.KvPair = undefined;
    const pairs = try parsed.pairs(&pair_buf);
    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqualStrings("name", pairs[0].key);
    try testing.expectEqualStrings("zig", pairs[0].value);
    try testing.expectEqualStrings("version", pairs[1].key);
    try testing.expectEqualStrings("1", pairs[1].value);
}

// ── prettyPrint ─────────────────────────────────────────────────────────

test "prettyPrint: known pairs produce expected output" {
    var buf: [64]u8 = undefined;
    const parsed = try sig_parse.parseInto("name=zig\nversion=1\n", &buf);
    var pair_buf: [4]sig_parse.KvPair = undefined;
    const pairs = try parsed.pairs(&pair_buf);

    var pp_buf: [64]u8 = undefined;
    const output = try sig_parse.prettyPrint(pairs, &pp_buf);
    try testing.expectEqualStrings("name=zig\nversion=1\n", output);
}

// ── StreamingParser ─────────────────────────────────────────────────────

test "StreamingParser: feed with valid input produces correct tokens" {
    var parser = sig_parse.StreamingParser(sig_parse.KvPair).init();
    var token_buf: [4]sig_parse.KvPair = undefined;
    const result = parser.feed("name=zig\nversion=1\n", &token_buf);
    const tokens = result.ok;
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqualStrings("name", tokens[0].key);
    try testing.expectEqualStrings("zig", tokens[0].value);
    try testing.expectEqualStrings("version", tokens[1].key);
    try testing.expectEqualStrings("1", tokens[1].value);
}

test "StreamingParser: feed with invalid input returns parse error with byte offset" {
    var parser = sig_parse.StreamingParser(sig_parse.KvPair).init();
    var token_buf: [4]sig_parse.KvPair = undefined;
    const result = parser.feed("badline\n", &token_buf);
    switch (result) {
        .err => |info| {
            try testing.expectEqual(@as(usize, 0), info.byte_offset);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "StreamingParser: finish flushes partial line" {
    var parser = sig_parse.StreamingParser(sig_parse.KvPair).init();
    var token_buf: [4]sig_parse.KvPair = undefined;

    // Feed input without trailing newline — data stays partial.
    const feed_result = parser.feed("key=val", &token_buf);
    try testing.expectEqual(@as(usize, 0), feed_result.ok.len);

    // finish should flush the partial line.
    const finish_result = parser.finish(&token_buf);
    const tokens = finish_result.ok;
    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expectEqualStrings("key", tokens[0].key);
    try testing.expectEqualStrings("val", tokens[0].value);
}

// ── measureParse ────────────────────────────────────────────────────────

test "measureParse: returns input length" {
    const input = "name=zig\nversion=1\n";
    try testing.expectEqual(input.len, sig_parse.measureParse(input));
}
