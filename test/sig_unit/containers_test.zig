const std = @import("std");
const testing = std.testing;
const containers = @import("containers");

// ── Unit Tests for BoundedVec, RingBuffer, FixedPool, SlotMap ────────────
// Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7

// ── BoundedVec ───────────────────────────────────────────────────────────

test "BoundedVec: push 3 items, length is 3, slice returns correct items" {
    var vec = containers.BoundedVec(u32, 4){};
    try vec.push(10);
    try vec.push(20);
    try vec.push(30);
    try testing.expectEqual(@as(usize, 3), vec.length());
    const s = vec.slice();
    try testing.expectEqual(@as(u32, 10), s[0]);
    try testing.expectEqual(@as(u32, 20), s[1]);
    try testing.expectEqual(@as(u32, 30), s[2]);
}

test "BoundedVec: pop returns items in LIFO order" {
    var vec = containers.BoundedVec(u32, 4){};
    try vec.push(1);
    try vec.push(2);
    try vec.push(3);
    try testing.expectEqual(@as(u32, 3), vec.pop().?);
    try testing.expectEqual(@as(u32, 2), vec.pop().?);
    try testing.expectEqual(@as(u32, 1), vec.pop().?);
}

test "BoundedVec: get returns correct item, null for out-of-bounds" {
    var vec = containers.BoundedVec(u32, 4){};
    try vec.push(42);
    try vec.push(99);
    try testing.expectEqual(@as(u32, 42), vec.get(0).?);
    try testing.expectEqual(@as(u32, 99), vec.get(1).?);
    try testing.expectEqual(@as(?u32, null), vec.get(2));
    try testing.expectEqual(@as(?u32, null), vec.get(100));
}

test "BoundedVec: push on full container returns CapacityExceeded" {
    var vec = containers.BoundedVec(u8, 4){};
    try vec.push(1);
    try vec.push(2);
    try vec.push(3);
    try vec.push(4);
    try testing.expectError(error.CapacityExceeded, vec.push(5));
    try testing.expectEqual(@as(usize, 4), vec.length());
}

test "BoundedVec: pop on empty container returns null" {
    var vec = containers.BoundedVec(u8, 4){};
    try testing.expectEqual(@as(?u8, null), vec.pop());
}

// ── RingBuffer ───────────────────────────────────────────────────────────

test "RingBuffer: push/pop FIFO order" {
    var ring = containers.RingBuffer(u32, 4){};
    try ring.push(10);
    try ring.push(20);
    try ring.push(30);
    try testing.expectEqual(@as(u32, 10), ring.pop().?);
    try testing.expectEqual(@as(u32, 20), ring.pop().?);
    try testing.expectEqual(@as(u32, 30), ring.pop().?);
}

test "RingBuffer: wrap-around preserves FIFO" {
    var ring = containers.RingBuffer(u32, 4){};
    // Fill completely
    try ring.push(1);
    try ring.push(2);
    try ring.push(3);
    try ring.push(4);
    // Pop two to make room
    try testing.expectEqual(@as(u32, 1), ring.pop().?);
    try testing.expectEqual(@as(u32, 2), ring.pop().?);
    // Push two more (wraps around internal array)
    try ring.push(5);
    try ring.push(6);
    // Verify FIFO order
    try testing.expectEqual(@as(u32, 3), ring.pop().?);
    try testing.expectEqual(@as(u32, 4), ring.pop().?);
    try testing.expectEqual(@as(u32, 5), ring.pop().?);
    try testing.expectEqual(@as(u32, 6), ring.pop().?);
}

test "RingBuffer: push on full returns CapacityExceeded" {
    var ring = containers.RingBuffer(u8, 4){};
    try ring.push(1);
    try ring.push(2);
    try ring.push(3);
    try ring.push(4);
    try testing.expectError(error.CapacityExceeded, ring.push(5));
    try testing.expectEqual(@as(usize, 4), ring.length());
}

test "RingBuffer: pop on empty returns null" {
    var ring = containers.RingBuffer(u8, 4){};
    try testing.expectEqual(@as(?u8, null), ring.pop());
}

// ── FixedPool ────────────────────────────────────────────────────────────

test "FixedPool: acquire returns valid pointers" {
    var pool = containers.FixedPool(u32, 4){};
    const p1 = try pool.acquire();
    const p2 = try pool.acquire();
    p1.* = 100;
    p2.* = 200;
    try testing.expectEqual(@as(u32, 100), p1.*);
    try testing.expectEqual(@as(u32, 200), p2.*);
    try testing.expectEqual(@as(usize, 2), pool.length());
}

test "FixedPool: release and re-acquire works" {
    var pool = containers.FixedPool(u32, 4){};
    const p1 = try pool.acquire();
    p1.* = 42;
    pool.release(p1);
    try testing.expectEqual(@as(usize, 0), pool.length());
    const p2 = try pool.acquire();
    // Should get a valid pointer back (may be same slot)
    p2.* = 99;
    try testing.expectEqual(@as(u32, 99), p2.*);
    try testing.expectEqual(@as(usize, 1), pool.length());
}

test "FixedPool: acquire on full pool returns CapacityExceeded" {
    var pool = containers.FixedPool(u8, 4){};
    _ = try pool.acquire();
    _ = try pool.acquire();
    _ = try pool.acquire();
    _ = try pool.acquire();
    try testing.expectError(error.CapacityExceeded, pool.acquire());
    try testing.expectEqual(@as(usize, 4), pool.length());
}

// ── SlotMap ──────────────────────────────────────────────────────────────

test "SlotMap: insert and get returns correct value" {
    var map = containers.SlotMap(u32, 4){};
    const key = try map.insert(42);
    const val = map.get(key);
    try testing.expect(val != null);
    try testing.expectEqual(@as(u32, 42), val.?.*);
}

test "SlotMap: remove invalidates key" {
    var map = containers.SlotMap(u32, 4){};
    const key = try map.insert(42);
    const removed = map.remove(key);
    try testing.expectEqual(@as(u32, 42), removed.?);
    // get with old key returns null
    try testing.expectEqual(@as(?*const u32, null), map.get(key));
}

test "SlotMap: generation counter — old key returns null after slot reuse" {
    var map = containers.SlotMap(u32, 4){};
    const key1 = try map.insert(100);
    _ = map.remove(key1);
    // Insert again — may reuse the same slot with bumped generation
    const key2 = try map.insert(200);
    // Old key must be stale
    try testing.expectEqual(@as(?*const u32, null), map.get(key1));
    // New key must work
    const val = map.get(key2);
    try testing.expect(val != null);
    try testing.expectEqual(@as(u32, 200), val.?.*);
}

test "SlotMap: insert on full returns CapacityExceeded" {
    var map = containers.SlotMap(u32, 4){};
    _ = try map.insert(1);
    _ = try map.insert(2);
    _ = try map.insert(3);
    _ = try map.insert(4);
    try testing.expectError(error.CapacityExceeded, map.insert(5));
    try testing.expectEqual(@as(usize, 4), map.length());
}
