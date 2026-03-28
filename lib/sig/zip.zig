//! Capacity-first streaming zip parser.
//!
//! Reads zip archive entries into caller-provided buffers. No allocator.
//! Parses the central directory to enumerate entries.

const std = @import("std");
const SigError = @import("errors.zig").SigError;

/// A zip entry parsed into fixed-size fields.
pub const ZipEntry = struct {
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    compressed_size: u32 = 0,
    uncompressed_size: u32 = 0,
    compression_method: u16 = 0,
    local_header_offset: u32 = 0,

    pub fn name(self: *const ZipEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn isStored(self: *const ZipEntry) bool {
        return self.compression_method == 0;
    }
};

/// Streaming zip reader. Parses zip central directory from raw bytes.
pub fn ZipReader(comptime max_entries: usize) type {
    return struct {
        entries: [max_entries]ZipEntry = undefined,
        count: usize = 0,

        const Self = @This();

        /// Parse zip archive data by locating the End of Central Directory
        /// and reading central directory entries.
        /// Returns `BufferTooSmall` if there are more entries than `max_entries`.
        pub fn parse(self: *Self, data: []const u8) SigError![]ZipEntry {
            self.count = 0;

            // Find End of Central Directory record (signature 0x06054b50).
            const eocd_offset = findEOCD(data) orelse return error.BufferTooSmall;
            if (eocd_offset + 22 > data.len) return error.BufferTooSmall;

            const eocd = data[eocd_offset..];
            const entry_count = readU16LE(eocd[8..10]);
            const cd_offset = readU32LE(eocd[16..20]);

            if (entry_count > max_entries) return error.BufferTooSmall;

            var offset: usize = @intCast(cd_offset);

            var i: u16 = 0;
            while (i < entry_count) : (i += 1) {
                if (offset + 46 > data.len) return error.BufferTooSmall;
                const rec = data[offset..];

                // Verify central directory signature (0x02014b50).
                if (readU32LE(rec[0..4]) != 0x02014b50) return error.BufferTooSmall;

                const name_len = readU16LE(rec[28..30]);
                const extra_len = readU16LE(rec[30..32]);
                const comment_len = readU16LE(rec[32..34]);

                var entry = &self.entries[self.count];
                entry.* = .{};

                if (name_len > entry.name_buf.len) return error.BufferTooSmall;
                if (offset + 46 + name_len > data.len) return error.BufferTooSmall;

                @memcpy(entry.name_buf[0..name_len], rec[46..][0..name_len]);
                entry.name_len = name_len;
                entry.compression_method = readU16LE(rec[10..12]);
                entry.compressed_size = readU32LE(rec[20..24]);
                entry.uncompressed_size = readU32LE(rec[24..28]);
                entry.local_header_offset = readU32LE(rec[42..46]);

                self.count += 1;
                offset += 46 + name_len + extra_len + comment_len;
            }

            return self.entries[0..self.count];
        }

        fn findEOCD(data: []const u8) ?usize {
            if (data.len < 22) return null;
            // Search backwards for EOCD signature.
            var i: usize = data.len - 22;
            while (true) {
                if (readU32LE(data[i..][0..4]) == 0x06054b50) return i;
                if (i == 0) break;
                i -= 1;
            }
            return null;
        }

        fn readU16LE(bytes: []const u8) u16 {
            return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
        }

        fn readU32LE(bytes: []const u8) u32 {
            return @as(u32, bytes[0]) |
                (@as(u32, bytes[1]) << 8) |
                (@as(u32, bytes[2]) << 16) |
                (@as(u32, bytes[3]) << 24);
        }
    };
}
