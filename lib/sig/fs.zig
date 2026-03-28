const std = @import("std");
const SigError = @import("errors.zig").SigError;

/// Directory entry for bounded directory listing.
/// Name is stored inline in a fixed buffer — no allocation needed.
pub const DirEntry = struct {
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    kind: Kind,

    pub const Kind = enum { file, directory, symlink, other };

    /// Returns the name as a slice.
    pub fn name(self: *const DirEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Read an entire file into a caller-provided buffer.
/// Returns the filled slice, or `BufferTooSmall` if the file exceeds the buffer.
pub fn readFile(io: std.Io, path: []const u8, buf: []u8) SigError![]u8 {
    const cwd: std.Io.Dir = .cwd();
    var file = cwd.openFile(io, path, .{}) catch return error.BufferTooSmall;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    var total: usize = 0;
    while (total < buf.len) {
        const n = reader.interface.readSliceShort(buf[total..]) catch return error.BufferTooSmall;
        if (n == 0) break;
        total += n;
    }

    // If we filled the buffer, probe for more data.
    if (total == buf.len) {
        var probe: [1]u8 = undefined;
        const extra = reader.interface.readSliceShort(&probe) catch 0;
        if (extra != 0) return error.BufferTooSmall;
    }

    return buf[0..total];
}

/// Write a caller-provided slice to a file (creates or truncates).
pub fn writeFile(io: std.Io, path: []const u8, data: []const u8) SigError!void {
    const cwd: std.Io.Dir = .cwd();
    var file = cwd.createFile(io, path, .{}) catch return error.BufferTooSmall;
    defer file.close(io);
    file.writeStreamingAll(io, data) catch return error.BufferTooSmall;
}

/// Join path segments into a caller-provided buffer using the platform separator.
/// Returns the joined path slice, or `BufferTooSmall` if the buffer is insufficient.
pub fn joinPath(buf: []u8, segments: []const []const u8) SigError![]u8 {
    const sep = std.fs.path.sep;
    var offset: usize = 0;
    for (segments, 0..) |seg, i| {
        // Strip trailing separators from segment (except for root "/").
        var s = seg;
        while (s.len > 1 and s[s.len - 1] == sep) {
            s = s[0 .. s.len - 1];
        }

        // Strip leading separators from non-first segments.
        if (i > 0) {
            while (s.len > 0 and s[0] == sep) {
                s = s[1..];
            }
        }

        if (s.len == 0) continue;

        // Add separator between segments.
        if (i > 0 and offset > 0 and buf[offset - 1] != sep) {
            if (offset >= buf.len) return error.BufferTooSmall;
            buf[offset] = sep;
            offset += 1;
        }

        if (offset + s.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[offset..][0..s.len], s);
        offset += s.len;
    }
    return buf[0..offset];
}

/// List directory entries into a caller-provided array of DirEntry.
/// Returns the filled slice, or `BufferTooSmall` if there are more entries than the buffer holds.
pub fn listDir(io: std.Io, path: []const u8, entries: []DirEntry) SigError![]DirEntry {
    const cwd: std.Io.Dir = .cwd();
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch return error.BufferTooSmall;
    defer dir.close(io);

    var iter = dir.iterate();
    var count: usize = 0;

    while (iter.next(io) catch return error.BufferTooSmall) |entry| {
        if (count >= entries.len) return error.BufferTooSmall;

        const de = &entries[count];
        if (entry.name.len > de.name_buf.len) return error.BufferTooSmall;

        @memcpy(de.name_buf[0..entry.name.len], entry.name);
        de.name_len = entry.name.len;
        de.kind = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            else => .other,
        };
        count += 1;
    }

    return entries[0..count];
}
