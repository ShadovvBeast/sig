// Feature: sig-memory-model, Property 1: Format measure-then-write round trip
//
// For any valid format string and format arguments, calling measureFormat to
// obtain the required size n, then calling formatInto with a buffer of exactly
// n bytes, shall succeed without error and produce the same output as calling
// formatInto with any buffer of size >= n.
//
// **Validates: Requirements 2.2, 2.3, 2.5**

const std = @import("std");
const harness = @import("harness");
const sig_fmt = @import("fmt");

// ---------------------------------------------------------------------------
// Property 1 – measure-then-write round trip
// ---------------------------------------------------------------------------

test "Property 1: format measure-then-write round trip (decimal)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const value = harness.randomInt(random, i64);

            // 1. Measure the exact size needed.
            const n = sig_fmt.measureFormat("{d}", .{value});

            // 2. formatInto with a buffer of exactly n bytes must succeed.
            var exact_buf: [128]u8 = undefined;
            const exact_result = try sig_fmt.formatInto(exact_buf[0..n], "{d}", .{value});

            // 3. formatInto with a larger buffer must also succeed.
            const large_result = try sig_fmt.formatInto(&exact_buf, "{d}", .{value});

            // 4. Both outputs must be byte-identical.
            try std.testing.expectEqualStrings(exact_result, large_result);

            // 5. The exact-buffer result length must equal n.
            try std.testing.expectEqual(n, exact_result.len);
        }
    };
    harness.property("format measure-then-write round trip (decimal)", S.run);
}

test "Property 1: format measure-then-write round trip (hex)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const value = harness.randomInt(random, u64);

            const n = sig_fmt.measureFormat("{x}", .{value});

            var exact_buf: [128]u8 = undefined;
            const exact_result = try sig_fmt.formatInto(exact_buf[0..n], "{x}", .{value});

            const large_result = try sig_fmt.formatInto(&exact_buf, "{x}", .{value});

            try std.testing.expectEqualStrings(exact_result, large_result);
            try std.testing.expectEqual(n, exact_result.len);
        }
    };
    harness.property("format measure-then-write round trip (hex)", S.run);
}

test "Property 1: format measure-then-write round trip (string + int)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const int_val = harness.randomInt(random, i32);

            // Use a composite format string with a fixed prefix and a random int.
            const n = sig_fmt.measureFormat("value={d}", .{int_val});

            var exact_buf: [128]u8 = undefined;
            const exact_result = try sig_fmt.formatInto(exact_buf[0..n], "value={d}", .{int_val});

            const large_result = try sig_fmt.formatInto(&exact_buf, "value={d}", .{int_val});

            try std.testing.expectEqualStrings(exact_result, large_result);
            try std.testing.expectEqual(n, exact_result.len);
        }
    };
    harness.property("format measure-then-write round trip (string + int)", S.run);
}

// ---------------------------------------------------------------------------
// Feature: sig-memory-model, Property 2: Format BufferTooSmall on undersized buffer
//
// For any valid format string and format arguments where measureFormat returns
// size n > 0, calling formatInto with a buffer of size < n shall return
// error.BufferTooSmall.
//
// **Validates: Requirements 2.4**
// ---------------------------------------------------------------------------

test "Property 2: formatInto returns BufferTooSmall on undersized buffer (decimal)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const value = harness.randomInt(random, i64);

            const n = sig_fmt.measureFormat("{d}", .{value});
            if (n == 0) return; // skip trivial case

            // Pick a random undersized length in 0..n-1.
            const undersized_len = random.uintLessThan(usize, n);

            var buf: [128]u8 = undefined;
            try std.testing.expectError(
                error.BufferTooSmall,
                sig_fmt.formatInto(buf[0..undersized_len], "{d}", .{value}),
            );
        }
    };
    harness.property("formatInto returns BufferTooSmall on undersized buffer (decimal)", S.run);
}

test "Property 2: formatInto returns BufferTooSmall on undersized buffer (hex)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const value = harness.randomInt(random, u64);

            const n = sig_fmt.measureFormat("{x}", .{value});
            if (n == 0) return;

            const undersized_len = random.uintLessThan(usize, n);

            var buf: [128]u8 = undefined;
            try std.testing.expectError(
                error.BufferTooSmall,
                sig_fmt.formatInto(buf[0..undersized_len], "{x}", .{value}),
            );
        }
    };
    harness.property("formatInto returns BufferTooSmall on undersized buffer (hex)", S.run);
}

test "Property 2: formatInto returns BufferTooSmall on undersized buffer (string + int)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const int_val = harness.randomInt(random, i32);

            const n = sig_fmt.measureFormat("value={d}", .{int_val});
            if (n == 0) return;

            const undersized_len = random.uintLessThan(usize, n);

            var buf: [128]u8 = undefined;
            try std.testing.expectError(
                error.BufferTooSmall,
                sig_fmt.formatInto(buf[0..undersized_len], "value={d}", .{int_val}),
            );
        }
    };
    harness.property("formatInto returns BufferTooSmall on undersized buffer (string + int)", S.run);
}
