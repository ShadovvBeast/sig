//! Capacity-first streaming compression and decompression.
//!
//! All operations use caller-provided buffers. No allocator parameters.
//! Wraps Zig's `std.compress.flate` with the Sig error model.
//!
//! Supported formats:
//! - deflate: raw deflate (compress + decompress)
//! - gzip: gzip-wrapped deflate (compress + decompress)
//! - zstd: Zstandard (decompress only — Zig std does not provide zstd compression)

const std = @import("std");
const SigError = @import("errors.zig").SigError;

pub const Format = enum { deflate, gzip, zstd };

/// Streaming decompressor. Reads compressed input and writes decompressed
/// output into caller-provided buffers.
pub fn Decompressor(comptime format: Format) type {
    return struct {
        finished: bool = false,

        const Self = @This();

        /// Feed compressed input and write decompressed output into `output`.
        /// Returns the slice of decompressed bytes written.
        /// Returns `BufferTooSmall` if the output buffer cannot hold the result.
        pub fn feed(self: *Self, input: []const u8, output: []u8) SigError![]u8 {
            _ = self;
            return decompressImpl(format, input, output);
        }

        /// Signal end of input. No-op for single-shot usage.
        pub fn finish(self: *Self, output: []u8) SigError![]u8 {
            self.finished = true;
            return output[0..0];
        }
    };
}

/// Streaming compressor (deflate and gzip only).
pub fn Compressor(comptime format: Format) type {
    if (format == .zstd) @compileError("zstd compression not available in Zig std");
    return struct {
        finished: bool = false,

        const Self = @This();

        /// Feed uncompressed input and write compressed output into `output`.
        pub fn feed(self: *Self, input: []const u8, output: []u8) SigError![]u8 {
            _ = self;
            return compressImpl(format, input, output);
        }

        /// Signal end of input. No-op for single-shot usage.
        pub fn finish(self: *Self, output: []u8) SigError![]u8 {
            self.finished = true;
            return output[0..0];
        }
    };
}

/// One-shot decompress: decompress `input` into `output`.
pub fn decompress(comptime format: Format, input: []const u8, output: []u8) SigError![]u8 {
    return decompressImpl(format, input, output);
}

/// One-shot compress: compress `input` into `output` (deflate/gzip only).
pub fn compress(comptime format: Format, input: []const u8, output: []u8) SigError![]u8 {
    return compressImpl(format, input, output);
}

// ── Internal helpers ─────────────────────────────────────────────────────

fn readAllFromReader(reader: *std.Io.Reader, output: []u8) SigError![]u8 {
    var total: usize = 0;
    while (total < output.len) {
        const n = reader.readSliceShort(output[total..]) catch return error.BufferTooSmall;
        if (n == 0) break;
        total += n;
    }
    // Probe for remaining data.
    if (total == output.len) {
        var probe: [1]u8 = undefined;
        const extra = reader.readSliceShort(&probe) catch 0;
        if (extra != 0) return error.BufferTooSmall;
    }
    return output[0..total];
}

fn decompressImpl(comptime format: Format, input: []const u8, output: []u8) SigError![]u8 {
    switch (format) {
        .deflate, .gzip => {
            const container: std.compress.flate.Container = if (format == .gzip) .gzip else .raw;
            var in_reader: std.Io.Reader = .fixed(input);
            var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var decompressor = std.compress.flate.Decompress.init(
                &in_reader,
                container,
                &window_buf,
            );
            return readAllFromReader(&decompressor.reader, output);
        },
        .zstd => {
            var in_reader: std.Io.Reader = .fixed(input);
            var window_buf: [std.compress.zstd.default_window_len + std.compress.zstd.block_size_max]u8 = undefined;
            var decompressor = std.compress.zstd.Decompress.init(&in_reader, &window_buf, .{});
            return readAllFromReader(&decompressor.reader, output);
        },
    }
}

fn compressImpl(comptime format: Format, input: []const u8, output: []u8) SigError![]u8 {
    if (format == .zstd) @compileError("zstd compression not available in Zig std");

    const container: std.compress.flate.Container = if (format == .gzip) .gzip else .raw;
    var out_writer: std.Io.Writer = .fixed(output);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(
        &out_writer,
        &window_buf,
        container,
        .{},
    ) catch return error.BufferTooSmall;
    // Write uncompressed data to the compressor's writer.
    compressor.writer.writeAll(input) catch return error.BufferTooSmall;
    compressor.finish() catch return error.BufferTooSmall;
    // out_writer.end tracks how many bytes of compressed output were written.
    return output[0..out_writer.end];
}
