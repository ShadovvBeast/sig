const SigError = @import("errors.zig").SigError;

/// Concatenates slices into a caller-provided buffer.
/// Returns the filled portion of `buf`, or `BufferTooSmall` if the total exceeds `buf.len`.
pub fn concat(buf: []u8, slices: []const []const u8) SigError![]u8 {
    var offset: usize = 0;
    for (slices) |s| {
        if (offset + s.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[offset..][0..s.len], s);
        offset += s.len;
    }
    return buf[0..offset];
}

/// Replaces all occurrences of `needle` with `replacement` in `haystack`,
/// writing the result into `buf`. Returns the filled portion of `buf`,
/// or `BufferTooSmall` if the output exceeds `buf.len`.
pub fn replace(buf: []u8, haystack: []const u8, needle: []const u8, replacement: []const u8) SigError![]u8 {
    // Edge case: empty needle — just copy haystack verbatim.
    if (needle.len == 0) {
        if (haystack.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[0..haystack.len], haystack);
        return buf[0..haystack.len];
    }

    var offset: usize = 0; // write position in buf
    var i: usize = 0; // read position in haystack

    while (i <= haystack.len) {
        // Check if needle matches at position i.
        if (i + needle.len <= haystack.len and eql(haystack[i..][0..needle.len], needle)) {
            if (offset + replacement.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[offset..][0..replacement.len], replacement);
            offset += replacement.len;
            i += needle.len;
        } else {
            if (i >= haystack.len) break;
            if (offset + 1 > buf.len) return error.BufferTooSmall;
            buf[offset] = haystack[i];
            offset += 1;
            i += 1;
        }
    }

    return buf[0..offset];
}

/// A segmented string: fixed number of fixed-size chunks, no allocator.
pub fn SegmentedString(comptime chunk_count: usize, comptime chunk_size: usize) type {
    return struct {
        chunks: [chunk_count][chunk_size]u8 = undefined,
        lengths: [chunk_count]usize = [_]usize{0} ** chunk_count,
        active_chunks: usize = 0,

        const Self = @This();

        /// Appends data across chunks. Fills the current chunk, then moves to the next.
        /// Returns `CapacityExceeded` if all chunks are full and data remains.
        pub fn append(self: *Self, data: []const u8) SigError!void {
            var remaining = data;

            while (remaining.len > 0) {
                // Determine which chunk to write into.
                var chunk_idx: usize = undefined;
                if (self.active_chunks == 0) {
                    // First append — activate the first chunk.
                    self.active_chunks = 1;
                    chunk_idx = 0;
                } else {
                    chunk_idx = self.active_chunks - 1;
                    // If current chunk is full, advance.
                    if (self.lengths[chunk_idx] >= chunk_size) {
                        if (self.active_chunks >= chunk_count) return error.CapacityExceeded;
                        self.active_chunks += 1;
                        chunk_idx = self.active_chunks - 1;
                    }
                }

                const space = chunk_size - self.lengths[chunk_idx];
                const to_copy = if (remaining.len < space) remaining.len else space;
                const start = self.lengths[chunk_idx];
                @memcpy(self.chunks[chunk_idx][start..][0..to_copy], remaining[0..to_copy]);
                self.lengths[chunk_idx] += to_copy;
                remaining = remaining[to_copy..];
            }
        }

        /// Copies all stored data into `buf` sequentially.
        /// Returns the filled portion of `buf`, or `BufferTooSmall` if `buf` is too small.
        pub fn toSlice(self: *const Self, buf: []u8) SigError![]u8 {
            var offset: usize = 0;
            for (0..self.active_chunks) |ci| {
                const len = self.lengths[ci];
                if (offset + len > buf.len) return error.BufferTooSmall;
                @memcpy(buf[offset..][0..len], self.chunks[ci][0..len]);
                offset += len;
            }
            return buf[0..offset];
        }
    };
}

/// Byte-wise equality check (avoids pulling in std.mem).
fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
