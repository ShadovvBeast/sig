const std = @import("std");
const Io = std.Io;
const sig = @import("sig");
const sig_io = sig.io;

// ── Benchmark: sig.io.readInto vs std.io reader patterns ─────────────────
// Requirements: 1.2, 1.3

const iterations: u64 = 10_000;

/// A minimal reader backed by a byte slice.
const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn read(self: *SliceReader, buf: []u8) error{}!usize {
        if (self.pos >= self.data.len) return 0;
        const remaining = self.data.len - self.pos;
        const n = @min(remaining, buf.len);
        @memcpy(buf[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    pub fn reset(self: *SliceReader) void {
        self.pos = 0;
    }
};

const small_data = "Hello, world! This is a small payload for benchmarking." ** 4;
const large_data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop" ** 80;

fn benchReadIntoSmall(io: Io) u64 {
    var reader = SliceReader{ .data = small_data };
    var buf: [512]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        reader.reset();
        _ = sig_io.readInto(&reader, &buf) catch unreachable;
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchStdReadSmall(io: Io) u64 {
    var reader = SliceReader{ .data = small_data };
    var buf: [512]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        reader.reset();
        var total: usize = 0;
        while (total < buf.len) {
            const n = reader.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchReadIntoLarge(io: Io) u64 {
    var reader = SliceReader{ .data = large_data };
    var buf: [8192]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        reader.reset();
        _ = sig_io.readInto(&reader, &buf) catch unreachable;
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchStdReadLarge(io: Io) u64 {
    var reader = SliceReader{ .data = large_data };
    var buf: [8192]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        reader.reset();
        var total: usize = 0;
        while (total < buf.len) {
            const n = reader.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchReadAtMost(io: Io) u64 {
    var reader = SliceReader{ .data = large_data };
    var buf: [8192]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        reader.reset();
        _ = sig_io.readAtMost(&reader, &buf, 256) catch unreachable;
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchStreamReader(io: Io) u64 {
    var reader = SliceReader{ .data = large_data };
    var stream = sig_io.StreamReader(256){};
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        reader.reset();
        while (stream.next(&reader)) |_| {}
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const sig_small_ns = benchReadIntoSmall(io);
    const std_small_ns = benchStdReadSmall(io);
    const sig_large_ns = benchReadIntoLarge(io);
    const std_large_ns = benchStdReadLarge(io);
    const read_at_most_ns = benchReadAtMost(io);
    const stream_ns = benchStreamReader(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\{{
        \\  "suite": "io",
        \\  "benchmarks": [
        \\    {{
        \\      "name": "readInto_vs_manual_read_small",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": {d},
        \\      "sig_peak_bytes": 512,
        \\      "std_peak_bytes": 512
        \\    }},
        \\    {{
        \\      "name": "readInto_vs_manual_read_large",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": {d},
        \\      "sig_peak_bytes": 8192,
        \\      "std_peak_bytes": 8192
        \\    }},
        \\    {{
        \\      "name": "readAtMost_256_bytes",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": 0,
        \\      "sig_peak_bytes": 256,
        \\      "std_peak_bytes": 0
        \\    }},
        \\    {{
        \\      "name": "streamReader_256_chunk",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": 0,
        \\      "sig_peak_bytes": 256,
        \\      "std_peak_bytes": 0
        \\    }}
        \\  ]
        \\}}
        \\
    , .{
        sig_small_ns / iterations,
        std_small_ns / iterations,
        sig_large_ns / iterations,
        std_large_ns / iterations,
        read_at_most_ns / iterations,
        stream_ns / iterations,
    });
    try stdout.flush();
}
