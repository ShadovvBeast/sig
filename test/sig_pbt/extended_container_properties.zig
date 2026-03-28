// Feature: sig-memory-model, Property 27: Extended container length invariant
//
// For any extended bounded container (BoundedDeque, BoundedPriorityQueue,
// FixedLinkedList, BoundedBitSet, BoundedMultiArrayList, BoundedStringMap)
// and any sequence of insert and remove operations, length() shall track
// live elements and max_capacity() shall equal the comptime-declared capacity.
// When full, the next insertion shall return error.CapacityExceeded.
//
// **Validates: Requirements 16.1, 16.2, 16.3, 16.4, 16.5, 16.6, 16.7**

const std = @import("std");
const harness = @import("harness");
const containers = @import("containers");

const CAPACITY = 16;

// ---------------------------------------------------------------------------
// BoundedDeque
// ---------------------------------------------------------------------------

test "Property 27: BoundedDeque length tracks insertions minus removals" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var deque = containers.BoundedDeque(u32, CAPACITY){};
            var expected_len: usize = 0;

            try std.testing.expectEqual(@as(usize, CAPACITY), deque.max_capacity());

            var i: usize = 0;
            while (i < 64) : (i += 1) {
                const op = random.uintLessThan(u8, 4);
                switch (op) {
                    0 => { // pushBack
                        if (deque.pushBack(random.int(u32))) |_| {
                            expected_len += 1;
                        } else |err| {
                            try std.testing.expectEqual(error.CapacityExceeded, err);
                        }
                    },
                    1 => { // pushFront
                        if (deque.pushFront(random.int(u32))) |_| {
                            expected_len += 1;
                        } else |err| {
                            try std.testing.expectEqual(error.CapacityExceeded, err);
                        }
                    },
                    2 => { // popBack
                        if (deque.popBack()) |_| expected_len -= 1;
                    },
                    3 => { // popFront
                        if (deque.popFront()) |_| expected_len -= 1;
                    },
                    else => unreachable,
                }
                try std.testing.expectEqual(expected_len, deque.length());
            }
        }
    };
    harness.property("BoundedDeque length tracks insertions minus removals", S.run);
}

test "Property 27: BoundedDeque CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var deque = containers.BoundedDeque(u8, CAPACITY){};
            var i: usize = 0;
            while (i < CAPACITY) : (i += 1) try deque.pushBack(@intCast(i));
            try std.testing.expectError(error.CapacityExceeded, deque.pushBack(0xFF));
            try std.testing.expectError(error.CapacityExceeded, deque.pushFront(0xFF));
        }
    };
    harness.property("BoundedDeque CapacityExceeded when full", S.run);
}

// ---------------------------------------------------------------------------
// BoundedPriorityQueue
// ---------------------------------------------------------------------------

fn u32LessThan(a: u32, b: u32) bool {
    return a < b;
}

test "Property 27: BoundedPriorityQueue length tracks insertions minus removals" {
    const PQ = containers.BoundedPriorityQueue(u32, CAPACITY, u32LessThan);
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var pq = PQ{};
            var expected_len: usize = 0;

            try std.testing.expectEqual(@as(usize, CAPACITY), pq.max_capacity());

            var i: usize = 0;
            while (i < 64) : (i += 1) {
                if (random.boolean()) {
                    if (pq.push(random.int(u32))) |_| {
                        expected_len += 1;
                    } else |err| {
                        try std.testing.expectEqual(error.CapacityExceeded, err);
                    }
                } else {
                    if (pq.pop()) |_| expected_len -= 1;
                }
                try std.testing.expectEqual(expected_len, pq.length());
            }
        }
    };
    harness.property("BoundedPriorityQueue length tracks insertions minus removals", S.run);
}

test "Property 27: BoundedPriorityQueue pops in sorted order" {
    const PQ = containers.BoundedPriorityQueue(u32, CAPACITY, u32LessThan);
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var pq = PQ{};
            const n = 1 + random.uintAtMost(usize, CAPACITY - 1);
            var i: usize = 0;
            while (i < n) : (i += 1) try pq.push(random.int(u32));

            var prev: u32 = 0;
            while (pq.pop()) |val| {
                try std.testing.expect(val >= prev);
                prev = val;
            }
        }
    };
    harness.property("BoundedPriorityQueue pops in sorted order", S.run);
}

// ---------------------------------------------------------------------------
// FixedLinkedList
// ---------------------------------------------------------------------------

test "Property 27: FixedLinkedList length tracks insertions minus removals" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var list = containers.FixedLinkedList(u32, CAPACITY).init();
            var expected_len: usize = 0;

            try std.testing.expectEqual(@as(usize, CAPACITY), list.max_capacity());

            var i: usize = 0;
            while (i < 64) : (i += 1) {
                if (random.boolean()) {
                    if (list.pushBack(random.int(u32))) |_| {
                        expected_len += 1;
                    } else |err| {
                        try std.testing.expectEqual(error.CapacityExceeded, err);
                    }
                } else {
                    if (list.popFront()) |_| expected_len -= 1;
                }
                try std.testing.expectEqual(expected_len, list.length());
            }
        }
    };
    harness.property("FixedLinkedList length tracks insertions minus removals", S.run);
}

// ---------------------------------------------------------------------------
// BoundedBitSet
// ---------------------------------------------------------------------------

test "Property 27: BoundedBitSet set/unset tracks count correctly" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var bs = containers.BoundedBitSet(CAPACITY){};
            var expected_count: usize = 0;
            var is_set = [_]bool{false} ** CAPACITY;

            var i: usize = 0;
            while (i < 64) : (i += 1) {
                const idx = random.uintLessThan(usize, CAPACITY);
                if (random.boolean()) {
                    try bs.set(idx);
                    if (!is_set[idx]) {
                        expected_count += 1;
                        is_set[idx] = true;
                    }
                } else {
                    try bs.unset(idx);
                    if (is_set[idx]) {
                        expected_count -= 1;
                        is_set[idx] = false;
                    }
                }
                try std.testing.expectEqual(expected_count, bs.count());
            }
        }
    };
    harness.property("BoundedBitSet set/unset tracks count correctly", S.run);
}

test "Property 27: BoundedBitSet CapacityExceeded on out-of-range index" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var bs = containers.BoundedBitSet(CAPACITY){};
            try std.testing.expectError(error.CapacityExceeded, bs.set(CAPACITY));
            try std.testing.expectError(error.CapacityExceeded, bs.set(CAPACITY + 10));
        }
    };
    harness.property("BoundedBitSet CapacityExceeded on out-of-range index", S.run);
}

// ---------------------------------------------------------------------------
// BoundedMultiArrayList
// ---------------------------------------------------------------------------

const TestStruct = struct { x: u32, y: u16 };

test "Property 27: BoundedMultiArrayList length tracks appends minus pops" {
    const MAL = containers.BoundedMultiArrayList(TestStruct, CAPACITY);
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var mal = MAL{};
            var expected_len: usize = 0;

            try std.testing.expectEqual(@as(usize, CAPACITY), mal.max_capacity());

            var i: usize = 0;
            while (i < 64) : (i += 1) {
                if (random.boolean()) {
                    const item = TestStruct{ .x = random.int(u32), .y = random.int(u16) };
                    if (mal.append(item)) |_| {
                        expected_len += 1;
                    } else |err| {
                        try std.testing.expectEqual(error.CapacityExceeded, err);
                    }
                } else {
                    if (mal.pop()) |_| expected_len -= 1;
                }
                try std.testing.expectEqual(expected_len, mal.length());
            }
        }
    };
    harness.property("BoundedMultiArrayList length tracks appends minus pops", S.run);
}

// ---------------------------------------------------------------------------
// BoundedStringMap
// ---------------------------------------------------------------------------

test "Property 27: BoundedStringMap length tracks puts minus removes" {
    const SM = containers.BoundedStringMap(16, 16, CAPACITY);
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var map = SM{};
            var expected_len: usize = 0;

            try std.testing.expectEqual(@as(usize, CAPACITY), map.max_capacity());

            // Use a set of known keys to allow removal.
            var key_buf: [8]u8 = undefined;
            var inserted_keys: [CAPACITY][8]u8 = undefined;
            var inserted_lens: [CAPACITY]usize = [_]usize{0} ** CAPACITY;
            var inserted_count: usize = 0;

            var i: usize = 0;
            while (i < 48) : (i += 1) {
                if (random.boolean() or inserted_count == 0) {
                    // Generate a unique key.
                    const klen = 1 + random.uintAtMost(usize, 7);
                    const chars = "abcdefghijklmnop";
                    for (key_buf[0..klen]) |*c| c.* = chars[random.uintAtMost(usize, chars.len - 1)];
                    const key = key_buf[0..klen];

                    // Check if key already exists.
                    const exists = map.getValue(key) != null;
                    const result = map.put(key, "v");
                    if (result) |_| {
                        if (!exists) {
                            @memcpy(inserted_keys[inserted_count][0..klen], key);
                            inserted_lens[inserted_count] = klen;
                            inserted_count += 1;
                            expected_len += 1;
                        }
                    } else |_| {
                        // CapacityExceeded or BufferTooSmall — length unchanged.
                    }
                } else {
                    // Remove a random inserted key.
                    const idx = random.uintLessThan(usize, inserted_count);
                    const klen = inserted_lens[idx];
                    if (map.remove(inserted_keys[idx][0..klen])) {
                        expected_len -= 1;
                        inserted_count -= 1;
                        inserted_keys[idx] = inserted_keys[inserted_count];
                        inserted_lens[idx] = inserted_lens[inserted_count];
                    }
                }
                try std.testing.expectEqual(expected_len, map.length());
            }
        }
    };
    harness.property("BoundedStringMap length tracks puts minus removes", S.run);
}
