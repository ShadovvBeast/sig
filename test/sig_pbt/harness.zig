const std = @import("std");

/// Runs a property-based test for a fixed number of iterations using a
/// deterministic PRNG seeded with 0xdeadbeef. On failure the iteration
/// index and error are printed before panicking, which makes reproduction
/// straightforward.
pub fn property(
    comptime name: []const u8,
    comptime testFn: fn (std.Random) anyerror!void,
) void {
    const iterations = 200;
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        testFn(prng.random()) catch |err| {
            std.debug.print("Property '{s}' failed on iteration {d}: {}\n", .{ name, i, err });
            @panic("property test failed");
        };
    }
}

// ---------------------------------------------------------------------------
// Basic generators
// ---------------------------------------------------------------------------

/// Fills `buf` with random bytes and returns a random-length prefix slice.
pub fn randomBytes(random: std.Random, buf: []u8) []u8 {
    if (buf.len == 0) return buf[0..0];
    const len = random.uintAtMost(usize, buf.len);
    random.bytes(buf[0..len]);
    return buf[0..len];
}

/// Returns a uniformly random integer of type `T`.
pub fn randomInt(random: std.Random, comptime T: type) T {
    return random.int(T);
}

/// Returns a random length in the range `0..max_len` (inclusive).
pub fn randomSliceLen(random: std.Random, max_len: usize) usize {
    if (max_len == 0) return 0;
    return random.uintAtMost(usize, max_len);
}

// ---------------------------------------------------------------------------
// Smoke tests for the harness itself
// ---------------------------------------------------------------------------

test "property runs 200 iterations" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {}
    };
    // Verify the property runner invokes the function without error.
    property("smoke", S.run);
}

test "randomBytes returns valid sub-slice" {
    var prng = std.Random.DefaultPrng.init(42);
    var buf: [64]u8 = undefined;
    const slice = randomBytes(prng.random(), &buf);
    try std.testing.expect(slice.len <= buf.len);
}

test "randomBytes handles zero-length buffer" {
    var prng = std.Random.DefaultPrng.init(42);
    var buf: [0]u8 = undefined;
    const slice = randomBytes(prng.random(), &buf);
    try std.testing.expectEqual(@as(usize, 0), slice.len);
}

test "randomInt returns a value" {
    var prng = std.Random.DefaultPrng.init(42);
    const v = randomInt(prng.random(), u32);
    // Just ensure it compiles and runs; any u32 value is valid.
    _ = v;
}

test "randomSliceLen respects max" {
    var prng = std.Random.DefaultPrng.init(42);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const len = randomSliceLen(prng.random(), 10);
        try std.testing.expect(len <= 10);
    }
}

test "randomSliceLen handles zero max" {
    var prng = std.Random.DefaultPrng.init(42);
    const len = randomSliceLen(prng.random(), 0);
    try std.testing.expectEqual(@as(usize, 0), len);
}
