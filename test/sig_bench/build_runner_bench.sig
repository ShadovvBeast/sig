// Benchmarks for the sig build runner components.
// Measures throughput of core data structures at production capacities.
// Requirements: 16.5, 16.6, 16.8

const std = @import("std");
const Io = std.Io;
const sig = @import("sig");
const containers = sig.containers;
const sig_fs = sig.fs;

// ── Error set ───────────────────────────────────────────────────────────
const SigError = error{ CapacityExceeded, BufferTooSmall, DepthExceeded, QuotaExceeded };

// ── Production capacity constants ───────────────────────────────────────
const MAX_STEPS = 256;
const MAX_DEPS_PER_STEP = 32;
const MAX_MODULES = 128;
const MAX_IMPORTS_PER_MODULE = 64;
const MAX_OPTIONS = 128;
const MAX_CACHE_ENTRIES = 4096;
const PATH_BUF_SIZE = 4096;
const NAME_BUF_SIZE = 64;
const DESC_BUF_SIZE = 256;
const VALUE_BUF_SIZE = 256;
const HASH_CHUNK_SIZE = 8192;

const path_sep = std.fs.path.sep;

// ── Type aliases ────────────────────────────────────────────────────────
const Step_Handle = u16;
const Module_Handle = u16;
const Content_Hash = [16]u8;

// ── Replicated Step types ───────────────────────────────────────────────

const Step_State = enum { pending, ready, running, succeeded, failed, skipped };

const StepFn = *const fn (*Step_Context) SigError!void;

const Step_Context = struct {
    step_handle: Step_Handle,
};

fn noopStep(_: *Step_Context) SigError!void {}

const Step_Entry = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    desc: [DESC_BUF_SIZE]u8 = undefined,
    desc_len: usize = 0,
    make_fn: StepFn = &noopStep,
    deps: [MAX_DEPS_PER_STEP]Step_Handle = undefined,
    dep_count: usize = 0,
    state: Step_State = .pending,
};

const Step_Registry = struct {
    entries: [MAX_STEPS]Step_Entry = undefined,
    count: usize = 0,

    pub fn register(self: *Step_Registry, name: []const u8, desc: []const u8, make_fn: StepFn) SigError!Step_Handle {
        if (name.len > NAME_BUF_SIZE) return error.BufferTooSmall;
        if (desc.len > DESC_BUF_SIZE) return error.BufferTooSmall;
        if (self.count >= MAX_STEPS) return error.CapacityExceeded;

        for (self.entries[0..self.count]) |*entry| {
            if (entry.name_len == name.len and std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return error.CapacityExceeded;
            }
        }

        const idx = self.count;
        var entry = &self.entries[idx];
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;
        @memcpy(entry.desc[0..desc.len], desc);
        entry.desc_len = desc.len;
        entry.make_fn = make_fn;
        entry.dep_count = 0;
        entry.state = .pending;
        self.count += 1;

        return @intCast(idx);
    }

    pub fn addDep(self: *Step_Registry, step: Step_Handle, dep: Step_Handle) SigError!void {
        const step_idx: usize = step;
        if (step_idx >= self.count) return error.CapacityExceeded;

        var entry = &self.entries[step_idx];
        if (entry.dep_count >= MAX_DEPS_PER_STEP) return error.CapacityExceeded;

        entry.deps[entry.dep_count] = dep;
        entry.dep_count += 1;
    }
};

// ── Replicated Module types ─────────────────────────────────────────────

const Import_Entry = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    path: [PATH_BUF_SIZE]u8 = undefined,
    path_len: usize = 0,
};

const Module_Entry = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    source_path: [PATH_BUF_SIZE]u8 = undefined,
    source_path_len: usize = 0,
    imports: [MAX_IMPORTS_PER_MODULE]Import_Entry = undefined,
    import_count: usize = 0,
};

const Module_Registry = struct {
    entries: [MAX_MODULES]Module_Entry = undefined,
    count: usize = 0,

    pub fn register(self: *Module_Registry, name: []const u8, source_path: []const u8) SigError!Module_Handle {
        if (name.len > NAME_BUF_SIZE) return error.BufferTooSmall;
        if (source_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        if (self.count >= MAX_MODULES) return error.CapacityExceeded;

        for (self.entries[0..self.count]) |*entry| {
            if (entry.name_len == name.len and std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return error.CapacityExceeded;
            }
        }

        const idx = self.count;
        var entry = &self.entries[idx];
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;
        @memcpy(entry.source_path[0..source_path.len], source_path);
        entry.source_path_len = source_path.len;
        entry.import_count = 0;
        self.count += 1;

        return @intCast(idx);
    }

    pub fn addImport(self: *Module_Registry, module: Module_Handle, name: []const u8, imp_path: []const u8) SigError!void {
        const mod_idx: usize = module;
        if (mod_idx >= self.count) return error.CapacityExceeded;

        if (name.len > NAME_BUF_SIZE) return error.BufferTooSmall;
        if (imp_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;

        var entry = &self.entries[mod_idx];
        if (entry.import_count >= MAX_IMPORTS_PER_MODULE) return error.CapacityExceeded;

        var imp = &entry.imports[entry.import_count];
        @memcpy(imp.name[0..name.len], name);
        imp.name_len = name.len;
        @memcpy(imp.path[0..imp_path.len], imp_path);
        imp.path_len = imp_path.len;
        entry.import_count += 1;
    }
};

// ── Replicated Dependency_Graph ─────────────────────────────────────────

const Dependency_Graph = struct {
    adj: [MAX_STEPS][MAX_DEPS_PER_STEP]Step_Handle = undefined,
    adj_counts: [MAX_STEPS]usize = [_]usize{0} ** MAX_STEPS,
    node_count: usize = 0,

    pub fn addEdge(self: *Dependency_Graph, dependent: Step_Handle, dependency: Step_Handle) SigError!void {
        const dep_idx: usize = dependent;
        const dependency_idx: usize = dependency;
        if (dep_idx >= MAX_STEPS or dependency_idx >= MAX_STEPS) return error.CapacityExceeded;
        if (dep_idx >= self.node_count) self.node_count = dep_idx + 1;
        if (dependency_idx >= self.node_count) self.node_count = dependency_idx + 1;

        if (self.adj_counts[dep_idx] >= MAX_DEPS_PER_STEP) return error.CapacityExceeded;

        self.adj[dep_idx][self.adj_counts[dep_idx]] = dependency;
        self.adj_counts[dep_idx] += 1;
    }

    pub fn topologicalSort(self: *const Dependency_Graph, out: *[MAX_STEPS]Step_Handle) SigError![]const Step_Handle {
        var in_degree: [MAX_STEPS]usize = [_]usize{0} ** MAX_STEPS;
        for (0..self.node_count) |i| {
            in_degree[i] = self.adj_counts[i];
        }

        var queue: containers.BoundedDeque(Step_Handle, MAX_STEPS) = .{};
        for (0..self.node_count) |i| {
            if (in_degree[i] == 0) {
                try queue.pushBack(@intCast(i));
            }
        }

        var count: usize = 0;
        while (queue.popFront()) |node| {
            out[count] = node;
            count += 1;

            const node_idx: usize = node;
            for (0..self.node_count) |j| {
                for (self.adj[j][0..self.adj_counts[j]]) |dep| {
                    if (@as(usize, dep) == node_idx) {
                        in_degree[j] -= 1;
                        if (in_degree[j] == 0) {
                            try queue.pushBack(@intCast(j));
                        }
                        break;
                    }
                }
            }
        }

        if (count < self.node_count) return error.DepthExceeded;

        return out[0..count];
    }
};

// ── Replicated Cache types ──────────────────────────────────────────────

const Cache_Entry = struct {
    hash: Content_Hash = .{0} ** 16,
    step_name: [NAME_BUF_SIZE]u8 = .{0} ** NAME_BUF_SIZE,
    step_name_len: usize = 0,
    timestamp: i64 = 0,
    valid: bool = false,
};

const Cache_Map = struct {
    entries: [MAX_CACHE_ENTRIES]Cache_Entry = [_]Cache_Entry{.{}} ** MAX_CACHE_ENTRIES,
    count: usize = 0,

    pub fn lookup(self: *const Cache_Map, step_name: []const u8) ?Content_Hash {
        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (entry.valid and entry.step_name_len == step_name.len and
                std.mem.eql(u8, entry.step_name[0..entry.step_name_len], step_name))
            {
                return entry.hash;
            }
        }
        return null;
    }

    pub fn put(self: *Cache_Map, step_name: []const u8, hash: Content_Hash, timestamp: i64) SigError!void {
        if (step_name.len > NAME_BUF_SIZE) return error.BufferTooSmall;

        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (entry.valid and entry.step_name_len == step_name.len and
                std.mem.eql(u8, entry.step_name[0..entry.step_name_len], step_name))
            {
                entry.hash = hash;
                entry.timestamp = timestamp;
                return;
            }
        }

        if (self.count >= MAX_CACHE_ENTRIES) {
            self.evictOldest(MAX_CACHE_ENTRIES - 1);
        }

        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (!entry.valid) {
                entry.hash = hash;
                @memcpy(entry.step_name[0..step_name.len], step_name);
                if (step_name.len < NAME_BUF_SIZE) {
                    @memset(entry.step_name[step_name.len..], 0);
                }
                entry.step_name_len = step_name.len;
                entry.timestamp = timestamp;
                entry.valid = true;
                self.count += 1;
                return;
            }
        }

        return error.CapacityExceeded;
    }

    pub fn evictOldest(self: *Cache_Map, target_count: usize) void {
        while (self.count > target_count) {
            var oldest_idx: ?usize = null;
            var oldest_ts: i64 = std.math.maxInt(i64);
            for (self.entries[0..MAX_CACHE_ENTRIES], 0..) |*entry, idx| {
                if (entry.valid and entry.timestamp < oldest_ts) {
                    oldest_ts = entry.timestamp;
                    oldest_idx = idx;
                }
            }
            if (oldest_idx) |idx| {
                self.entries[idx].valid = false;
                self.count -= 1;
            } else {
                break;
            }
        }
    }

    const CACHE_MAGIC = [4]u8{ 'S', 'I', 'G', 'C' };
    const CACHE_VERSION: u32 = 1;
    const RECORD_SIZE: usize = 96;
    const HEADER_SIZE: usize = 12;

    pub fn save(self: *const Cache_Map, io_ctx: Io, file_path: []const u8) SigError!void {
        const cwd: Io.Dir = .cwd();
        var file = cwd.createFile(io_ctx, file_path, .{}) catch return error.BufferTooSmall;
        defer file.close(io_ctx);

        var header: [HEADER_SIZE]u8 = undefined;
        @memcpy(header[0..4], &CACHE_MAGIC);
        std.mem.writeInt(u32, header[4..8], CACHE_VERSION, .little);
        std.mem.writeInt(u32, header[8..12], @intCast(self.count), .little);
        file.writeStreamingAll(io_ctx, &header) catch return error.BufferTooSmall;

        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (!entry.valid) continue;
            var record: [RECORD_SIZE]u8 = .{0} ** RECORD_SIZE;
            @memcpy(record[0..16], &entry.hash);
            @memcpy(record[16..80], &entry.step_name);
            std.mem.writeInt(i64, record[80..88], entry.timestamp, .little);
            file.writeStreamingAll(io_ctx, &record) catch return error.BufferTooSmall;
        }
    }

    pub fn load(self: *Cache_Map, io_ctx: Io, file_path: []const u8) void {
        self.count = 0;
        for (&self.entries) |*entry| {
            entry.valid = false;
        }

        const cwd: Io.Dir = .cwd();
        var file = cwd.openFile(io_ctx, file_path, .{}) catch return;
        defer file.close(io_ctx);
        var reader = file.reader(io_ctx, &.{});

        var header: [HEADER_SIZE]u8 = undefined;
        var header_read: usize = 0;
        while (header_read < HEADER_SIZE) {
            const n = reader.interface.readSliceShort(header[header_read..]) catch return;
            if (n == 0) return;
            header_read += n;
        }

        if (!std.mem.eql(u8, header[0..4], &CACHE_MAGIC)) return;

        const version = std.mem.readInt(u32, header[4..8], .little);
        if (version != CACHE_VERSION) return;

        const file_count = std.mem.readInt(u32, header[8..12], .little);
        if (file_count == 0) return;

        const load_count = @min(@as(usize, file_count), MAX_CACHE_ENTRIES);

        var loaded: usize = 0;
        while (loaded < load_count) {
            var record: [RECORD_SIZE]u8 = undefined;
            var record_read: usize = 0;
            while (record_read < RECORD_SIZE) {
                const n = reader.interface.readSliceShort(record[record_read..]) catch return;
                if (n == 0) return;
                record_read += n;
            }

            var entry = &self.entries[loaded];
            @memcpy(&entry.hash, record[0..16]);
            @memcpy(&entry.step_name, record[16..80]);
            entry.step_name_len = 0;
            for (entry.step_name, 0..) |c, idx| {
                if (c == 0) {
                    entry.step_name_len = idx;
                    break;
                }
            } else {
                entry.step_name_len = NAME_BUF_SIZE;
            }
            entry.timestamp = std.mem.readInt(i64, record[80..88], .little);
            entry.valid = true;
            loaded += 1;
        }
        self.count = loaded;

        if (file_count > MAX_CACHE_ENTRIES) {
            self.evictOldest(MAX_CACHE_ENTRIES);
        }
    }
};

// ── Option_Map alias ────────────────────────────────────────────────────

const Option_Map = containers.BoundedStringMap(NAME_BUF_SIZE, VALUE_BUF_SIZE, MAX_OPTIONS);

fn parseOption(map: *Option_Map, arg: []const u8) SigError!void {
    const rest = arg[2..];
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq_pos| {
        try map.put(rest[0..eq_pos], rest[eq_pos + 1 ..]);
    } else {
        try map.put(rest, "true");
    }
}

// ── Helper: generate unique name into buffer ────────────────────────────

fn generateName(buf: *[NAME_BUF_SIZE]u8, prefix: []const u8, index: usize) []const u8 {
    var tmp: [32]u8 = undefined;
    const num_str = sig.fmt.formatInto(&tmp, "{d}", .{index}) catch "0";
    const total = prefix.len + num_str.len;
    if (total > NAME_BUF_SIZE) return prefix;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..num_str.len], num_str);
    return buf[0..total];
}

// ── Benchmark functions ─────────────────────────────────────────────────

fn benchStepRegistry(io: Io) u64 {
    var reg: Step_Registry = .{};
    var name_buf: [NAME_BUF_SIZE]u8 = undefined;

    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..MAX_STEPS) |i| {
        const name = generateName(&name_buf, "step_", i);
        _ = reg.register(name, "bench step", &noopStep) catch unreachable;
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchModuleRegistry(io: Io) u64 {
    var reg: Module_Registry = .{};
    var name_buf: [NAME_BUF_SIZE]u8 = undefined;
    var imp_name_buf: [NAME_BUF_SIZE]u8 = undefined;

    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..MAX_MODULES) |m| {
        const mod_name = generateName(&name_buf, "mod_", m);
        const handle = reg.register(mod_name, "src/mod.sig") catch unreachable;
        for (0..MAX_IMPORTS_PER_MODULE) |imp| {
            const imp_name = generateName(&imp_name_buf, "imp_", imp);
            reg.addImport(handle, imp_name, "lib/dep.sig") catch unreachable;
        }
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchTopologicalSort(io: Io) u64 {
    // Build a 256-node DAG: each node i depends on node i-1 (linear chain).
    var graph: Dependency_Graph = .{};
    graph.node_count = MAX_STEPS;
    for (1..MAX_STEPS) |i| {
        graph.addEdge(@intCast(i), @intCast(i - 1)) catch unreachable;
    }

    var out: [MAX_STEPS]Step_Handle = undefined;

    const start = Io.Clock.awake.now(io).nanoseconds;
    _ = graph.topologicalSort(&out) catch unreachable;
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchCacheMapLookup(io: Io) u64 {
    var cache: Cache_Map = .{};
    var name_buf: [NAME_BUF_SIZE]u8 = undefined;

    // Fill the cache with MAX_CACHE_ENTRIES entries.
    for (0..MAX_CACHE_ENTRIES) |i| {
        const name = generateName(&name_buf, "s_", i);
        var hash: Content_Hash = .{0} ** 16;
        hash[0] = @intCast(i & 0xFF);
        hash[1] = @intCast((i >> 8) & 0xFF);
        cache.put(name, hash, @intCast(i)) catch unreachable;
    }

    // Benchmark: look up every entry by name.
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..MAX_CACHE_ENTRIES) |i| {
        const name = generateName(&name_buf, "s_", i);
        _ = cache.lookup(name);
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchCacheSaveLoad(io: Io) u64 {
    var cache: Cache_Map = .{};
    var name_buf: [NAME_BUF_SIZE]u8 = undefined;

    // Fill the cache.
    for (0..MAX_CACHE_ENTRIES) |i| {
        const name = generateName(&name_buf, "s_", i);
        var hash: Content_Hash = .{0} ** 16;
        hash[0] = @intCast(i & 0xFF);
        hash[1] = @intCast((i >> 8) & 0xFF);
        cache.put(name, hash, @intCast(i)) catch unreachable;
    }

    const cache_path = ".sig-cache/bench_cache.bin";

    const start = Io.Clock.awake.now(io).nanoseconds;
    cache.save(io, cache_path) catch {};
    var loaded: Cache_Map = .{};
    loaded.load(io, cache_path);
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchOptionParsing(io: Io) u64 {
    var map: Option_Map = .{};
    var arg_buf: [256]u8 = undefined;

    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..MAX_OPTIONS) |i| {
        // Build "-Dopt_NNN=value_NNN"
        var tmp: [32]u8 = undefined;
        const num = sig.fmt.formatInto(&tmp, "{d}", .{i}) catch "0";
        const prefix = "-Dopt_";
        const eq_val = "=val_";
        const total = prefix.len + num.len + eq_val.len + num.len;
        if (total <= arg_buf.len) {
            var off: usize = 0;
            @memcpy(arg_buf[off..][0..prefix.len], prefix);
            off += prefix.len;
            @memcpy(arg_buf[off..][0..num.len], num);
            off += num.len;
            @memcpy(arg_buf[off..][0..eq_val.len], eq_val);
            off += eq_val.len;
            @memcpy(arg_buf[off..][0..num.len], num);
            off += num.len;
            parseOption(&map, arg_buf[0..off]) catch {};
        }
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchPathJoin(io: Io) u64 {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const segments = [_][]const u8{ "home", "user", "projects", "sig", "src" };

    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..10_000) |_| {
        _ = sig_fs.joinPath(&buf, &segments) catch {};
    }
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

fn benchContentHash(io: Io) u64 {
    // Simulate hashing 1MB of data in 8KB chunks using dual XxHash64.
    // We fill a chunk buffer with a repeating pattern and hash it 128 times
    // (128 × 8192 = 1,048,576 = 1MB).
    var chunk: [HASH_CHUNK_SIZE]u8 = undefined;
    for (&chunk, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }

    const num_chunks: usize = 128; // 128 * 8KB = 1MB

    const start = Io.Clock.awake.now(io).nanoseconds;
    var h0 = std.hash.XxHash64.init(0);
    var h1 = std.hash.XxHash64.init(0x9e3779b97f4a7c15);
    for (0..num_chunks) |_| {
        h0.update(&chunk);
        h1.update(&chunk);
    }
    const lo = h0.final();
    const hi = h1.final();
    // Prevent optimization from eliding the hash computation.
    var result: Content_Hash = undefined;
    std.mem.writeInt(u64, result[0..8], lo, .little);
    std.mem.writeInt(u64, result[8..16], hi, .little);
    _ = result;
    const end = Io.Clock.awake.now(io).nanoseconds;
    return @intCast(end - start);
}

// ── Entry point ─────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const step_reg_ns = benchStepRegistry(io);
    const mod_reg_ns = benchModuleRegistry(io);
    const topo_sort_ns = benchTopologicalSort(io);
    const cache_lookup_ns = benchCacheMapLookup(io);
    const cache_save_load_ns = benchCacheSaveLoad(io);
    const option_parse_ns = benchOptionParsing(io);
    const path_join_ns = benchPathJoin(io);
    const content_hash_ns = benchContentHash(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\=== Sig Build Runner Benchmarks ===
        \\Step_Registry register 256:     {d} ns
        \\Module_Registry 128x64 imports: {d} ns
        \\Topological sort 256-node DAG:  {d} ns
        \\Cache_Map 4096 lookups:         {d} ns
        \\Cache save/load 4096 entries:   {d} ns
        \\Option parsing 128 flags:       {d} ns
        \\Path join 10000 ops:            {d} ns
        \\Content hash 1MB:               {d} ns
        \\
    , .{
        step_reg_ns,
        mod_reg_ns,
        topo_sort_ns,
        cache_lookup_ns,
        cache_save_load_ns,
        option_parse_ns,
        path_join_ns,
        content_hash_ns,
    });
    try stdout.flush();
}
