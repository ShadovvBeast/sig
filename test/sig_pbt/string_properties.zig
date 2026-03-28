// Feature: sig-memory-model, Property 7: String buffer round trip
//
// For any valid byte sequence, writing it into a caller-provided buffer via
// Sig string operations and reading the resulting slice back shall produce a
// byte-identical result.
//
// **Validates: Requirements 5.1, 5.4**

const std = @import("std");
const harness = @import("harness");
const sig_string = @import("sig_string");

// ---------------------------------------------------------------------------
// Property 7 – String buffer round trip (concat)
// ---------------------------------------------------------------------------

test "Property 7: concat single slice round trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate a random byte sequence.
            var data_buf: [256]u8 = undefined;
            const data = harness.randomBytes(random, &data_buf);

            // Write it into a buffer via concat and read back.
            var out_buf: [256]u8 = undefined;
            const slices: []const []const u8 = &.{data};
            const result = try sig_string.concat(&out_buf, slices);

            // The result must be byte-identical to the original data.
            try std.testing.expectEqualSlices(u8, data, result);
        }
    };
    harness.property("concat single slice round trip", S.run);
}

test "Property 7: concat multiple slices round trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate 2-4 random byte slices whose total length fits in 256 bytes.
            var buf_a: [64]u8 = undefined;
            var buf_b: [64]u8 = undefined;
            var buf_c: [64]u8 = undefined;

            const a = harness.randomBytes(random, &buf_a);
            const b = harness.randomBytes(random, &buf_b);
            const c = harness.randomBytes(random, &buf_c);

            // Build expected concatenation manually.
            var expected_buf: [192]u8 = undefined;
            @memcpy(expected_buf[0..a.len], a);
            @memcpy(expected_buf[a.len..][0..b.len], b);
            @memcpy(expected_buf[a.len + b.len ..][0..c.len], c);
            const expected = expected_buf[0 .. a.len + b.len + c.len];

            // Write via concat.
            var out_buf: [192]u8 = undefined;
            const slices: []const []const u8 = &.{ a, b, c };
            const result = try sig_string.concat(&out_buf, slices);

            // Result must be byte-identical to the manual concatenation.
            try std.testing.expectEqualSlices(u8, expected, result);
        }
    };
    harness.property("concat multiple slices round trip", S.run);
}

test "Property 7: concat empty slices round trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Mix empty and non-empty slices.
            var buf_a: [64]u8 = undefined;
            const a = harness.randomBytes(random, &buf_a);
            const empty: []const u8 = "";

            var out_buf: [64]u8 = undefined;
            const slices: []const []const u8 = &.{ empty, a, empty };
            const result = try sig_string.concat(&out_buf, slices);

            // Result must equal just the non-empty slice.
            try std.testing.expectEqualSlices(u8, a, result);
        }
    };
    harness.property("concat empty slices round trip", S.run);
}

// ---------------------------------------------------------------------------
// Property 7 – String buffer round trip (replace with identity)
// ---------------------------------------------------------------------------

test "Property 7: replace with identity replacement produces same output" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate a random haystack.
            var haystack_buf: [128]u8 = undefined;
            const haystack = harness.randomBytes(random, &haystack_buf);

            // Pick a single random byte as the needle.
            const needle_byte = random.int(u8);
            const needle: []const u8 = &.{needle_byte};

            // Replace needle with itself (identity replacement).
            var out_buf: [128]u8 = undefined;
            const result = try sig_string.replace(&out_buf, haystack, needle, needle);

            // The result must be byte-identical to the original haystack.
            try std.testing.expectEqualSlices(u8, haystack, result);
        }
    };
    harness.property("replace with identity replacement produces same output", S.run);
}

test "Property 7: replace with empty needle copies haystack verbatim" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate a random haystack.
            var haystack_buf: [128]u8 = undefined;
            const haystack = harness.randomBytes(random, &haystack_buf);

            // Empty needle means no replacements — output should equal input.
            var out_buf: [128]u8 = undefined;
            const result = try sig_string.replace(&out_buf, haystack, "", "anything");

            try std.testing.expectEqualSlices(u8, haystack, result);
        }
    };
    harness.property("replace with empty needle copies haystack verbatim", S.run);
}

// ---------------------------------------------------------------------------
// Property 8 – SegmentedString append and extract
//
// For any sequence of byte slices appended to a SegmentedString, calling
// toSlice into a sufficiently large buffer shall produce the concatenation
// of all appended slices. If the total data exceeds the segmented string's
// capacity, append shall return error.CapacityExceeded.
//
// **Validates: Requirements 5.2, 5.3**
// ---------------------------------------------------------------------------

test "Property 8: SegmentedString append then toSlice reproduces concatenation" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const SegStr = sig_string.SegmentedString(4, 32); // 4 chunks × 32 bytes = 128 bytes capacity
            var ss = SegStr{};

            // Track expected concatenation manually.
            var expected_buf: [128]u8 = undefined;
            var expected_len: usize = 0;

            // Generate 1–6 random slices and append them.
            const num_slices = 1 + random.uintAtMost(usize, 5);
            for (0..num_slices) |_| {
                // Each slice is at most 24 bytes so we can fit several before overflow.
                var slice_buf: [24]u8 = undefined;
                const slice = harness.randomBytes(random, &slice_buf);

                if (expected_len + slice.len > 128) {
                    // Should exceed capacity — stop appending.
                    break;
                }

                try ss.append(slice);
                @memcpy(expected_buf[expected_len..][0..slice.len], slice);
                expected_len += slice.len;
            }

            // Extract via toSlice and compare.
            var out_buf: [128]u8 = undefined;
            const result = try ss.toSlice(&out_buf);
            try std.testing.expectEqualSlices(u8, expected_buf[0..expected_len], result);
        }
    };
    harness.property("SegmentedString append then toSlice reproduces concatenation", S.run);
}

test "Property 8: SegmentedString append returns CapacityExceeded on overflow" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const chunk_count = 4;
            const chunk_size = 32;
            const capacity = chunk_count * chunk_size; // 128 bytes
            const SegStr = sig_string.SegmentedString(chunk_count, chunk_size);
            var ss = SegStr{};

            var total_requested: usize = 0;
            var overflowed = false;

            // Keep appending until we exceed capacity.
            for (0..20) |_| {
                // Generate slices of 8–32 bytes to ensure we eventually overflow.
                var slice_buf: [32]u8 = undefined;
                const len = 8 + random.uintAtMost(usize, 24);
                random.bytes(slice_buf[0..len]);
                const slice = slice_buf[0..len];

                total_requested += slice.len;

                const result = ss.append(slice);
                if (result) |_| {
                    // ok
                } else |err| {
                    try std.testing.expectEqual(error.CapacityExceeded, err);
                    overflowed = true;
                    break;
                }
            }

            // With 20 iterations of 8–32 byte slices against 128 byte capacity,
            // we should always overflow.
            try std.testing.expect(overflowed);

            // The total requested data must have exceeded capacity.
            try std.testing.expect(total_requested > capacity);

            // toSlice should still succeed and return data <= capacity.
            var out_buf: [128]u8 = undefined;
            const result = try ss.toSlice(&out_buf);
            try std.testing.expect(result.len <= capacity);
            try std.testing.expect(result.len > 0);
        }
    };
    harness.property("SegmentedString append returns CapacityExceeded on overflow", S.run);
}

test "Property 8: SegmentedString empty produces empty slice" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const SegStr = sig_string.SegmentedString(4, 32);
            var ss = SegStr{};

            var out_buf: [128]u8 = undefined;
            const result = try ss.toSlice(&out_buf);
            try std.testing.expectEqual(@as(usize, 0), result.len);
        }
    };
    harness.property("SegmentedString empty produces empty slice", S.run);
}
