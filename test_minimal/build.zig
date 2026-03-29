const std = @import("std");
pub fn build(b: *std.Build) !void {
    const step = b.step("hello", "test");
    _ = step;
}
