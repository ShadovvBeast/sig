const std = @import("std");
const SigError = @import("errors.zig").SigError;

/// A fixed-capacity vector backed by a comptime-sized array. No allocator needed.
pub fn BoundedVec(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        /// Appends an item. Returns `CapacityExceeded` when full.
        pub fn push(self: *Self, item: T) SigError!void {
            if (self.len >= capacity) return error.CapacityExceeded;
            self.items[self.len] = item;
            self.len += 1;
        }

        /// Removes and returns the last item, or null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }

        /// Returns the item at `index`, or null if out of bounds.
        pub fn get(self: *const Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.items[index];
        }

        /// Returns a slice over the live elements.
        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        /// Returns the number of live elements.
        pub fn length(self: *const Self) usize {
            return self.len;
        }

        /// Returns the comptime capacity.
        pub fn max_capacity(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

/// A fixed-capacity circular buffer. No allocator needed.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        const Self = @This();

        /// Pushes an item to the tail. Returns `CapacityExceeded` when full.
        pub fn push(self: *Self, item: T) SigError!void {
            if (self.count >= capacity) return error.CapacityExceeded;
            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count += 1;
        }

        /// Pops an item from the head, or null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }

        /// Returns the number of live elements.
        pub fn length(self: *const Self) usize {
            return self.count;
        }

        /// Returns the comptime capacity.
        pub fn max_capacity(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

/// A fixed-capacity object pool with acquire/release semantics. No allocator needed.
pub fn FixedPool(comptime T: type, comptime count: usize) type {
    return struct {
        slots: [count]T = undefined,
        free_list: [count]usize = init_free_list(),
        free_count: usize = count,

        const Self = @This();

        fn init_free_list() [count]usize {
            var list: [count]usize = undefined;
            for (0..count) |i| {
                list[i] = i;
            }
            return list;
        }

        /// Acquires a slot from the pool. Returns `CapacityExceeded` when empty.
        pub fn acquire(self: *Self) SigError!*T {
            if (self.free_count == 0) return error.CapacityExceeded;
            self.free_count -= 1;
            const idx = self.free_list[self.free_count];
            return &self.slots[idx];
        }

        /// Releases a previously acquired slot back to the pool.
        pub fn release(self: *Self, ptr: *T) void {
            const base = @intFromPtr(&self.slots[0]);
            const addr = @intFromPtr(ptr);
            const idx = (addr - base) / @sizeOf(T);
            self.free_list[self.free_count] = idx;
            self.free_count += 1;
        }

        /// Returns the number of acquired (in-use) slots.
        pub fn length(self: *const Self) usize {
            return count - self.free_count;
        }

        /// Returns the comptime capacity.
        pub fn max_capacity(self: *const Self) usize {
            _ = self;
            return count;
        }
    };
}

/// A generational slot map with stable keys. No allocator needed.
pub fn SlotMap(comptime T: type, comptime capacity: usize) type {
    return struct {
        pub const Key = struct { index: u32, generation: u32 };

        values: [capacity]T = undefined,
        generations: [capacity]u32 = [_]u32{0} ** capacity,
        free_list: [capacity]u32 = init_free_list(),
        free_count: usize = capacity,
        len: usize = 0,

        const Self = @This();

        fn init_free_list() [capacity]u32 {
            var list: [capacity]u32 = undefined;
            for (0..capacity) |i| {
                list[i] = @intCast(i);
            }
            return list;
        }

        /// Inserts a value and returns a stable key. Returns `CapacityExceeded` when full.
        pub fn insert(self: *Self, value: T) SigError!Key {
            if (self.free_count == 0) return error.CapacityExceeded;
            self.free_count -= 1;
            const idx = self.free_list[self.free_count];
            self.values[idx] = value;
            const gen = self.generations[idx];
            self.len += 1;
            return Key{ .index = idx, .generation = gen };
        }

        /// Removes the value for `key`. Returns null if the key is stale.
        pub fn remove(self: *Self, key: Key) ?T {
            const idx = key.index;
            if (idx >= capacity) return null;
            if (self.generations[idx] != key.generation) return null;
            const value = self.values[idx];
            self.generations[idx] += 1;
            self.free_list[self.free_count] = idx;
            self.free_count += 1;
            self.len -= 1;
            return value;
        }

        /// Returns a pointer to the value for `key`, or null if the key is stale.
        pub fn get(self: *const Self, key: Key) ?*const T {
            const idx = key.index;
            if (idx >= capacity) return null;
            if (self.generations[idx] != key.generation) return null;
            return &self.values[idx];
        }

        /// Returns the number of live entries.
        pub fn length(self: *const Self) usize {
            return self.len;
        }

        /// Returns the comptime capacity.
        pub fn max_capacity(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

/// A fixed-capacity double-ended queue. No allocator needed.
pub fn BoundedDeque(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        head: usize = 0,
        count: usize = 0,

        const Self = @This();

        /// Push to the back. Returns `CapacityExceeded` when full.
        pub fn pushBack(self: *Self, item: T) SigError!void {
            if (self.count >= capacity) return error.CapacityExceeded;
            self.items[(self.head + self.count) % capacity] = item;
            self.count += 1;
        }

        /// Push to the front. Returns `CapacityExceeded` when full.
        pub fn pushFront(self: *Self, item: T) SigError!void {
            if (self.count >= capacity) return error.CapacityExceeded;
            self.head = if (self.head == 0) capacity - 1 else self.head - 1;
            self.items[self.head] = item;
            self.count += 1;
        }

        /// Pop from the back, or null if empty.
        pub fn popBack(self: *Self) ?T {
            if (self.count == 0) return null;
            self.count -= 1;
            return self.items[(self.head + self.count) % capacity];
        }

        /// Pop from the front, or null if empty.
        pub fn popFront(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }

        pub fn length(self: *const Self) usize {
            return self.count;
        }

        pub fn max_capacity(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

/// A fixed-capacity binary min-heap priority queue. No allocator needed.
pub fn BoundedPriorityQueue(comptime T: type, comptime capacity: usize, comptime lessThan: fn (T, T) bool) type {
    return struct {
        items: [capacity]T = undefined,
        count: usize = 0,

        const Self = @This();

        /// Insert an item. Returns `CapacityExceeded` when full.
        pub fn push(self: *Self, item: T) SigError!void {
            if (self.count >= capacity) return error.CapacityExceeded;
            self.items[self.count] = item;
            self.siftUp(self.count);
            self.count += 1;
        }

        /// Remove and return the minimum item, or null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const top = self.items[0];
            self.count -= 1;
            if (self.count > 0) {
                self.items[0] = self.items[self.count];
                self.siftDown(0);
            }
            return top;
        }

        /// Peek at the minimum item without removing.
        pub fn peek(self: *const Self) ?T {
            if (self.count == 0) return null;
            return self.items[0];
        }

        fn siftUp(self: *Self, idx: usize) void {
            var i = idx;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (lessThan(self.items[i], self.items[parent])) {
                    const tmp = self.items[i];
                    self.items[i] = self.items[parent];
                    self.items[parent] = tmp;
                    i = parent;
                } else break;
            }
        }

        fn siftDown(self: *Self, idx: usize) void {
            var i = idx;
            while (true) {
                var smallest = i;
                const left = 2 * i + 1;
                const right = 2 * i + 2;
                if (left < self.count and lessThan(self.items[left], self.items[smallest]))
                    smallest = left;
                if (right < self.count and lessThan(self.items[right], self.items[smallest]))
                    smallest = right;
                if (smallest == i) break;
                const tmp = self.items[i];
                self.items[i] = self.items[smallest];
                self.items[smallest] = tmp;
                i = smallest;
            }
        }

        pub fn length(self: *const Self) usize {
            return self.count;
        }

        pub fn max_capacity(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

/// A fixed-capacity intrusive linked list using a pre-allocated node array. No allocator needed.
pub fn FixedLinkedList(comptime T: type, comptime capacity: usize) type {
    return struct {
        const nil: u32 = @intCast(capacity);

        const Node = struct {
            value: T = undefined,
            next: u32 = nil,
            prev: u32 = nil,
        };

        nodes: [capacity]Node = undefined,
        free_head: u32 = 0,
        list_head: u32 = nil,
        list_tail: u32 = nil,
        count: usize = 0,
        free_count: usize = capacity,

        const Self = @This();

        pub fn init() Self {
            var self = Self{};
            for (0..capacity) |i| {
                self.nodes[i].next = if (i + 1 < capacity) @intCast(i + 1) else nil;
            }
            return self;
        }

        /// Append to the back. Returns `CapacityExceeded` when full.
        pub fn pushBack(self: *Self, value: T) SigError!void {
            if (self.free_count == 0) return error.CapacityExceeded;
            const idx = self.free_head;
            self.free_head = self.nodes[idx].next;
            self.free_count -= 1;

            self.nodes[idx] = .{ .value = value, .next = nil, .prev = self.list_tail };
            if (self.list_tail != nil) {
                self.nodes[self.list_tail].next = idx;
            } else {
                self.list_head = idx;
            }
            self.list_tail = idx;
            self.count += 1;
        }

        /// Remove from the front, or null if empty.
        pub fn popFront(self: *Self) ?T {
            if (self.count == 0) return null;
            const idx = self.list_head;
            const value = self.nodes[idx].value;
            self.list_head = self.nodes[idx].next;
            if (self.list_head != nil) {
                self.nodes[self.list_head].prev = nil;
            } else {
                self.list_tail = nil;
            }
            // Return node to free list.
            self.nodes[idx].next = self.free_head;
            self.free_head = idx;
            self.free_count += 1;
            self.count -= 1;
            return value;
        }

        pub fn length(self: *const Self) usize {
            return self.count;
        }

        pub fn max_capacity(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

/// A fixed-capacity bit set. No allocator needed.
pub fn BoundedBitSet(comptime capacity: usize) type {
    const word_count = (capacity + 63) / 64;
    return struct {
        words: [word_count]u64 = [_]u64{0} ** word_count,

        const Self = @This();

        /// Set bit at `index`. Returns `CapacityExceeded` if out of range.
        pub fn set(self: *Self, index: usize) SigError!void {
            if (index >= capacity) return error.CapacityExceeded;
            self.words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
        }

        /// Clear bit at `index`. Returns `CapacityExceeded` if out of range.
        pub fn unset(self: *Self, index: usize) SigError!void {
            if (index >= capacity) return error.CapacityExceeded;
            self.words[index / 64] &= ~(@as(u64, 1) << @intCast(index % 64));
        }

        /// Test bit at `index`.
        pub fn isSet(self: *const Self, index: usize) bool {
            if (index >= capacity) return false;
            return (self.words[index / 64] & (@as(u64, 1) << @intCast(index % 64))) != 0;
        }

        /// Count of set bits.
        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (self.words) |w| total += @popCount(w);
            return total;
        }

        pub fn max_capacity(_: *const Self) usize {
            return capacity;
        }
    };
}

/// A fixed-capacity multi-array list (bounded array list of structs). No allocator needed.
pub fn BoundedMultiArrayList(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        /// Append an item. Returns `CapacityExceeded` when full.
        pub fn append(self: *Self, item: T) SigError!void {
            if (self.len >= capacity) return error.CapacityExceeded;
            self.items[self.len] = item;
            self.len += 1;
        }

        /// Get item at index, or null if out of bounds.
        pub fn get(self: *const Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.items[index];
        }

        /// Remove and return the last item, or null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }

        pub fn length(self: *const Self) usize {
            return self.len;
        }

        pub fn max_capacity(_: *const Self) usize {
            return capacity;
        }
    };
}

/// A fixed-capacity string-keyed map. No allocator needed.
/// Keys and values are stored in fixed-size inline buffers.
pub fn BoundedStringMap(comptime key_cap: usize, comptime val_cap: usize, comptime count: usize) type {
    return struct {
        const Entry = struct {
            key_buf: [key_cap]u8 = undefined,
            key_len: usize = 0,
            val_buf: [val_cap]u8 = undefined,
            val_len: usize = 0,
            occupied: bool = false,
        };

        entries: [count]Entry = [_]Entry{.{}} ** count,
        len: usize = 0,

        const Self = @This();

        /// Insert or update a key-value pair. Returns `CapacityExceeded` if full and key is new.
        /// Returns `BufferTooSmall` if key or value exceeds inline buffer capacity.
        pub fn put(self: *Self, key: []const u8, value: []const u8) SigError!void {
            if (key.len > key_cap) return error.BufferTooSmall;
            if (value.len > val_cap) return error.BufferTooSmall;

            // Check for existing key.
            for (&self.entries) |*e| {
                if (e.occupied and e.key_len == key.len and
                    std.mem.eql(u8, e.key_buf[0..e.key_len], key))
                {
                    @memcpy(e.val_buf[0..value.len], value);
                    e.val_len = value.len;
                    return;
                }
            }

            if (self.len >= count) return error.CapacityExceeded;

            // Find first empty slot.
            for (&self.entries) |*e| {
                if (!e.occupied) {
                    @memcpy(e.key_buf[0..key.len], key);
                    e.key_len = key.len;
                    @memcpy(e.val_buf[0..value.len], value);
                    e.val_len = value.len;
                    e.occupied = true;
                    self.len += 1;
                    return;
                }
            }
        }

        /// Get the value for a key, or null if not found.
        pub fn getValue(self: *const Self, key: []const u8) ?[]const u8 {
            for (&self.entries) |*e| {
                if (e.occupied and e.key_len == key.len and
                    std.mem.eql(u8, e.key_buf[0..e.key_len], key))
                {
                    return e.val_buf[0..e.val_len];
                }
            }
            return null;
        }

        /// Remove a key. Returns true if found and removed.
        pub fn remove(self: *Self, key: []const u8) bool {
            for (&self.entries) |*e| {
                if (e.occupied and e.key_len == key.len and
                    std.mem.eql(u8, e.key_buf[0..e.key_len], key))
                {
                    e.occupied = false;
                    self.len -= 1;
                    return true;
                }
            }
            return false;
        }

        pub fn length(self: *const Self) usize {
            return self.len;
        }

        pub fn max_capacity(_: *const Self) usize {
            return count;
        }
    };
}
