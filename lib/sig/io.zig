const std = @import("std");
const SigError = @import("errors.zig").SigError;

/// Reads data into a caller-provided buffer. Returns the filled slice.
/// Returns error.BufferTooSmall if the source has more data than the buffer can hold.
pub fn readInto(reader: anytype, buf: []u8) SigError![]u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = reader.read(buf[total..]) catch return error.BufferTooSmall;
        if (n == 0) break;
        total += n;
    }

    // If we filled the buffer, check whether the source has more data.
    if (total == buf.len) {
        var probe: [1]u8 = undefined;
        const extra = reader.read(&probe) catch return error.BufferTooSmall;
        if (extra != 0) return error.BufferTooSmall;
    }

    return buf[0..total];
}

/// Reads up to `max_bytes` into a caller-provided buffer.
/// The buffer must be at least `max_bytes` in size.
pub fn readAtMost(reader: anytype, buf: []u8, max_bytes: usize) SigError![]u8 {
    const limit = @min(max_bytes, buf.len);
    var total: usize = 0;
    while (total < limit) {
        const n = reader.read(buf[total..limit]) catch return error.BufferTooSmall;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

/// A streaming reader that processes data in fixed-size chunks.
/// RAM usage is bounded to exactly `chunk_size` bytes for the internal buffer.
pub fn StreamReader(comptime chunk_size: usize) type {
    return struct {
        buf: [chunk_size]u8 = undefined,

        const Self = @This();

        /// Reads the next chunk from the reader. Returns the filled slice,
        /// or null when the reader has reached EOF.
        pub fn next(self: *Self, reader: anytype) ?[]const u8 {
            var total: usize = 0;
            while (total < chunk_size) {
                const n = reader.read(self.buf[total..]) catch return null;
                if (n == 0) break;
                total += n;
            }
            if (total == 0) return null;
            return self.buf[0..total];
        }
    };
}

// ── Write operations ─────────────────────────────────────────────────────

/// Writes the entire contents of a caller-provided buffer to a writer.
/// The writer must have a `write([]const u8) !usize` method.
/// Returns `BufferTooSmall` if the writer fails before all bytes are written.
pub fn writeAll(writer: anytype, data: []const u8) SigError!void {
    var written: usize = 0;
    while (written < data.len) {
        const n = writer.write(data[written..]) catch return error.BufferTooSmall;
        if (n == 0) return error.BufferTooSmall;
        written += n;
    }
}

/// Writes a formatted string into a caller-provided buffer, then writes
/// the buffer contents to a writer. Zero heap allocation.
/// Returns `BufferTooSmall` if the format output exceeds `buf` or the writer fails.
pub fn writeFormatted(writer: anytype, buf: []u8, comptime fmt_str: []const u8, args: anytype) SigError!void {
    const formatted = std.fmt.bufPrint(buf, fmt_str, args) catch return error.BufferTooSmall;
    return writeAll(writer, formatted);
}

/// Returns a stdout writer. No allocator needed.
/// Requires an Io context from std.process.Init.
pub fn stdoutWriter(io: @import("std").Io) FdWriter {
    return .{ .file = @import("std").Io.File.stdout(), .io = io };
}

/// Returns a stderr writer. No allocator needed.
pub fn stderrWriter(io: @import("std").Io) FdWriter {
    return .{ .file = @import("std").Io.File.stderr(), .io = io };
}

/// Cross-platform file writer using the Zig 0.16 Io interface.
/// No allocator.
pub const FdWriter = struct {
    file: @import("std").Io.File,
    io: @import("std").Io,

    pub fn write(self: FdWriter, data: []const u8) !usize {
        self.file.writeStreamingAll(self.io, data) catch return error.BufferTooSmall;
        return data.len;
    }
};
