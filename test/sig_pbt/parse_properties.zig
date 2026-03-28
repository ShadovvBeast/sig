// Feature: sig-memory-model, Property 9: Parser measure-then-parse round trip
//
// For any valid input, calling measureParse to obtain size n, then calling
// parseInto with a buffer of size n, shall succeed. Calling parseInto with
// a buffer of size < n shall return error.BufferTooSmall.
//
// **Validates: Requirements 6.2, 6.3, 6.4**

const std = @import("std");
const harness = @import("harness");
const sig_parse = @import("sig_parse");

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Characters allowed in keys and values (printable ASCII excluding '=', '\n').
const alphanum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// Generates a random alphanumeric string of length 1..max_len into `buf`.
/// Returns the filled slice.
fn randomAlphaNum(random: std.Random, buf: []u8, max_len: usize) []u8 {
    if (max_len == 0) return buf[0..0];
    const len = 1 + random.uintAtMost(usize, max_len - 1);
    for (buf[0..len]) |*c| {
        c.* = alphanum[random.uintAtMost(usize, alphanum.len - 1)];
    }
    return buf[0..len];
}

/// Builds a valid KV input string ("key=value\n" lines) into `out_buf`.
/// Returns the filled slice.
fn generateKvInput(random: std.Random, out_buf: []u8) []u8 {
    const max_pairs = 1 + random.uintAtMost(usize, 5); // 1–6 pairs
    var offset: usize = 0;

    for (0..max_pairs) |_| {
        var key_buf: [16]u8 = undefined;
        var val_buf: [16]u8 = undefined;
        const key = randomAlphaNum(random, &key_buf, 12);
        const value = randomAlphaNum(random, &val_buf, 12);

        // "key=value\n" — check we have room
        const line_len = key.len + 1 + value.len + 1; // +1 for '=', +1 for '\n'
        if (offset + line_len > out_buf.len) break;

        @memcpy(out_buf[offset..][0..key.len], key);
        offset += key.len;
        out_buf[offset] = '=';
        offset += 1;
        @memcpy(out_buf[offset..][0..value.len], value);
        offset += value.len;
        out_buf[offset] = '\n';
        offset += 1;
    }

    return out_buf[0..offset];
}

// ---------------------------------------------------------------------------
// Property 9 – measure-then-parse round trip: success with exact buffer
// ---------------------------------------------------------------------------

test "Property 9: measureParse then parseInto with exact buffer succeeds" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var input_buf: [256]u8 = undefined;
            const input = generateKvInput(random, &input_buf);

            // Measure required size.
            const n = sig_parse.measureParse(input);

            // parseInto with a buffer of exactly n bytes must succeed.
            var parse_buf: [256]u8 = undefined;
            const result = try sig_parse.parseInto(input, parse_buf[0..n]);

            // The parsed data slice must be byte-identical to the input.
            try std.testing.expectEqualSlices(u8, input, result.data);
        }
    };
    harness.property("measureParse then parseInto with exact buffer succeeds", S.run);
}

// ---------------------------------------------------------------------------
// Property 9 – measure-then-parse round trip: success with oversized buffer
// ---------------------------------------------------------------------------

test "Property 9: measureParse then parseInto with oversized buffer succeeds" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var input_buf: [256]u8 = undefined;
            const input = generateKvInput(random, &input_buf);

            const n = sig_parse.measureParse(input);

            // parseInto with a buffer larger than n must also succeed.
            var parse_buf: [512]u8 = undefined;
            const extra = random.uintAtMost(usize, 256);
            const buf_size = n + extra;
            const result = try sig_parse.parseInto(input, parse_buf[0..buf_size]);

            try std.testing.expectEqualSlices(u8, input, result.data);
        }
    };
    harness.property("measureParse then parseInto with oversized buffer succeeds", S.run);
}

// ---------------------------------------------------------------------------
// Property 9 – measure-then-parse round trip: undersized buffer returns error
// ---------------------------------------------------------------------------

test "Property 9: parseInto with undersized buffer returns BufferTooSmall" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var input_buf: [256]u8 = undefined;
            const input = generateKvInput(random, &input_buf);

            const n = sig_parse.measureParse(input);

            // Skip if n == 0 — an empty input needs 0 bytes, so there is no
            // strictly smaller valid buffer size.
            if (n == 0) return;

            // Pick a buffer size in [0, n-1].
            const small = random.uintAtMost(usize, n - 1);
            var parse_buf: [256]u8 = undefined;

            try std.testing.expectError(
                error.BufferTooSmall,
                sig_parse.parseInto(input, parse_buf[0..small]),
            );
        }
    };
    harness.property("parseInto with undersized buffer returns BufferTooSmall", S.run);
}

// ---------------------------------------------------------------------------
// Property 10 – Parse-then-pretty-print round trip
//
// For any valid input, parsing the input and then pretty-printing the parsed
// result and then parsing the pretty-printed output shall produce an
// equivalent parsed structure.
//
// **Validates: Requirements 6.6, 6.7**
// ---------------------------------------------------------------------------

test "Property 10: parse then pretty-print then re-parse produces equivalent pairs" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // 1. Generate random valid KV input.
            var input_buf: [256]u8 = undefined;
            const input = generateKvInput(random, &input_buf);

            // 2. Parse the input.
            var parse_buf1: [256]u8 = undefined;
            const parsed1 = try sig_parse.parseInto(input, &parse_buf1);

            // 3. Extract pairs from the first parse.
            var pair_buf1: [16]sig_parse.KvPair = undefined;
            const pairs1 = try parsed1.pairs(&pair_buf1);

            // 4. Pretty-print the pairs.
            var pp_buf: [512]u8 = undefined;
            const pp_output = try sig_parse.prettyPrint(pairs1, &pp_buf);

            // 5. Parse the pretty-printed output.
            var parse_buf2: [512]u8 = undefined;
            const parsed2 = try sig_parse.parseInto(pp_output, &parse_buf2);

            // 6. Extract pairs from the second parse.
            var pair_buf2: [16]sig_parse.KvPair = undefined;
            const pairs2 = try parsed2.pairs(&pair_buf2);

            // 7. Verify equivalence: same number of pairs, same keys and values.
            try std.testing.expectEqual(pairs1.len, pairs2.len);
            for (pairs1, pairs2) |p1, p2| {
                try std.testing.expectEqualSlices(u8, p1.key, p2.key);
                try std.testing.expectEqualSlices(u8, p1.value, p2.value);
            }
        }
    };
    harness.property("parse then pretty-print then re-parse produces equivalent pairs", S.run);
}

// ---------------------------------------------------------------------------
// Property 11 – Parse error includes byte offset
//
// For any input containing a syntax error, the parser shall return an error
// value that includes the byte offset of the first error location, and that
// offset shall be within the bounds of the input.
//
// **Validates: Requirements 6.5**
// ---------------------------------------------------------------------------

/// Generates a random invalid line (no '=' character) of length 1..max_len.
fn randomInvalidLine(random: std.Random, buf: []u8, max_len: usize) []u8 {
    if (max_len == 0) return buf[0..0];
    const len = 1 + random.uintAtMost(usize, max_len - 1);
    // Fill with alphanumeric chars only (no '=' or '\n').
    for (buf[0..len]) |*c| {
        c.* = alphanum[random.uintAtMost(usize, alphanum.len - 1)];
    }
    return buf[0..len];
}

test "Property 11: parse error includes byte offset within input bounds" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Build input: 0..3 valid "key=value\n" lines followed by one
            // invalid line (no '=') terminated with '\n'.
            var input_buf: [512]u8 = undefined;
            var offset: usize = 0;

            // Number of valid prefix lines (0–3).
            const valid_count = random.uintAtMost(usize, 3);
            var expected_error_offset: usize = 0;

            for (0..valid_count) |_| {
                var key_buf: [12]u8 = undefined;
                var val_buf: [12]u8 = undefined;
                const key = randomAlphaNum(random, &key_buf, 10);
                const value = randomAlphaNum(random, &val_buf, 10);
                const line_len = key.len + 1 + value.len + 1;
                if (offset + line_len > input_buf.len - 20) break; // leave room for invalid line
                @memcpy(input_buf[offset..][0..key.len], key);
                offset += key.len;
                input_buf[offset] = '=';
                offset += 1;
                @memcpy(input_buf[offset..][0..value.len], value);
                offset += value.len;
                input_buf[offset] = '\n';
                offset += 1;
            }

            // Record where the invalid line starts — this is the expected
            // error byte offset.
            expected_error_offset = offset;

            // Append an invalid line (no '=') terminated by '\n'.
            var bad_buf: [16]u8 = undefined;
            const bad_line = randomInvalidLine(random, &bad_buf, 14);
            if (bad_line.len == 0) return; // skip degenerate case
            @memcpy(input_buf[offset..][0..bad_line.len], bad_line);
            offset += bad_line.len;
            input_buf[offset] = '\n';
            offset += 1;

            const input = input_buf[0..offset];

            // Feed the entire input to a fresh StreamingParser.
            var parser = sig_parse.StreamingParser(sig_parse.KvPair).init();
            var token_buf: [16]sig_parse.KvPair = undefined;
            const result = parser.feed(input, &token_buf);

            // The result must be .err (parse error), not .ok or .err_sig.
            switch (result) {
                .err => |info| {
                    // byte_offset must be within the input bounds.
                    try std.testing.expect(info.byte_offset < input.len);
                    // byte_offset should point to the start of the bad line.
                    try std.testing.expectEqual(expected_error_offset, info.byte_offset);
                    // message must be non-empty.
                    try std.testing.expect(info.message.len > 0);
                },
                .ok => return error.TestUnexpectedResult,
                .err_sig => return error.TestUnexpectedResult,
            }
        }
    };
    harness.property("parse error includes byte offset within input bounds", S.run);
}
