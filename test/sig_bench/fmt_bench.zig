const std = @import("std");
const Io = std.Io;
const sig = @import("sig");
const sig_fmt = sig.fmt;

// ── Benchmark: sig.fmt.formatInto vs std.fmt.bufPrint ────────────────────
// Requirements: 1.2, 1.3

const iterations: u64 = 10_000;

fn benchFormatIntoSmall(io: Io) u64 {
    var buf: [128]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |i| {
        _ = sig_fmt.formatInto(&buf, "hello {d} world", .{i}) catch unreachable;
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchBufPrintSmall(io: Io) u64 {
    var buf: [128]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |i| {
        _ = std.fmt.bufPrint(&buf, "hello {d} world", .{i}) catch unreachable;
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchFormatIntoLarge(io: Io) u64 {
    var buf: [4096]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |i| {
        _ = sig_fmt.formatInto(&buf, "item[{d}]: name={s} value={d} active={}", .{
            i, "benchmark_entry", i * 42, i % 2 == 0,
        }) catch unreachable;
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchBufPrintLarge(io: Io) u64 {
    var buf: [4096]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |i| {
        _ = std.fmt.bufPrint(&buf, "item[{d}]: name={s} value={d} active={}", .{
            i, "benchmark_entry", i * 42, i % 2 == 0,
        }) catch unreachable;
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchMeasureFormat(io: Io) u64 {
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |i| {
        _ = sig_fmt.measureFormat("hello {d} world", .{i});
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const sig_small_ns = benchFormatIntoSmall(io);
    const std_small_ns = benchBufPrintSmall(io);
    const sig_large_ns = benchFormatIntoLarge(io);
    const std_large_ns = benchBufPrintLarge(io);
    const measure_ns = benchMeasureFormat(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\{{
        \\  "suite": "fmt",
        \\  "benchmarks": [
        \\    {{
        \\      "name": "formatInto_vs_bufPrint_small",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": {d},
        \\      "sig_peak_bytes": 128,
        \\      "std_peak_bytes": 128
        \\    }},
        \\    {{
        \\      "name": "formatInto_vs_bufPrint_large",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": {d},
        \\      "sig_peak_bytes": 4096,
        \\      "std_peak_bytes": 4096
        \\    }},
        \\    {{
        \\      "name": "measureFormat_overhead",
        \\      "sig_ns_per_op": {d},
        \\      "std_ns_per_op": 0,
        \\      "sig_peak_bytes": 0,
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
        measure_ns / iterations,
    });
    try stdout.flush();
}
