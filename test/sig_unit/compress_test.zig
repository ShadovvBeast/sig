// Unit tests for lib/sig/compress.zig
// Requirements: 17.1, 17.2, 17.3

const std = @import("std");
const testing = std.testing;
const sig_compress = @import("sig_compress");

test "deflate compress and decompress 'hello world'" {
    const input = "hello world";
    var compressed_buf: [256]u8 = undefined;
    const compressed = try sig_compress.compress(.deflate, input, &compressed_buf);
    try testing.expect(compressed.len > 0);

    var decompressed_buf: [256]u8 = undefined;
    const decompressed = try sig_compress.decompress(.deflate, compressed, &decompressed_buf);
    try testing.expectEqualStrings(input, decompressed);
}

test "gzip compress and decompress 'hello world'" {
    const input = "hello world";
    var compressed_buf: [256]u8 = undefined;
    const compressed = try sig_compress.compress(.gzip, input, &compressed_buf);
    try testing.expect(compressed.len > 0);

    var decompressed_buf: [256]u8 = undefined;
    const decompressed = try sig_compress.decompress(.gzip, compressed, &decompressed_buf);
    try testing.expectEqualStrings(input, decompressed);
}

test "deflate compress empty input" {
    const input = "";
    var compressed_buf: [256]u8 = undefined;
    const compressed = try sig_compress.compress(.deflate, input, &compressed_buf);

    var decompressed_buf: [256]u8 = undefined;
    const decompressed = try sig_compress.decompress(.deflate, compressed, &decompressed_buf);
    try testing.expectEqual(@as(usize, 0), decompressed.len);
}

test "decompress returns BufferTooSmall for undersized buffer" {
    const input = "this is a longer string that needs more space when decompressed";
    var compressed_buf: [256]u8 = undefined;
    const compressed = try sig_compress.compress(.deflate, input, &compressed_buf);

    var tiny_buf: [4]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, sig_compress.decompress(.deflate, compressed, &tiny_buf));
}

test "Decompressor struct feed works" {
    const input = "test data";
    var compressed_buf: [256]u8 = undefined;
    const compressed = try sig_compress.compress(.deflate, input, &compressed_buf);

    var d = sig_compress.Decompressor(.deflate){};
    var out_buf: [256]u8 = undefined;
    const result = try d.feed(compressed, &out_buf);
    try testing.expectEqualStrings(input, result);
}

test "Compressor struct feed works" {
    var c = sig_compress.Compressor(.gzip){};
    var out_buf: [256]u8 = undefined;
    const compressed = try c.feed("hello", &out_buf);
    try testing.expect(compressed.len > 0);
}
