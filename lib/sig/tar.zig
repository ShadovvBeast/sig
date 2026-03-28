//! Capacity-first streaming tar parser.
//!
//! Reads tar archive entries into caller-provided buffers. No allocator.

const std = @import("std");
const SigError = @import("errors.zig").SigError;

/// A tar entry header parsed into fixed-size fields.
pub const TarEntry = struct {
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    size: u64 = 0,
    kind: Kind = .regular,

    pub const Kind = enum { regular, directory, symlink, other };

    pub fn name(self: *const TarEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Streaming tar reader. Parses tar headers from raw bytes into caller-provided
/// entry buffers.
pub fn TarReader(comptime max_entries: usize) type {
    return struct {
        entries: [max_entries]TarEntry = undefined,
        count: usize = 0,

        const Self = @This();
        const BLOCK_SIZE = 512;

        /// Parse tar archive data and populate entries.
        /// Returns the slice of parsed entries.
        /// Returns `BufferTooSmall` if there are more entries than `max_entries`.
        pub fn parse(self: *Self, data: []const u8) SigError![]TarEntry {
            self.count = 0;
            var offset: usize = 0;

            while (offset + BLOCK_SIZE <= data.len) {
                const header = data[offset..][0..BLOCK_SIZE];

                // Check for end-of-archive (two zero blocks).
                if (isZeroBlock(header)) break;

                if (self.count >= max_entries) return error.BufferTooSmall;

                var entry = &self.entries[self.count];
                entry.* = .{};

                // Parse name (bytes 0..100).
                const raw_name = header[0..100];
                var name_end: usize = 0;
                while (name_end < 100 and raw_name[name_end] != 0) : (name_end += 1) {}
                if (name_end > entry.name_buf.len) return error.BufferTooSmall;
                @memcpy(entry.name_buf[0..name_end], raw_name[0..name_end]);
                entry.name_len = name_end;

                // Parse size (bytes 124..136, octal ASCII).
                entry.size = parseOctal(header[124..136]);

                // Parse type flag (byte 156).
                entry.kind = switch (header[156]) {
                    '0', 0 => .regular,
                    '5' => .directory,
                    '2' => .symlink,
                    else => .other,
                };

                self.count += 1;

                // Skip past the file data (rounded up to 512-byte blocks).
                const data_blocks = (entry.size + BLOCK_SIZE - 1) / BLOCK_SIZE;
                offset += BLOCK_SIZE + data_blocks * BLOCK_SIZE;
            }

            return self.entries[0..self.count];
        }

        /// Read the content of a specific entry from the archive data.
        pub fn readContent(data: []const u8, entry_index: usize, entries: []const TarEntry, buf: []u8) SigError![]u8 {
            var offset: usize = 0;
            var idx: usize = 0;

            while (offset + BLOCK_SIZE <= data.len and idx <= entry_index) {
                const header = data[offset..][0..BLOCK_SIZE];
                if (isZeroBlock(header)) break;

                const size = parseOctal(header[124..136]);
                const data_blocks = (size + BLOCK_SIZE - 1) / BLOCK_SIZE;

                if (idx == entry_index) {
                    _ = entries; // used for validation context
                    const content_start = offset + BLOCK_SIZE;
                    const content_len: usize = @intCast(size);
                    if (content_len > buf.len) return error.BufferTooSmall;
                    if (content_start + content_len > data.len) return error.BufferTooSmall;
                    @memcpy(buf[0..content_len], data[content_start..][0..content_len]);
                    return buf[0..content_len];
                }

                offset += BLOCK_SIZE + data_blocks * BLOCK_SIZE;
                idx += 1;
            }

            return error.BufferTooSmall;
        }

        fn isZeroBlock(block: *const [BLOCK_SIZE]u8) bool {
            for (block) |b| {
                if (b != 0) return false;
            }
            return true;
        }

        fn parseOctal(field: []const u8) u64 {
            var result: u64 = 0;
            for (field) |c| {
                if (c >= '0' and c <= '7') {
                    result = result * 8 + (c - '0');
                } else if (c == ' ' or c == 0) {
                    continue;
                }
            }
            return result;
        }
    };
}
