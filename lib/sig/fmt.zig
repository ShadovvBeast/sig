const std = @import("std");
const SigError = @import("errors.zig").SigError;

/// Formats into a caller-provided buffer. Returns the slice of bytes written.
/// Returns error.BufferTooSmall if the buffer cannot hold the full output.
pub fn formatInto(buf: []u8, comptime fmt_str: []const u8, args: anytype) SigError![]u8 {
    return std.fmt.bufPrint(buf, fmt_str, args) catch return error.BufferTooSmall;
}

/// Computes the exact byte length of the formatted output without writing.
pub fn measureFormat(comptime fmt_str: []const u8, args: anytype) usize {
    return std.fmt.count(fmt_str, args);
}
