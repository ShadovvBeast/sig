// Unit tests for extended bounded containers
// Requirements: 16.1, 16.2, 16.3, 16.4, 16.5, 16.6, 16.7

const std = @import("std");
const testing = std.testing;
const containers = @import("containers");

// ── BoundedDeque tests ───────────────────────────────────────────────────

test "BoundedDeque pushBack/popFront FIFO order" {
    var deque = containers.BoundedDeque(u32, 4){};
    try deque.pushBack(1);
    try deque.pushBack(2);
    try deque.pushBack(3);
    try testing.expectEqual(@as(u32, 1), deque.popFront().?);
    try testing.expectEqual(@as(u32, 2), deque.popFront().?);
    try testing.expectEqual(@as(u32, 3), deque.popFront().?);
    try testing.expectEqual(@as(?u32, null), deque.popFront());
}

test "BoundedDeque pushFront/popBack FIFO order" {
    var deque = containers.BoundedDeque(u32, 4){};
    try deque.pushFront(1);
    try deque.pushFront(2);
    try deque.pushFront(3);
    try testing.expectEqual(@as(u32, 1), deque.popBack().?);
    try testing.expectEqual(@as(u32, 2), deque.popBack().?);
    try testing.expectEqual(@as(u32, 3), deque.popBack().?);
}

test "BoundedDeque CapacityExceeded" {
    var deque = containers.BoundedDeque(u8, 2){};
    try deque.pushBack(1);
    try deque.pushBack(2);
    try testing.expectError(error.CapacityExceeded, deque.pushBack(3));
    try testing.expectError(error.CapacityExceeded, deque.pushFront(3));
}

// ── BoundedPriorityQueue tests ───────────────────────────────────────────

fn u32Less(a: u32, b: u32) bool {
    return a < b;
}

test "BoundedPriorityQueue pops minimum first" {
    var pq = containers.BoundedPriorityQueue(u32, 8, u32Less){};
    try pq.push(5);
    try pq.push(1);
    try pq.push(3);
    try testing.expectEqual(@as(u32, 1), pq.pop().?);
    try testing.expectEqual(@as(u32, 3), pq.pop().?);
    try testing.expectEqual(@as(u32, 5), pq.pop().?);
    try testing.expectEqual(@as(?u32, null), pq.pop());
}

test "BoundedPriorityQueue peek returns minimum without removing" {
    var pq = containers.BoundedPriorityQueue(u32, 4, u32Less){};
    try pq.push(10);
    try pq.push(2);
    try testing.expectEqual(@as(u32, 2), pq.peek().?);
    try testing.expectEqual(@as(usize, 2), pq.length());
}

test "BoundedPriorityQueue CapacityExceeded" {
    var pq = containers.BoundedPriorityQueue(u32, 2, u32Less){};
    try pq.push(1);
    try pq.push(2);
    try testing.expectError(error.CapacityExceeded, pq.push(3));
}

// ── FixedLinkedList tests ────────────────────────────────────────────────

test "FixedLinkedList pushBack/popFront FIFO order" {
    var list = containers.FixedLinkedList(u32, 4).init();
    try list.pushBack(10);
    try list.pushBack(20);
    try list.pushBack(30);
    try testing.expectEqual(@as(u32, 10), list.popFront().?);
    try testing.expectEqual(@as(u32, 20), list.popFront().?);
    try testing.expectEqual(@as(u32, 30), list.popFront().?);
    try testing.expectEqual(@as(?u32, null), list.popFront());
}

test "FixedLinkedList CapacityExceeded" {
    var list = containers.FixedLinkedList(u8, 2).init();
    try list.pushBack(1);
    try list.pushBack(2);
    try testing.expectError(error.CapacityExceeded, list.pushBack(3));
}

test "FixedLinkedList reuses freed nodes" {
    var list = containers.FixedLinkedList(u32, 2).init();
    try list.pushBack(1);
    try list.pushBack(2);
    _ = list.popFront();
    try list.pushBack(3); // should succeed — freed slot reused
    try testing.expectEqual(@as(usize, 2), list.length());
}

// ── BoundedBitSet tests ──────────────────────────────────────────────────

test "BoundedBitSet set and isSet" {
    var bs = containers.BoundedBitSet(64){};
    try bs.set(0);
    try bs.set(63);
    try testing.expect(bs.isSet(0));
    try testing.expect(bs.isSet(63));
    try testing.expect(!bs.isSet(1));
    try testing.expectEqual(@as(usize, 2), bs.count());
}

test "BoundedBitSet unset clears bit" {
    var bs = containers.BoundedBitSet(64){};
    try bs.set(5);
    try testing.expect(bs.isSet(5));
    try bs.unset(5);
    try testing.expect(!bs.isSet(5));
    try testing.expectEqual(@as(usize, 0), bs.count());
}

test "BoundedBitSet CapacityExceeded on out-of-range" {
    var bs = containers.BoundedBitSet(8){};
    try testing.expectError(error.CapacityExceeded, bs.set(8));
    try testing.expectError(error.CapacityExceeded, bs.unset(100));
}

// ── BoundedMultiArrayList tests ──────────────────────────────────────────

const Point = struct { x: u32, y: u32 };

test "BoundedMultiArrayList append and get" {
    var mal = containers.BoundedMultiArrayList(Point, 4){};
    try mal.append(.{ .x = 1, .y = 2 });
    try mal.append(.{ .x = 3, .y = 4 });
    const p = mal.get(0).?;
    try testing.expectEqual(@as(u32, 1), p.x);
    try testing.expectEqual(@as(u32, 2), p.y);
    try testing.expectEqual(@as(usize, 2), mal.length());
}

test "BoundedMultiArrayList pop returns last item" {
    var mal = containers.BoundedMultiArrayList(Point, 4){};
    try mal.append(.{ .x = 10, .y = 20 });
    try mal.append(.{ .x = 30, .y = 40 });
    const p = mal.pop().?;
    try testing.expectEqual(@as(u32, 30), p.x);
    try testing.expectEqual(@as(usize, 1), mal.length());
}

test "BoundedMultiArrayList CapacityExceeded" {
    var mal = containers.BoundedMultiArrayList(Point, 1){};
    try mal.append(.{ .x = 1, .y = 1 });
    try testing.expectError(error.CapacityExceeded, mal.append(.{ .x = 2, .y = 2 }));
}

// ── BoundedStringMap tests ───────────────────────────────────────────────

test "BoundedStringMap put and getValue" {
    var map = containers.BoundedStringMap(16, 16, 4){};
    try map.put("key1", "val1");
    try map.put("key2", "val2");
    try testing.expectEqualStrings("val1", map.getValue("key1").?);
    try testing.expectEqualStrings("val2", map.getValue("key2").?);
    try testing.expectEqual(@as(?[]const u8, null), map.getValue("key3"));
}

test "BoundedStringMap put updates existing key" {
    var map = containers.BoundedStringMap(16, 16, 4){};
    try map.put("k", "old");
    try map.put("k", "new");
    try testing.expectEqualStrings("new", map.getValue("k").?);
    try testing.expectEqual(@as(usize, 1), map.length());
}

test "BoundedStringMap remove" {
    var map = containers.BoundedStringMap(16, 16, 4){};
    try map.put("a", "1");
    try testing.expect(map.remove("a"));
    try testing.expectEqual(@as(?[]const u8, null), map.getValue("a"));
    try testing.expectEqual(@as(usize, 0), map.length());
}

test "BoundedStringMap CapacityExceeded" {
    var map = containers.BoundedStringMap(16, 16, 2){};
    try map.put("a", "1");
    try map.put("b", "2");
    try testing.expectError(error.CapacityExceeded, map.put("c", "3"));
}

test "BoundedStringMap BufferTooSmall for oversized key" {
    var map = containers.BoundedStringMap(4, 4, 2){};
    try testing.expectError(error.BufferTooSmall, map.put("toolong", "v"));
}
