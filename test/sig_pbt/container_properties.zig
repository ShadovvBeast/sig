// Feature: sig-memory-model, Property 6: Bounded container length invariant
//
// For any bounded container (BoundedVec, RingBuffer, FixedPool, or SlotMap)
// and any sequence of insert and remove operations, length() shall equal the
// number of successful insertions minus the number of successful removals,
// and max_capacity() shall equal the comptime-declared capacity. When
// length() == max_capacity(), the next insertion shall return
// error.CapacityExceeded.
//
// **Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7**

const std = @import("std");
const harness = @import("harness");
const containers = @import("containers");

const CAPACITY = 16;

// ---------------------------------------------------------------------------
// Property 6 – BoundedVec length invariant
// ---------------------------------------------------------------------------

test "Property 6: BoundedVec length tracks insertions minus removals" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var vec = containers.BoundedVec(u32, CAPACITY){};
            var expected_len: usize = 0;

            // max_capacity must equal the comptime capacity.
            try std.testing.expectEqual(@as(usize, CAPACITY), vec.max_capacity());

            // Run a random sequence of push/pop operations.
            const ops = 64;
            var i: usize = 0;
            while (i < ops) : (i += 1) {
                const do_push = random.boolean();
                if (do_push) {
                    const val = random.int(u32);
                    if (vec.push(val)) |_| {
                        expected_len += 1;
                    } else |err| {
                        // Must be CapacityExceeded and container must be full.
                        try std.testing.expectEqual(error.CapacityExceeded, err);
                        try std.testing.expectEqual(@as(usize, CAPACITY), expected_len);
                    }
                } else {
                    if (vec.pop()) |_| {
                        expected_len -= 1;
                    }
                    // pop returns null when empty — length stays the same.
                }
                try std.testing.expectEqual(expected_len, vec.length());
                try std.testing.expectEqual(@as(usize, CAPACITY), vec.max_capacity());
            }
        }
    };
    harness.property("BoundedVec length tracks insertions minus removals", S.run);
}

test "Property 6: BoundedVec CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var vec = containers.BoundedVec(u8, CAPACITY){};

            // Fill to capacity.
            var i: usize = 0;
            while (i < CAPACITY) : (i += 1) {
                try vec.push(@intCast(i));
            }
            try std.testing.expectEqual(@as(usize, CAPACITY), vec.length());

            // Next push must return CapacityExceeded.
            try std.testing.expectError(error.CapacityExceeded, vec.push(0xFF));
            try std.testing.expectEqual(@as(usize, CAPACITY), vec.length());
        }
    };
    harness.property("BoundedVec CapacityExceeded when full", S.run);
}

// ---------------------------------------------------------------------------
// Property 6 – RingBuffer length invariant
// ---------------------------------------------------------------------------

test "Property 6: RingBuffer length tracks insertions minus removals" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var ring = containers.RingBuffer(u32, CAPACITY){};
            var expected_len: usize = 0;

            try std.testing.expectEqual(@as(usize, CAPACITY), ring.max_capacity());

            const ops = 64;
            var i: usize = 0;
            while (i < ops) : (i += 1) {
                const do_push = random.boolean();
                if (do_push) {
                    const val = random.int(u32);
                    if (ring.push(val)) |_| {
                        expected_len += 1;
                    } else |err| {
                        try std.testing.expectEqual(error.CapacityExceeded, err);
                        try std.testing.expectEqual(@as(usize, CAPACITY), expected_len);
                    }
                } else {
                    if (ring.pop()) |_| {
                        expected_len -= 1;
                    }
                }
                try std.testing.expectEqual(expected_len, ring.length());
                try std.testing.expectEqual(@as(usize, CAPACITY), ring.max_capacity());
            }
        }
    };
    harness.property("RingBuffer length tracks insertions minus removals", S.run);
}

test "Property 6: RingBuffer CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var ring = containers.RingBuffer(u8, CAPACITY){};

            var i: usize = 0;
            while (i < CAPACITY) : (i += 1) {
                try ring.push(@intCast(i));
            }
            try std.testing.expectEqual(@as(usize, CAPACITY), ring.length());

            try std.testing.expectError(error.CapacityExceeded, ring.push(0xFF));
            try std.testing.expectEqual(@as(usize, CAPACITY), ring.length());
        }
    };
    harness.property("RingBuffer CapacityExceeded when full", S.run);
}

// ---------------------------------------------------------------------------
// Property 6 – FixedPool length invariant
// ---------------------------------------------------------------------------

test "Property 6: FixedPool length tracks acquires minus releases" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var pool = containers.FixedPool(u64, CAPACITY){};
            var expected_len: usize = 0;

            try std.testing.expectEqual(@as(usize, CAPACITY), pool.max_capacity());

            // Track acquired pointers so we can release valid ones.
            var acquired: [CAPACITY]*u64 = undefined;
            var acquired_count: usize = 0;

            const ops = 64;
            var i: usize = 0;
            while (i < ops) : (i += 1) {
                const do_acquire = random.boolean();
                if (do_acquire) {
                    if (pool.acquire()) |ptr| {
                        acquired[acquired_count] = ptr;
                        acquired_count += 1;
                        expected_len += 1;
                    } else |err| {
                        try std.testing.expectEqual(error.CapacityExceeded, err);
                        try std.testing.expectEqual(@as(usize, CAPACITY), expected_len);
                    }
                } else {
                    if (acquired_count > 0) {
                        // Pick a random acquired pointer to release.
                        const idx = random.uintLessThan(usize, acquired_count);
                        pool.release(acquired[idx]);
                        // Swap-remove from our tracking array.
                        acquired_count -= 1;
                        acquired[idx] = acquired[acquired_count];
                        expected_len -= 1;
                    }
                }
                try std.testing.expectEqual(expected_len, pool.length());
                try std.testing.expectEqual(@as(usize, CAPACITY), pool.max_capacity());
            }
        }
    };
    harness.property("FixedPool length tracks acquires minus releases", S.run);
}

test "Property 6: FixedPool CapacityExceeded when full" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var pool = containers.FixedPool(u8, CAPACITY){};

            var i: usize = 0;
            while (i < CAPACITY) : (i += 1) {
                _ = try pool.acquire();
            }
            try std.testing.expectEqual(@as(usize, CAPACITY), pool.length());

            try std.testing.expectError(error.CapacityExceeded, pool.acquire());
            try std.testing.expectEqual(@as(usize, CAPACITY), pool.length());
        }
    };
    harness.property("FixedPool CapacityExceeded when full", S.run);
}

// ---------------------------------------------------------------------------
// Property 6 – SlotMap length invariant
// ---------------------------------------------------------------------------

test "Property 6: SlotMap length tracks inserts minus removes" {
    const SlotMap = containers.SlotMap(u32, CAPACITY);
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var map = SlotMap{};
            var expected_len: usize = 0;

            try std.testing.expectEqual(@as(usize, CAPACITY), map.max_capacity());

            // Track keys so we can remove valid ones.
            var keys: [CAPACITY]SlotMap.Key = undefined;
            var key_count: usize = 0;

            const ops = 64;
            var i: usize = 0;
            while (i < ops) : (i += 1) {
                const do_insert = random.boolean();
                if (do_insert) {
                    const val = random.int(u32);
                    if (map.insert(val)) |key| {
                        keys[key_count] = key;
                        key_count += 1;
                        expected_len += 1;
                    } else |err| {
                        try std.testing.expectEqual(error.CapacityExceeded, err);
                        try std.testing.expectEqual(@as(usize, CAPACITY), expected_len);
                    }
                } else {
                    if (key_count > 0) {
                        // Pick a random key to remove.
                        const idx = random.uintLessThan(usize, key_count);
                        const removed = map.remove(keys[idx]);
                        // The key should be valid (not stale), so remove must succeed.
                        try std.testing.expect(removed != null);
                        // Swap-remove from our tracking array.
                        key_count -= 1;
                        keys[idx] = keys[key_count];
                        expected_len -= 1;
                    }
                }
                try std.testing.expectEqual(expected_len, map.length());
                try std.testing.expectEqual(@as(usize, CAPACITY), map.max_capacity());
            }
        }
    };
    harness.property("SlotMap length tracks inserts minus removes", S.run);
}

test "Property 6: SlotMap CapacityExceeded when full" {
    const SlotMap = containers.SlotMap(u32, CAPACITY);
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            var map = SlotMap{};

            var i: usize = 0;
            while (i < CAPACITY) : (i += 1) {
                _ = try map.insert(@intCast(i));
            }
            try std.testing.expectEqual(@as(usize, CAPACITY), map.length());

            try std.testing.expectError(error.CapacityExceeded, map.insert(0xFFFF));
            try std.testing.expectEqual(@as(usize, CAPACITY), map.length());
        }
    };
    harness.property("SlotMap CapacityExceeded when full", S.run);
}
