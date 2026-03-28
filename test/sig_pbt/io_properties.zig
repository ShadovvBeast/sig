// Feature: sig-memory-model, Property 3: readInto returns correct byte count and errors on overflow
//
// For any data source of size s and caller-provided buffer of size b,
// readInto shall return a slice of length min(s, b) when s <= b, and
// shall return error.BufferTooSmall when s > b.
//
// **Validates: Requirements 3.1, 3.3**

const std = @import("std");
const harness = @import("harness");
const sig_io = @import("sig_io");

/// A minimal reader backed by a byte slice. Provides the `.read(buf)` method
/// that sig_io.readInto expects via its `anytype` reader parameter.
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

// ---------------------------------------------------------------------------
// Property 3 – readInto returns correct byte count and errors on overflow
// ---------------------------------------------------------------------------

test "Property 3: readInto returns correct slice when source fits in buffer" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random data of random size s (0..256).
            var data_buf: [256]u8 = undefined;
            const data = harness.randomBytes(random, &data_buf);
            const s = data.len;

            // Create a buffer of size b >= s so the data fits.
            // b is in range [s .. s+256], capped at 512.
            const extra = random.uintAtMost(usize, 256);
            const b = @min(s + extra, 512);
            var read_buf: [512]u8 = undefined;

            var reader = SliceReader{ .data = data };
            const result = try sig_io.readInto(&reader, read_buf[0..b]);

            // Result length must equal s (all source bytes read).
            try std.testing.expectEqual(s, result.len);

            // Result content must match the source data.
            try std.testing.expectEqualSlices(u8, data, result);
        }
    };
    harness.property("readInto returns correct slice when source fits in buffer", S.run);
}

test "Property 3: readInto returns BufferTooSmall when source exceeds buffer" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random data of size s >= 2 so we can make b < s.
            var data_buf: [256]u8 = undefined;
            const min_s: usize = 2;
            const s = min_s + random.uintAtMost(usize, data_buf.len - min_s);
            random.bytes(data_buf[0..s]);
            const data = data_buf[0..s];

            // Buffer size b is strictly less than s.
            const b = random.uintAtMost(usize, s - 1);
            var read_buf: [256]u8 = undefined;

            var reader = SliceReader{ .data = data };
            try std.testing.expectError(
                error.BufferTooSmall,
                sig_io.readInto(&reader, read_buf[0..b]),
            );
        }
    };
    harness.property("readInto returns BufferTooSmall when source exceeds buffer", S.run);
}

test "Property 3: readInto with exact-size buffer returns all bytes" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random data of random size s (0..256).
            var data_buf: [256]u8 = undefined;
            const data = harness.randomBytes(random, &data_buf);
            const s = data.len;

            // Buffer is exactly the size of the data.
            var read_buf: [256]u8 = undefined;

            var reader = SliceReader{ .data = data };
            const result = try sig_io.readInto(&reader, read_buf[0..s]);

            // Result length must equal s.
            try std.testing.expectEqual(s, result.len);

            // Content must match.
            try std.testing.expectEqualSlices(u8, data, result);
        }
    };
    harness.property("readInto with exact-size buffer returns all bytes", S.run);
}

// ---------------------------------------------------------------------------
// Feature: sig-memory-model, Property 4: readAtMost respects caller-specified limit
//
// For any data source and caller-specified max_bytes value with a buffer of
// size >= max_bytes, readAtMost shall return a slice of length <= max_bytes.
//
// **Validates: Requirements 3.2**
// ---------------------------------------------------------------------------

test "Property 4: readAtMost returns slice of length <= max_bytes" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random source data of random size (0..256).
            var data_buf: [256]u8 = undefined;
            const data = harness.randomBytes(random, &data_buf);

            // Pick a random max_bytes value in 0..512.
            const max_bytes = random.uintAtMost(usize, 512);

            // Create a buffer of size >= max_bytes (use 512 which is always >= max_bytes).
            var read_buf: [512]u8 = undefined;

            var reader = SliceReader{ .data = data };
            const result = try sig_io.readAtMost(&reader, read_buf[0..@max(max_bytes, 1)], max_bytes);

            // Result length must be <= max_bytes.
            try std.testing.expect(result.len <= max_bytes);

            // Result length must also be <= source data size (can't read more than exists).
            try std.testing.expect(result.len <= data.len);
        }
    };
    harness.property("readAtMost returns slice of length <= max_bytes", S.run);
}

test "Property 4: readAtMost result matches source prefix" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random source data of random size (1..256).
            var data_buf: [256]u8 = undefined;
            const data = harness.randomBytes(random, &data_buf);
            if (data.len == 0) return; // skip empty source

            // Pick a random max_bytes in 1..512.
            const max_bytes = 1 + random.uintAtMost(usize, 511);

            var read_buf: [512]u8 = undefined;

            var reader = SliceReader{ .data = data };
            const result = try sig_io.readAtMost(&reader, &read_buf, max_bytes);

            // The expected read length is min(data.len, max_bytes).
            const expected_len = @min(data.len, max_bytes);
            try std.testing.expectEqual(expected_len, result.len);

            // The returned bytes must match the source prefix.
            try std.testing.expectEqualSlices(u8, data[0..expected_len], result);
        }
    };
    harness.property("readAtMost result matches source prefix", S.run);
}

test "Property 4: readAtMost with max_bytes zero returns empty slice" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random source data.
            var data_buf: [256]u8 = undefined;
            const data = harness.randomBytes(random, &data_buf);

            // max_bytes = 0 means read nothing.
            var read_buf: [1]u8 = undefined;

            var reader = SliceReader{ .data = data };
            const result = try sig_io.readAtMost(&reader, &read_buf, 0);

            try std.testing.expectEqual(@as(usize, 0), result.len);
        }
    };
    harness.property("readAtMost with max_bytes zero returns empty slice", S.run);
}

// ---------------------------------------------------------------------------
// Feature: sig-memory-model, Property 5: Streaming interface bounded RAM invariant
//
// For any StreamReader(chunk_size) processing a data source of arbitrary size,
// the reader's internal buffer shall be exactly chunk_size bytes, and each call
// to next shall return a slice of length <= chunk_size.
//
// **Validates: Requirements 3.4, 3.5**
// ---------------------------------------------------------------------------

test "Property 5: StreamReader buffer is exactly chunk_size and next returns <= chunk_size slices" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const chunk_size = 64;

            // Generate random data of random size (0..1024).
            var data_buf: [1024]u8 = undefined;
            const data = harness.randomBytes(random, &data_buf);

            var reader = SliceReader{ .data = data };
            var stream = sig_io.StreamReader(chunk_size){};

            // Verify the internal buffer is exactly chunk_size bytes.
            try std.testing.expectEqual(chunk_size, stream.buf.len);

            var total_bytes: usize = 0;
            while (stream.next(&reader)) |chunk| {
                // Each returned slice must have length <= chunk_size.
                try std.testing.expect(chunk.len <= chunk_size);
                // Each returned slice must be non-empty (next returns null for EOF).
                try std.testing.expect(chunk.len > 0);
                total_bytes += chunk.len;
            }

            // Total bytes read must equal the source data size.
            try std.testing.expectEqual(data.len, total_bytes);
        }
    };
    harness.property("StreamReader buffer is exactly chunk_size and next returns <= chunk_size slices", S.run);
}
