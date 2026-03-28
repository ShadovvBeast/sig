const std = @import("std");
const sig = @import("sig");
const sig_fmt = sig.fmt;
const sig_io = sig.io;

/// Sig Standard Library Coverage Analyzer
///
/// Reports what percentage of the Zig standard library has a
/// capacity-first Sig equivalent. Pure Sig — stack buffers, no allocators.
///
/// Run: zig build run-sig-coverage
const Coverage = enum { covered, not_needed, not_covered };

const ModuleEntry = struct {
    std_name: []const u8,
    sig_name: []const u8,
    coverage: Coverage,
    note: []const u8,
};

const module_map = [_]ModuleEntry{
    // ── Covered by sig ──
    .{ .std_name = "fmt", .sig_name = "sig.fmt", .coverage = .covered, .note = "formatInto, measureFormat" },
    .{ .std_name = "Io", .sig_name = "sig.io", .coverage = .covered, .note = "readInto, readAtMost, StreamReader, writeAll" },
    .{ .std_name = "array_list", .sig_name = "sig.containers", .coverage = .covered, .note = "BoundedVec" },
    .{ .std_name = "hash_map", .sig_name = "sig.containers", .coverage = .covered, .note = "SlotMap" },
    .{ .std_name = "array_hash_map", .sig_name = "sig.containers", .coverage = .covered, .note = "SlotMap" },
    .{ .std_name = "json", .sig_name = "sig.json", .coverage = .covered, .note = "Tokenizer, extractString, extractInt, Writer" },

    // ── Not needed (no allocator usage) ──
    .{ .std_name = "ascii", .sig_name = "-", .coverage = .not_needed, .note = "pure functions" },
    .{ .std_name = "atomic", .sig_name = "-", .coverage = .not_needed, .note = "hardware primitives" },
    .{ .std_name = "base64", .sig_name = "-", .coverage = .not_needed, .note = "encode/decode into caller slices" },
    .{ .std_name = "BitStack", .sig_name = "-", .coverage = .not_needed, .note = "stack-based" },
    .{ .std_name = "Build", .sig_name = "-", .coverage = .not_needed, .note = "build system" },
    .{ .std_name = "builtin", .sig_name = "-", .coverage = .not_needed, .note = "comptime constants" },
    .{ .std_name = "c", .sig_name = "-", .coverage = .not_needed, .note = "C ABI bindings" },
    .{ .std_name = "coff", .sig_name = "-", .coverage = .not_needed, .note = "binary format" },
    .{ .std_name = "crypto", .sig_name = "-", .coverage = .not_needed, .note = "fixed-size operations" },
    .{ .std_name = "debug", .sig_name = "-", .coverage = .not_needed, .note = "debug tooling" },
    .{ .std_name = "dwarf", .sig_name = "-", .coverage = .not_needed, .note = "debug format" },
    .{ .std_name = "elf", .sig_name = "-", .coverage = .not_needed, .note = "binary format" },
    .{ .std_name = "enums", .sig_name = "-", .coverage = .not_needed, .note = "comptime utilities" },
    .{ .std_name = "gpu", .sig_name = "-", .coverage = .not_needed, .note = "GPU interface" },
    .{ .std_name = "hash", .sig_name = "-", .coverage = .not_needed, .note = "fixed-size hash functions" },
    .{ .std_name = "leb128", .sig_name = "-", .coverage = .not_needed, .note = "encoding" },
    .{ .std_name = "log", .sig_name = "-", .coverage = .not_needed, .note = "logging facade" },
    .{ .std_name = "macho", .sig_name = "-", .coverage = .not_needed, .note = "binary format" },
    .{ .std_name = "math", .sig_name = "-", .coverage = .not_needed, .note = "pure math" },
    .{ .std_name = "mem", .sig_name = "-", .coverage = .not_needed, .note = "slice utilities" },
    .{ .std_name = "meta", .sig_name = "-", .coverage = .not_needed, .note = "comptime reflection" },
    .{ .std_name = "os", .sig_name = "-", .coverage = .not_needed, .note = "OS constants" },
    .{ .std_name = "pdb", .sig_name = "-", .coverage = .not_needed, .note = "debug format" },
    .{ .std_name = "pie", .sig_name = "-", .coverage = .not_needed, .note = "PIE support" },
    .{ .std_name = "posix", .sig_name = "-", .coverage = .not_needed, .note = "syscall wrappers" },
    .{ .std_name = "Random", .sig_name = "-", .coverage = .not_needed, .note = "PRNG" },
    .{ .std_name = "SemanticVersion", .sig_name = "-", .coverage = .not_needed, .note = "small struct" },
    .{ .std_name = "simd", .sig_name = "-", .coverage = .not_needed, .note = "SIMD intrinsics" },
    .{ .std_name = "sort", .sig_name = "-", .coverage = .not_needed, .note = "in-place sorting" },
    .{ .std_name = "start", .sig_name = "-", .coverage = .not_needed, .note = "entry point glue" },
    .{ .std_name = "static_string_map", .sig_name = "-", .coverage = .not_needed, .note = "comptime map" },
    .{ .std_name = "Target", .sig_name = "-", .coverage = .not_needed, .note = "comptime target info" },
    .{ .std_name = "testing", .sig_name = "-", .coverage = .not_needed, .note = "test framework" },
    .{ .std_name = "time", .sig_name = "-", .coverage = .not_needed, .note = "clock functions" },
    .{ .std_name = "treap", .sig_name = "-", .coverage = .not_needed, .note = "intrusive data structure" },
    .{ .std_name = "tz", .sig_name = "-", .coverage = .not_needed, .note = "timezone data" },
    .{ .std_name = "unicode", .sig_name = "-", .coverage = .not_needed, .note = "lookup tables" },
    .{ .std_name = "valgrind", .sig_name = "-", .coverage = .not_needed, .note = "valgrind client requests" },
    .{ .std_name = "wasm", .sig_name = "-", .coverage = .not_needed, .note = "wasm format" },
    .{ .std_name = "zig", .sig_name = "-", .coverage = .not_needed, .note = "zig format tooling" },

    // ── Not covered (uses allocators, needs sig) ──
    .{ .std_name = "http", .sig_name = "sig.http", .coverage = .covered, .note = "parseUri, buildRequest, parseResponse, get, post, Server" },
    .{ .std_name = "fs", .sig_name = "sig.fs", .coverage = .covered, .note = "readFile, writeFile, joinPath, listDir" },
    .{ .std_name = "process", .sig_name = "TODO", .coverage = .not_covered, .note = "needs sig.process" },
    .{ .std_name = "compress", .sig_name = "sig.compress", .coverage = .covered, .note = "Decompressor, Compressor (deflate, gzip, zstd)" },
    .{ .std_name = "heap", .sig_name = "TODO", .coverage = .not_covered, .note = "sig replaces with bounded patterns" },
    .{ .std_name = "dynamic_library", .sig_name = "TODO", .coverage = .not_covered, .note = "needs sig.dynamic_library" },
    .{ .std_name = "Thread", .sig_name = "TODO", .coverage = .not_covered, .note = "needs sig.Thread" },
    .{ .std_name = "Progress", .sig_name = "TODO", .coverage = .not_covered, .note = "needs sig.Progress" },
    .{ .std_name = "deque", .sig_name = "sig.containers", .coverage = .covered, .note = "BoundedDeque" },
    .{ .std_name = "priority_queue", .sig_name = "sig.containers", .coverage = .covered, .note = "BoundedPriorityQueue" },
    .{ .std_name = "priority_dequeue", .sig_name = "sig.containers", .coverage = .covered, .note = "BoundedDeque (double-ended)" },
    .{ .std_name = "DoublyLinkedList", .sig_name = "sig.containers", .coverage = .covered, .note = "FixedLinkedList" },
    .{ .std_name = "SinglyLinkedList", .sig_name = "sig.containers", .coverage = .covered, .note = "FixedLinkedList" },
    .{ .std_name = "buf_map", .sig_name = "sig.containers", .coverage = .covered, .note = "BoundedStringMap" },
    .{ .std_name = "buf_set", .sig_name = "sig.containers", .coverage = .covered, .note = "BoundedStringMap (keys only)" },
    .{ .std_name = "bit_set", .sig_name = "sig.containers", .coverage = .covered, .note = "BoundedBitSet" },
    .{ .std_name = "multi_array_list", .sig_name = "sig.containers", .coverage = .covered, .note = "BoundedMultiArrayList" },
    .{ .std_name = "tar", .sig_name = "sig.tar", .coverage = .covered, .note = "TarReader streaming parser" },
    .{ .std_name = "zip", .sig_name = "sig.zip", .coverage = .covered, .note = "ZipReader streaming parser" },
    .{ .std_name = "zon", .sig_name = "sig.zon", .coverage = .covered, .note = "parseZon into caller buffer" },
    .{ .std_name = "Uri", .sig_name = "sig.uri", .coverage = .covered, .note = "parseUri into fixed struct" },
};

var w: sig_io.FdWriter = undefined;

fn out(s: []const u8) void {
    sig_io.writeAll(w, s) catch {};
}

fn outFmt(buf: []u8, comptime fmt_str: []const u8, args: anytype) void {
    sig_io.writeFormatted(w, buf, fmt_str, args) catch {};
}

pub fn main(init: std.process.Init) !void {
    w = sig_io.stdoutWriter(init.io);
    var buf: [512]u8 = undefined;

    var covered: usize = 0;
    var not_needed: usize = 0;
    var not_covered: usize = 0;

    for (module_map) |entry| {
        switch (entry.coverage) {
            .covered => covered += 1,
            .not_needed => not_needed += 1,
            .not_covered => not_covered += 1,
        }
    }

    const total = module_map.len;
    const needs_sig = covered + not_covered;
    const pct_alloc = if (needs_sig > 0) covered * 100 / needs_sig else 0;
    const pct_total = (covered + not_needed) * 100 / total;

    out("\n");
    out("========================================================\n");
    out("         Sig Standard Library Coverage Report\n");
    out("========================================================\n\n");

    outFmt(&buf, "  Total std modules:          {d}\n", .{total});
    outFmt(&buf, "  Covered by sig:             {d}\n", .{covered});
    outFmt(&buf, "  Not needed (no allocators): {d}\n", .{not_needed});
    outFmt(&buf, "  Not covered (needs sig):    {d}\n", .{not_covered});
    out("\n");
    outFmt(&buf, "  Coverage (allocator-using): {d}/{d} ({d}%)\n", .{ covered, needs_sig, pct_alloc });
    outFmt(&buf, "  Coverage (all modules):     {d}/{d} ({d}%)\n", .{ covered + not_needed, total, pct_total });

    out("\n  -- Covered -------------------------------------------\n");
    for (module_map) |entry| {
        if (entry.coverage == .covered) {
            outFmt(&buf, "  + std.{s} -> {s}  ({s})\n", .{ entry.std_name, entry.sig_name, entry.note });
        }
    }

    out("\n  -- Not Covered (needs sig) ---------------------------\n");
    for (module_map) |entry| {
        if (entry.coverage == .not_covered) {
            outFmt(&buf, "  - std.{s}  {s}\n", .{ entry.std_name, entry.note });
        }
    }

    out("\n  -- Not Needed (already allocator-free) ----------------\n");
    for (module_map) |entry| {
        if (entry.coverage == .not_needed) {
            outFmt(&buf, "  . std.{s}  {s}\n", .{ entry.std_name, entry.note });
        }
    }

    out("\n");
}
