// Feature: sig-memory-model, Property 18: Sig_Std API contract — no Allocator parameters
//
// For any public function in the Sig_Std module, the function's parameter
// list shall not include a parameter of type std.mem.Allocator. All functions
// requiring memory shall accept a []u8 buffer parameter or use a comptime-sized
// container.
//
// **Validates: Requirements 12.1, 12.2**

const std = @import("std");
const harness = @import("harness");
const sig = @import("sig");
const sig_fmt = sig.fmt;
const sig_io = sig.io;
const sig_string = sig.string;
const sig_parse = sig.parse;
const containers = sig.containers;

// ---------------------------------------------------------------------------
// Property 18 – Sig_Std API contract: no Allocator parameters
//
// We verify this structurally by calling every public API function with
// valid arguments and confirming they compile and execute without any
// Allocator parameter. If any function required an Allocator, the call
// would fail to compile.
// ---------------------------------------------------------------------------

test "Property 18: formatInto works without Allocator parameter" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const value = harness.randomInt(random, i32);
            var buf: [64]u8 = undefined;
            _ = try sig_fmt.formatInto(&buf, "{d}", .{value});
        }
    };
    harness.property("formatInto works without Allocator parameter", S.run);
}

test "Property 18: measureFormat works without Allocator parameter" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const value = harness.randomInt(random, i32);
            const n = sig_fmt.measureFormat("{d}", .{value});
            try std.testing.expect(n > 0 or value == 0);
        }
    };
    harness.property("measureFormat works without Allocator parameter", S.run);
}
test "Property 18: readInto works without Allocator parameter" {
    const S = struct {
        const SliceReader = struct {
            data: []const u8,
            pos: usize = 0,
            pub fn read(self: *@This(), buf: []u8) error{}!usize {
                if (self.pos >= self.data.len) return 0;
                const remaining = self.data.len - self.pos;
                const n = @min(remaining, buf.len);
                @memcpy(buf[0..n], self.data[self.pos..][0..n]);
                self.pos += n;
                return n;
            }
        };
        fn run(random: std.Random) anyerror!void {
            var data_buf: [64]u8 = undefined;
            const data = harness.randomBytes(random, &data_buf);
            var reader = SliceReader{ .data = data };
            var buf: [64]u8 = undefined;
            _ = try sig_io.readInto(&reader, &buf);
        }
    };
    harness.property("readInto works without Allocator parameter", S.run);
}

test "Property 18: readAtMost works without Allocator parameter" {
    const S = struct {
        const SliceReader = struct {
            data: []const u8,
            pos: usize = 0,
            pub fn read(self: *@This(), buf: []u8) error{}!usize {
                if (self.pos >= self.data.len) return 0;
                const remaining = self.data.len - self.pos;
                const n = @min(remaining, buf.len);
                @memcpy(buf[0..n], self.data[self.pos..][0..n]);
                self.pos += n;
                return n;
            }
        };
        fn run(random: std.Random) anyerror!void {
            var data_buf: [32]u8 = undefined;
            const data = harness.randomBytes(random, &data_buf);
            var reader = SliceReader{ .data = data };
            var buf: [64]u8 = undefined;
            _ = try sig_io.readAtMost(&reader, &buf, 16);
        }
    };
    harness.property("readAtMost works without Allocator parameter", S.run);
}

test "Property 18: concat works without Allocator parameter" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var a_buf: [32]u8 = undefined;
            var b_buf: [32]u8 = undefined;
            const a = harness.randomBytes(random, &a_buf);
            const b = harness.randomBytes(random, &b_buf);
            var out: [64]u8 = undefined;
            const slices: []const []const u8 = &.{ a, b };
            _ = try sig_string.concat(&out, slices);
        }
    };
    harness.property("concat works without Allocator parameter", S.run);
}

test "Property 18: replace works without Allocator parameter" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var hay_buf: [64]u8 = undefined;
            const haystack = harness.randomBytes(random, &hay_buf);
            var out: [128]u8 = undefined;
            _ = try sig_string.replace(&out, haystack, "x", "y");
        }
    };
    harness.property("replace works without Allocator parameter", S.run);
}

test "Property 18: parseInto works without Allocator parameter" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var buf: [64]u8 = undefined;
            _ = try sig_parse.parseInto("key=val\n", &buf);
        }
    };
    harness.property("parseInto works without Allocator parameter", S.run);
}

test "Property 18: prettyPrint works without Allocator parameter" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const pairs: []const sig_parse.KvPair = &.{
                .{ .key = "k", .value = "v" },
            };
            var buf: [64]u8 = undefined;
            _ = try sig_parse.prettyPrint(pairs, &buf);
        }
    };
    harness.property("prettyPrint works without Allocator parameter", S.run);
}

test "Property 18: measureParse works without Allocator parameter" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const n = sig_parse.measureParse("key=val\n");
            try std.testing.expect(n > 0);
        }
    };
    harness.property("measureParse works without Allocator parameter", S.run);
}
// ---------------------------------------------------------------------------
// Feature: sig-memory-model, Property 19: Buffer bounds safety
//
// For any Sig_Std public API function that accepts a []u8 buffer parameter,
// and for any input, the function shall not write to any memory address
// outside the range [buf.ptr .. buf.ptr + buf.len].
//
// We test this by placing sentinel bytes before and after the working buffer
// region and verifying they remain unchanged after each API call.
//
// **Validates: Requirements 12.4**
// ---------------------------------------------------------------------------

/// Sentinel byte used to guard buffer boundaries.
const SENTINEL: u8 = 0xAA;

test "Property 19: formatInto does not write outside buffer bounds" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const value = harness.randomInt(random, i32);
            const needed = sig_fmt.measureFormat("{d}", .{value});

            // Allocate a guarded region: [guard_before | working_buf | guard_after]
            const guard_size = 8;
            var arena: [guard_size + 128 + guard_size]u8 = undefined;

            // Fill entire arena with sentinel.
            @memset(&arena, SENTINEL);

            const buf_start = guard_size;
            const buf_len = @max(needed, 1); // at least 1 byte
            const buf = arena[buf_start..][0..buf_len];

            _ = sig_fmt.formatInto(buf, "{d}", .{value}) catch {};

            // Verify guard regions are untouched.
            for (arena[0..guard_size]) |b| {
                try std.testing.expectEqual(SENTINEL, b);
            }
            for (arena[buf_start + buf_len ..][0..guard_size]) |b| {
                try std.testing.expectEqual(SENTINEL, b);
            }
        }
    };
    harness.property("formatInto does not write outside buffer bounds", S.run);
}

test "Property 19: concat does not write outside buffer bounds" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var a_buf: [32]u8 = undefined;
            var b_buf: [32]u8 = undefined;
            const a = harness.randomBytes(random, &a_buf);
            const b = harness.randomBytes(random, &b_buf);

            const guard_size = 8;
            var arena: [guard_size + 64 + guard_size]u8 = undefined;
            @memset(&arena, SENTINEL);

            const buf = arena[guard_size..][0..64];
            const slices: []const []const u8 = &.{ a, b };
            _ = sig_string.concat(buf, slices) catch {};

            for (arena[0..guard_size]) |byte| {
                try std.testing.expectEqual(SENTINEL, byte);
            }
            for (arena[guard_size + 64 ..][0..guard_size]) |byte| {
                try std.testing.expectEqual(SENTINEL, byte);
            }
        }
    };
    harness.property("concat does not write outside buffer bounds", S.run);
}

test "Property 19: replace does not write outside buffer bounds" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var hay_buf: [32]u8 = undefined;
            const haystack = harness.randomBytes(random, &hay_buf);

            const guard_size = 8;
            var arena: [guard_size + 64 + guard_size]u8 = undefined;
            @memset(&arena, SENTINEL);

            const buf = arena[guard_size..][0..64];
            _ = sig_string.replace(buf, haystack, "x", "yy") catch {};

            for (arena[0..guard_size]) |byte| {
                try std.testing.expectEqual(SENTINEL, byte);
            }
            for (arena[guard_size + 64 ..][0..guard_size]) |byte| {
                try std.testing.expectEqual(SENTINEL, byte);
            }
        }
    };
    harness.property("replace does not write outside buffer bounds", S.run);
}

test "Property 19: parseInto does not write outside buffer bounds" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const input = "key=val\n";
            const guard_size = 8;
            var arena: [guard_size + 64 + guard_size]u8 = undefined;
            @memset(&arena, SENTINEL);

            const buf = arena[guard_size..][0..64];
            _ = sig_parse.parseInto(input, buf) catch {};

            for (arena[0..guard_size]) |byte| {
                try std.testing.expectEqual(SENTINEL, byte);
            }
            for (arena[guard_size + 64 ..][0..guard_size]) |byte| {
                try std.testing.expectEqual(SENTINEL, byte);
            }
        }
    };
    harness.property("parseInto does not write outside buffer bounds", S.run);
}

test "Property 19: prettyPrint does not write outside buffer bounds" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const pairs: []const sig_parse.KvPair = &.{
                .{ .key = "name", .value = "zig" },
            };
            const guard_size = 8;
            var arena: [guard_size + 64 + guard_size]u8 = undefined;
            @memset(&arena, SENTINEL);

            const buf = arena[guard_size..][0..64];
            _ = sig_parse.prettyPrint(pairs, buf) catch {};

            for (arena[0..guard_size]) |byte| {
                try std.testing.expectEqual(SENTINEL, byte);
            }
            for (arena[guard_size + 64 ..][0..guard_size]) |byte| {
                try std.testing.expectEqual(SENTINEL, byte);
            }
        }
    };
    harness.property("prettyPrint does not write outside buffer bounds", S.run);
}
// ---------------------------------------------------------------------------
// Feature: sig-memory-model, Property 12: Capacity-first APIs never allocate on error
//
// For any Sig_Std API call where the provided buffer or container capacity is
// insufficient, the API shall return a SigError (one of CapacityExceeded,
// BufferTooSmall, DepthExceeded, QuotaExceeded) and shall not invoke any
// allocator.
//
// We test this by calling APIs with undersized buffers/full containers and
// verifying they return the expected SigError variants without panicking or
// allocating.
//
// **Validates: Requirements 7.5, 7.6**
// ---------------------------------------------------------------------------

test "Property 12: formatInto returns BufferTooSmall on undersized buffer (no allocation)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const value = harness.randomInt(random, i64);
            const needed = sig_fmt.measureFormat("{d}", .{value});
            if (needed == 0) return;

            const small = random.uintAtMost(usize, needed - 1);
            var buf: [128]u8 = undefined;
            const result = sig_fmt.formatInto(buf[0..small], "{d}", .{value});
            try std.testing.expectError(error.BufferTooSmall, result);
        }
    };
    harness.property("formatInto returns BufferTooSmall on undersized buffer (no alloc)", S.run);
}

test "Property 12: concat returns BufferTooSmall on undersized buffer (no allocation)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate data that won't fit in a tiny buffer.
            var a_buf: [32]u8 = undefined;
            const a = harness.randomBytes(random, &a_buf);
            if (a.len < 2) return;

            const small = random.uintAtMost(usize, a.len - 1);
            var out: [32]u8 = undefined;
            const slices: []const []const u8 = &.{a};
            const result = sig_string.concat(out[0..small], slices);
            try std.testing.expectError(error.BufferTooSmall, result);
        }
    };
    harness.property("concat returns BufferTooSmall on undersized buffer (no alloc)", S.run);
}
test "Property 12: replace returns BufferTooSmall on undersized buffer (no allocation)" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            // "hello world" with replacement "world"->"universe" needs 15 bytes.
            // A 5-byte buffer is too small.
            var buf: [5]u8 = undefined;
            const result = sig_string.replace(&buf, "hello world", "world", "universe");
            try std.testing.expectError(error.BufferTooSmall, result);
        }
    };
    harness.property("replace returns BufferTooSmall on undersized buffer (no alloc)", S.run);
}

test "Property 12: parseInto returns BufferTooSmall on undersized buffer (no allocation)" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const input = "name=zig\nversion=1\n";
            var buf: [5]u8 = undefined;
            const result = sig_parse.parseInto(input, &buf);
            try std.testing.expectError(error.BufferTooSmall, result);
        }
    };
    harness.property("parseInto returns BufferTooSmall on undersized buffer (no alloc)", S.run);
}

test "Property 12: BoundedVec returns CapacityExceeded when full (no allocation)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const Vec = containers.BoundedVec(u8, 4);
            var vec = Vec{};

            // Fill to capacity.
            for (0..4) |_| {
                try vec.push(harness.randomInt(random, u8));
            }
            try std.testing.expectEqual(@as(usize, 4), vec.length());

            // Next push must return CapacityExceeded.
            const result = vec.push(42);
            try std.testing.expectError(error.CapacityExceeded, result);
        }
    };
    harness.property("BoundedVec returns CapacityExceeded when full (no alloc)", S.run);
}

test "Property 12: RingBuffer returns CapacityExceeded when full (no allocation)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const Ring = containers.RingBuffer(u8, 4);
            var ring = Ring{};

            for (0..4) |_| {
                try ring.push(harness.randomInt(random, u8));
            }
            try std.testing.expectEqual(@as(usize, 4), ring.length());

            const result = ring.push(42);
            try std.testing.expectError(error.CapacityExceeded, result);
        }
    };
    harness.property("RingBuffer returns CapacityExceeded when full (no alloc)", S.run);
}
test "Property 12: FixedPool returns CapacityExceeded when empty (no allocation)" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const Pool = containers.FixedPool(u64, 2);
            var pool = Pool{};

            // Acquire all slots.
            const s1 = try pool.acquire();
            const s2 = try pool.acquire();
            _ = s1;
            _ = s2;
            try std.testing.expectEqual(@as(usize, 2), pool.length());

            // Next acquire must return CapacityExceeded.
            const result = pool.acquire();
            try std.testing.expectError(error.CapacityExceeded, result);
        }
    };
    harness.property("FixedPool returns CapacityExceeded when empty (no alloc)", S.run);
}

test "Property 12: SlotMap returns CapacityExceeded when full (no allocation)" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const Map = containers.SlotMap(u32, 4);
            var map = Map{};

            for (0..4) |_| {
                _ = try map.insert(harness.randomInt(random, u32));
            }
            try std.testing.expectEqual(@as(usize, 4), map.length());

            const result = map.insert(99);
            try std.testing.expectError(error.CapacityExceeded, result);
        }
    };
    harness.property("SlotMap returns CapacityExceeded when full (no alloc)", S.run);
}

test "Property 12: SegmentedString returns CapacityExceeded on overflow (no allocation)" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const SegStr = sig_string.SegmentedString(2, 4); // 8 bytes total
            var ss = SegStr{};

            try ss.append("1234"); // fills chunk 0
            try ss.append("5678"); // fills chunk 1

            // Next append must return CapacityExceeded.
            const result = ss.append("x");
            try std.testing.expectError(error.CapacityExceeded, result);
        }
    };
    harness.property("SegmentedString returns CapacityExceeded on overflow (no alloc)", S.run);
}
