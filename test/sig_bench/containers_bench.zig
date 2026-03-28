const std = @import("std");
const Io = std.Io;
const sig = @import("sig");
const containers = sig.containers;

// ── Benchmark: sig.containers.BoundedVec vs std.ArrayList ────────────────
// Requirements: 1.2, 1.3

const iterations: u64 = 10_000;
const container_cap = 1024;

fn benchBoundedVecPushPop(io: Io) u64 {
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        var vec = containers.BoundedVec(u32, container_cap){};
        for (0..container_cap) |i| {
            vec.push(@intCast(i)) catch unreachable;
        }
        for (0..container_cap) |_| {
            _ = vec.pop();
        }
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchArrayListPushPop(io: Io) u64 {
    // ArrayList needs extra space for growth strategy (powers of 2)
    var backing: [container_cap * @sizeOf(u32) * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const alloc = fba.allocator();
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        fba.reset();
        var list: std.ArrayList(u32) = .empty;
        for (0..container_cap) |i| {
            list.append(alloc, @intCast(i)) catch unreachable;
        }
        for (0..container_cap) |_| {
            _ = list.pop();
        }
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchRingBufferPushPop(io: Io) u64 {
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        var ring = containers.RingBuffer(u32, container_cap){};
        for (0..container_cap) |i| {
            ring.push(@intCast(i)) catch unreachable;
        }
        for (0..container_cap) |_| {
            _ = ring.pop();
        }
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchBoundedVecGet(io: Io) u64 {
    var vec = containers.BoundedVec(u32, container_cap){};
    for (0..container_cap) |i| {
        vec.push(@intCast(i)) catch unreachable;
    }
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        for (0..container_cap) |i| {
            _ = vec.get(i);
        }
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const sig_push_pop_ns = benchBoundedVecPushPop(io);
    const std_push_pop_ns = benchArrayListPushPop(io);
    const ring_push_pop_ns = benchRingBufferPushPop(io);
    const vec_get_ns = benchBoundedVecGet(io);

    const sig_bytes = container_cap * @sizeOf(u32) + @sizeOf(usize);
    // ArrayList uses FixedBufferAllocator with growth overhead
    const std_bytes = container_cap * @sizeOf(u32) * 2 + @sizeOf(std.ArrayList(u32));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\{{
        \\  "suite": "containers",
        \\  "benchmarks": [
        \\    {{
        \\      "name": "BoundedVec_vs_ArrayList_push_pop",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": {d},
        \\      "sig_peak_bytes": {d},
        \\      "std_peak_bytes": {d}
        \\    }},
        \\    {{
        \\      "name": "RingBuffer_push_pop",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": 0,
        \\      "sig_peak_bytes": {d},
        \\      "std_peak_bytes": 0
        \\    }},
        \\    {{
        \\      "name": "BoundedVec_random_get",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": 0,
        \\      "sig_peak_bytes": {d},
        \\      "std_peak_bytes": 0
        \\    }}
        \\  ]
        \\}}
        \\
    , .{
        sig_push_pop_ns / iterations,
        std_push_pop_ns / iterations,
        sig_bytes,
        std_bytes,
        ring_push_pop_ns / iterations,
        sig_bytes,
        vec_get_ns / iterations,
        sig_bytes,
    });
    try stdout.flush();
}
