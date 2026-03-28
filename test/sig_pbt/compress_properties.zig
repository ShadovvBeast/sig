// Feature: sig-memory-model, Property 28: Compress-then-decompress round trip
//
// For any byte sequence, compressing it and then decompressing the result
// shall produce the original bytes. Tested for deflate and gzip formats.
//
// **Validates: Requirements 17.1, 17.2, 17.3**

const std = @import("std");
const harness = @import("harness");
const sig_compress = @import("sig_compress");

// ---------------------------------------------------------------------------
// Property 28 – Compress-then-decompress round trip (deflate)
// ---------------------------------------------------------------------------

test "Property 28: deflate compress-then-decompress round trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random input data (1..256 bytes).
            var input_buf: [256]u8 = undefined;
            const input_len = 1 + random.uintAtMost(usize, 255);
            for (input_buf[0..input_len]) |*b| b.* = random.int(u8);
            const input = input_buf[0..input_len];

            // Compress.
            var compressed_buf: [4096]u8 = undefined;
            const compressed = sig_compress.compress(.deflate, input, &compressed_buf) catch |err| {
                // BufferTooSmall is acceptable for very incompressible data.
                try std.testing.expectEqual(error.BufferTooSmall, err);
                return;
            };

            // Decompress.
            var decompressed_buf: [256]u8 = undefined;
            const decompressed = try sig_compress.decompress(.deflate, compressed, &decompressed_buf);

            try std.testing.expectEqualSlices(u8, input, decompressed);
        }
    };
    harness.property("deflate compress-then-decompress round trip", S.run);
}

// ---------------------------------------------------------------------------
// Property 28 – Compress-then-decompress round trip (gzip)
// ---------------------------------------------------------------------------

test "Property 28: gzip compress-then-decompress round trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var input_buf: [256]u8 = undefined;
            const input_len = 1 + random.uintAtMost(usize, 255);
            for (input_buf[0..input_len]) |*b| b.* = random.int(u8);
            const input = input_buf[0..input_len];

            var compressed_buf: [4096]u8 = undefined;
            const compressed = sig_compress.compress(.gzip, input, &compressed_buf) catch |err| {
                try std.testing.expectEqual(error.BufferTooSmall, err);
                return;
            };

            var decompressed_buf: [256]u8 = undefined;
            const decompressed = try sig_compress.decompress(.gzip, compressed, &decompressed_buf);

            try std.testing.expectEqualSlices(u8, input, decompressed);
        }
    };
    harness.property("gzip compress-then-decompress round trip", S.run);
}

// ---------------------------------------------------------------------------
// Property 28 – BufferTooSmall on undersized decompression buffer
// ---------------------------------------------------------------------------

test "Property 28: decompress returns BufferTooSmall for undersized output" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const input = "hello world, this is a test of compression round trip";

            var compressed_buf: [4096]u8 = undefined;
            const compressed = try sig_compress.compress(.deflate, input, &compressed_buf);

            // Use a buffer too small for the decompressed output.
            var tiny_buf: [4]u8 = undefined;
            try std.testing.expectError(
                error.BufferTooSmall,
                sig_compress.decompress(.deflate, compressed, &tiny_buf),
            );
        }
    };
    harness.property("decompress returns BufferTooSmall for undersized output", S.run);
}
