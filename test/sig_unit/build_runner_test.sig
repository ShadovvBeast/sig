// Unit tests for the build runner — boundary and edge case tests.
//
// Since the build runner (tools/sig_build/main.sig) is not wired as a test import,
// these tests replicate the build runner logic using the same algorithms.
//
// Requirements: 2.1–2.7, 3.1–3.7, 4.1–4.7, 5.1–5.6, 8.1–8.8, 14.1–14.8, 9.4

const std = @import("std");
const testing = std.testing;
const sig = @import("sig");
const containers = sig.containers;
const sig_fs = sig.fs;

// ── Error set ───────────────────────────────────────────────────────────
const SigError = error{ CapacityExceeded, BufferTooSmall, DepthExceeded, QuotaExceeded };

// ── Capacity constants (smaller for tests) ──────────────────────────────
const MAX_STEPS = 32;
const MAX_DEPS_PER_STEP = 8;
const MAX_MODULES = 32;
const MAX_IMPORTS_PER_MODULE = 16;
const MAX_OPTIONS = 32;
const MAX_CACHE_ENTRIES = 64;
const MAX_CMD_ARGS = 32;
const MAX_ENV_VARS = 16;
const PATH_BUF_SIZE = 4096;
const NAME_BUF_SIZE = 64;
const DESC_BUF_SIZE = 256;
const VALUE_BUF_SIZE = 256;

const path_sep = std.fs.path.sep;

// ── Type aliases ────────────────────────────────────────────────────────
const Step_Handle = u16;
const Module_Handle = u16;
const Content_Hash = [16]u8;

// ── Replicated Step_Entry / Step_Registry ───────────────────────────────

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

    pub fn findByName(self: *const Step_Registry, name: []const u8) ?Step_Handle {
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (entry.name_len == name.len and std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return @intCast(i);
            }
        }
        return null;
    }
};

// ── Replicated Module_Entry / Module_Registry ───────────────────────────

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

    pub fn addImport(self: *Module_Registry, module: Module_Handle, name: []const u8, path: []const u8) SigError!void {
        const mod_idx: usize = module;
        if (mod_idx >= self.count) return error.CapacityExceeded;
        if (name.len > NAME_BUF_SIZE) return error.BufferTooSmall;
        if (path.len > PATH_BUF_SIZE) return error.BufferTooSmall;

        var entry = &self.entries[mod_idx];
        if (entry.import_count >= MAX_IMPORTS_PER_MODULE) return error.CapacityExceeded;

        var imp = &entry.imports[entry.import_count];
        @memcpy(imp.name[0..name.len], name);
        imp.name_len = name.len;
        @memcpy(imp.path[0..path.len], path);
        imp.path_len = path.len;
        entry.import_count += 1;
    }

    pub fn findByName(self: *const Module_Registry, name: []const u8) ?Module_Handle {
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (entry.name_len == name.len and std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return @intCast(i);
            }
        }
        return null;
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

    pub fn readySet(self: *const Dependency_Graph, completed: *const containers.BoundedBitSet(MAX_STEPS), out: *[MAX_STEPS]Step_Handle) []const Step_Handle {
        var count: usize = 0;
        for (0..self.node_count) |i| {
            if (completed.isSet(i)) continue;

            var all_met = true;
            for (self.adj[i][0..self.adj_counts[i]]) |dep| {
                if (!completed.isSet(dep)) {
                    all_met = false;
                    break;
                }
            }
            if (all_met) {
                out[count] = @intCast(i);
                count += 1;
            }
        }
        return out[0..count];
    }

    pub fn propagateFailure(self: *const Dependency_Graph, failed: Step_Handle, skipped: *containers.BoundedBitSet(MAX_STEPS)) void {
        var bfs_queue: containers.BoundedDeque(Step_Handle, MAX_STEPS) = .{};
        bfs_queue.pushBack(failed) catch return;
        skipped.set(failed) catch return;

        while (bfs_queue.popFront()) |node| {
            const node_idx: usize = node;
            for (0..self.node_count) |j| {
                if (skipped.isSet(j)) continue;
                for (self.adj[j][0..self.adj_counts[j]]) |dep| {
                    if (@as(usize, dep) == node_idx) {
                        skipped.set(j) catch continue;
                        bfs_queue.pushBack(@intCast(j)) catch continue;
                        break;
                    }
                }
            }
        }
    }
};

// ── Replicated Cache_Map ────────────────────────────────────────────────

const RECORD_SIZE: usize = 96;
const HEADER_SIZE: usize = 12;
const CACHE_MAGIC = [4]u8{ 'S', 'I', 'G', 'C' };
const CACHE_VERSION: u32 = 1;

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

    pub fn serializeToBuffer(self: *const Cache_Map, buf: []u8) ?usize {
        const needed = HEADER_SIZE + self.count * RECORD_SIZE;
        if (needed > buf.len) return null;

        @memcpy(buf[0..4], &CACHE_MAGIC);
        std.mem.writeInt(u32, buf[4..8], CACHE_VERSION, .little);
        std.mem.writeInt(u32, buf[8..12], @intCast(self.count), .little);

        var offset: usize = HEADER_SIZE;
        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (!entry.valid) continue;
            var record: [RECORD_SIZE]u8 = .{0} ** RECORD_SIZE;
            @memcpy(record[0..16], &entry.hash);
            @memcpy(record[16..80], &entry.step_name);
            std.mem.writeInt(i64, record[80..88], entry.timestamp, .little);
            @memcpy(buf[offset..][0..RECORD_SIZE], &record);
            offset += RECORD_SIZE;
        }
        return offset;
    }

    pub fn deserializeFromBuffer(self: *Cache_Map, buf: []const u8) void {
        self.count = 0;
        for (&self.entries) |*entry| {
            entry.valid = false;
        }

        if (buf.len < HEADER_SIZE) return;
        if (!std.mem.eql(u8, buf[0..4], &CACHE_MAGIC)) return;

        const version = std.mem.readInt(u32, buf[4..8], .little);
        if (version != CACHE_VERSION) return;

        const file_count = std.mem.readInt(u32, buf[8..12], .little);
        if (file_count == 0) return;

        const load_count = @min(@as(usize, file_count), MAX_CACHE_ENTRIES);
        var offset: usize = HEADER_SIZE;
        var loaded: usize = 0;

        while (loaded < load_count) {
            if (offset + RECORD_SIZE > buf.len) return;
            const record = buf[offset..][0..RECORD_SIZE];

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
            offset += RECORD_SIZE;
        }
        self.count = loaded;

        if (file_count > MAX_CACHE_ENTRIES) {
            self.evictOldest(MAX_CACHE_ENTRIES);
        }
    }
};

// ── Replicated Command_Buffer ───────────────────────────────────────────

const Env_Pair = struct {
    key: [NAME_BUF_SIZE]u8 = undefined,
    key_len: usize = 0,
    value: [PATH_BUF_SIZE]u8 = undefined,
    value_len: usize = 0,
};

const Command_Buffer = struct {
    args: [MAX_CMD_ARGS][PATH_BUF_SIZE]u8 = undefined,
    arg_lens: [MAX_CMD_ARGS]usize = [_]usize{0} ** MAX_CMD_ARGS,
    arg_count: usize = 0,
    env: [MAX_ENV_VARS]Env_Pair = undefined,
    env_count: usize = 0,
    cwd: [PATH_BUF_SIZE]u8 = undefined,
    cwd_len: usize = 0,

    pub fn addArg(self: *Command_Buffer, arg: []const u8) SigError!void {
        if (self.arg_count >= MAX_CMD_ARGS) return error.CapacityExceeded;
        if (arg.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(self.args[self.arg_count][0..arg.len], arg);
        self.arg_lens[self.arg_count] = arg.len;
        self.arg_count += 1;
    }

    pub fn addEnv(self: *Command_Buffer, key: []const u8, value: []const u8) SigError!void {
        if (self.env_count >= MAX_ENV_VARS) return error.CapacityExceeded;
        if (key.len > NAME_BUF_SIZE) return error.BufferTooSmall;
        if (value.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        var pair = &self.env[self.env_count];
        @memcpy(pair.key[0..key.len], key);
        pair.key_len = key.len;
        @memcpy(pair.value[0..value.len], value);
        pair.value_len = value.len;
        self.env_count += 1;
    }

    pub fn setCwd(self: *Command_Buffer, dir: []const u8) SigError!void {
        if (dir.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(self.cwd[0..dir.len], dir);
        self.cwd_len = dir.len;
    }

    pub fn getArg(self: *const Command_Buffer, i: usize) []const u8 {
        return self.args[i][0..self.arg_lens[i]];
    }
};

// ── Replicated Option_Map and parsing ───────────────────────────────────

const Option_Map = containers.BoundedStringMap(NAME_BUF_SIZE, VALUE_BUF_SIZE, MAX_OPTIONS);

fn parseOption(map: *Option_Map, arg: []const u8) SigError!void {
    const rest = arg[2..];
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq_pos| {
        try map.put(rest[0..eq_pos], rest[eq_pos + 1 ..]);
    } else {
        try map.put(rest, "true");
    }
}

fn getOption(comptime T: type, map: *const Option_Map, name: []const u8) ?T {
    const value = map.getValue(name) orelse return null;
    return switch (@typeInfo(T)) {
        .bool => {
            if (std.mem.eql(u8, value, "true")) return true;
            if (std.mem.eql(u8, value, "false")) return false;
            return null;
        },
        .int => std.fmt.parseInt(T, value, 10) catch return null,
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8 and ptr.is_const) {
                return value;
            }
            return null;
        },
        .@"enum" => {
            inline for (@typeInfo(T).@"enum".fields) |field| {
                if (std.mem.eql(u8, value, field.name)) {
                    return @field(T, field.name);
                }
            }
            return null;
        },
        else => null,
    };
}

// ── Replicated Target_Triple ────────────────────────────────────────────

const Optimize_Mode = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };

const Target_Triple = struct {
    arch: [32]u8 = undefined,
    arch_len: usize = 0,
    os: [32]u8 = undefined,
    os_len: usize = 0,
    abi: [32]u8 = undefined,
    abi_len: usize = 0,

    pub fn format(self: *const Target_Triple, buf: *[PATH_BUF_SIZE]u8) SigError![]const u8 {
        const total = self.arch_len + 1 + self.os_len + 1 + self.abi_len;
        if (total > PATH_BUF_SIZE) return error.BufferTooSmall;

        var offset: usize = 0;
        @memcpy(buf[offset..][0..self.arch_len], self.arch[0..self.arch_len]);
        offset += self.arch_len;
        buf[offset] = '-';
        offset += 1;
        @memcpy(buf[offset..][0..self.os_len], self.os[0..self.os_len]);
        offset += self.os_len;
        buf[offset] = '-';
        offset += 1;
        @memcpy(buf[offset..][0..self.abi_len], self.abi[0..self.abi_len]);
        offset += self.abi_len;

        return buf[0..offset];
    }

    pub fn parse(s: []const u8) SigError!Target_Triple {
        const first_dash = std.mem.indexOfScalar(u8, s, '-') orelse return error.BufferTooSmall;
        const rest = s[first_dash + 1 ..];
        const second_dash = std.mem.indexOfScalar(u8, rest, '-') orelse return error.BufferTooSmall;

        const arch = s[0..first_dash];
        const os = rest[0..second_dash];
        const abi = rest[second_dash + 1 ..];

        if (arch.len > 32) return error.BufferTooSmall;
        if (os.len > 32) return error.BufferTooSmall;
        if (abi.len > 32) return error.BufferTooSmall;

        var triple: Target_Triple = .{};
        @memcpy(triple.arch[0..arch.len], arch);
        triple.arch_len = arch.len;
        @memcpy(triple.os[0..os.len], os);
        triple.os_len = os.len;
        @memcpy(triple.abi[0..abi.len], abi);
        triple.abi_len = abi.len;

        return triple;
    }
};

// ── Replicated path operations ──────────────────────────────────────────

fn normalizePath(out: *[PATH_BUF_SIZE]u8, path: []const u8) SigError![]const u8 {
    var segments: containers.BoundedVec([]const u8, 128) = .{};

    var start: usize = 0;
    const is_absolute = path.len > 0 and path[0] == path_sep;
    if (is_absolute) start = 1;

    var i: usize = start;
    while (i <= path.len) {
        if (i == path.len or path[i] == path_sep) {
            const seg = path[start..i];
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
                // skip
            } else if (std.mem.eql(u8, seg, "..")) {
                if (segments.len == 0) {
                    if (is_absolute) return error.DepthExceeded;
                    try segments.push(seg);
                } else {
                    _ = segments.pop();
                }
            } else {
                try segments.push(seg);
            }
            start = i + 1;
        }
        i += 1;
    }

    var offset: usize = 0;
    if (is_absolute) {
        out[0] = path_sep;
        offset = 1;
    }

    const segs = segments.slice();
    for (segs, 0..) |seg, idx| {
        if (idx > 0) {
            if (offset >= PATH_BUF_SIZE) return error.BufferTooSmall;
            out[offset] = path_sep;
            offset += 1;
        }
        if (offset + seg.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(out[offset..][0..seg.len], seg);
        offset += seg.len;
    }

    return out[0..offset];
}

fn pathResolve(buf: *[PATH_BUF_SIZE]u8, base: []const u8, relative: []const u8) SigError![]const u8 {
    var tmp: [PATH_BUF_SIZE]u8 = undefined;
    const segments = [_][]const u8{ base, relative };
    const joined = try sig_fs.joinPath(&tmp, &segments);
    return normalizePath(buf, joined);
}

// ── Replicated shouldExcludeFile ────────────────────────────────────────

fn shouldExcludeFile(filename: []const u8) bool {
    if (std.mem.eql(u8, filename, "README.md")) return true;

    const excluded_suffixes = [_][]const u8{
        ".gz",     ".z.0",  ".z.9",    ".zst.3",
        ".zst.19", ".lzma", ".xz",     ".tzif",
        ".tar",    "test.zig",
    };

    for (excluded_suffixes) |suffix| {
        if (filename.len >= suffix.len and
            std.mem.eql(u8, filename[filename.len - suffix.len ..], suffix))
        {
            return true;
        }
    }

    return false;
}

// ── Replicated compile command construction ─────────────────────────────

const Compile_Options = struct {
    source_path: []const u8,
    output_name: []const u8,
    cache_dir: []const u8,
    optimize: Optimize_Mode,
    target: ?*const Target_Triple,
    imports: []const Import_Entry,
    compiler_path: []const u8,
};

fn buildCompileCommand(cmd: *Command_Buffer, opts: Compile_Options) SigError!void {
    if (opts.compiler_path.len > 0) {
        try cmd.addArg(opts.compiler_path);
    } else {
        try cmd.addArg("sig");
    }

    try cmd.addArg("build-exe");
    try cmd.addArg(opts.source_path);

    for (opts.imports) |imp| {
        try cmd.addArg("--mod");
        var mod_buf: [PATH_BUF_SIZE]u8 = undefined;
        const name_slice = imp.name[0..imp.name_len];
        const path_slice = imp.path[0..imp.path_len];
        const total = name_slice.len + 1 + path_slice.len;
        if (total > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(mod_buf[0..name_slice.len], name_slice);
        mod_buf[name_slice.len] = ':';
        @memcpy(mod_buf[name_slice.len + 1 ..][0..path_slice.len], path_slice);
        try cmd.addArg(mod_buf[0..total]);
    }

    try cmd.addArg("-O");
    try cmd.addArg(switch (opts.optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    });

    if (opts.target) |triple| {
        try cmd.addArg("-target");
        var triple_buf: [PATH_BUF_SIZE]u8 = undefined;
        const triple_str = try triple.format(&triple_buf);
        try cmd.addArg(triple_str);
    }

    try cmd.addArg("--cache-dir");
    try cmd.addArg(opts.cache_dir);

    try cmd.addArg("--name");
    try cmd.addArg(opts.output_name);
}

// ── Helper ──────────────────────────────────────────────────────────────

fn makeHash(val: u8) Content_Hash {
    return .{val} ** 16;
}

// ═══════════════════════════════════════════════════════════════════════
// Step_Registry boundary tests — Requirements 2.1–2.7
// ═══════════════════════════════════════════════════════════════════════

test "Step_Registry: empty name is zero-length, registers successfully" {
    // The register function checks name.len > NAME_BUF_SIZE, so len=0 passes.
    // An empty name is technically valid (not > 64).
    var reg: Step_Registry = .{};
    const handle = try reg.register("", "desc", &noopStep);
    try testing.expectEqual(@as(Step_Handle, 0), handle);
    try testing.expectEqual(@as(usize, 1), reg.count);
}

test "Step_Registry: name at exactly 64 bytes succeeds" {
    var reg: Step_Registry = .{};
    const name = "a" ** NAME_BUF_SIZE; // exactly 64 bytes
    const handle = try reg.register(name, "desc", &noopStep);
    try testing.expectEqual(@as(Step_Handle, 0), handle);
    // Verify stored name matches.
    const entry = &reg.entries[0];
    try testing.expectEqual(@as(usize, NAME_BUF_SIZE), entry.name_len);
    try testing.expectEqualSlices(u8, name, entry.name[0..entry.name_len]);
}

test "Step_Registry: name at 65 bytes returns BufferTooSmall" {
    var reg: Step_Registry = .{};
    const name = "a" ** (NAME_BUF_SIZE + 1); // 65 bytes
    try testing.expectError(error.BufferTooSmall, reg.register(name, "desc", &noopStep));
    try testing.expectEqual(@as(usize, 0), reg.count);
}

test "Step_Registry: register MAX_STEPS succeeds, one more returns CapacityExceeded" {
    var reg: Step_Registry = .{};
    // Register exactly MAX_STEPS (32 for tests).
    for (0..MAX_STEPS) |i| {
        var name_buf: [NAME_BUF_SIZE]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "step{d}", .{i}) catch unreachable;
        _ = try reg.register(name, "d", &noopStep);
    }
    try testing.expectEqual(@as(usize, MAX_STEPS), reg.count);

    // One more should fail.
    try testing.expectError(error.CapacityExceeded, reg.register("overflow", "d", &noopStep));
    try testing.expectEqual(@as(usize, MAX_STEPS), reg.count);
}

test "Step_Registry: duplicate name returns CapacityExceeded" {
    var reg: Step_Registry = .{};
    _ = try reg.register("compile", "first", &noopStep);
    try testing.expectError(error.CapacityExceeded, reg.register("compile", "second", &noopStep));
    try testing.expectEqual(@as(usize, 1), reg.count);
}

test "Step_Registry: findByName returns null for unknown name" {
    var reg: Step_Registry = .{};
    _ = try reg.register("build", "desc", &noopStep);
    try testing.expect(reg.findByName("test") == null);
    try testing.expect(reg.findByName("build") != null);
}

test "Step_Registry: addDep stores dependency correctly" {
    var reg: Step_Registry = .{};
    const a = try reg.register("a", "d", &noopStep);
    const b = try reg.register("b", "d", &noopStep);
    try reg.addDep(b, a); // b depends on a
    try testing.expectEqual(@as(usize, 1), reg.entries[@as(usize, b)].dep_count);
    try testing.expectEqual(a, reg.entries[@as(usize, b)].deps[0]);
}

test "Step_Registry: addDep at MAX_DEPS_PER_STEP returns CapacityExceeded" {
    var reg: Step_Registry = .{};
    // Register enough steps for deps.
    for (0..MAX_DEPS_PER_STEP + 2) |i| {
        var name_buf: [NAME_BUF_SIZE]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "s{d}", .{i}) catch unreachable;
        _ = try reg.register(name, "d", &noopStep);
    }
    // Fill dep list of last step.
    const target: Step_Handle = MAX_DEPS_PER_STEP + 1;
    for (0..MAX_DEPS_PER_STEP) |i| {
        try reg.addDep(target, @intCast(i));
    }
    // One more dep should fail.
    try testing.expectError(error.CapacityExceeded, reg.addDep(target, MAX_DEPS_PER_STEP));
}

// ═══════════════════════════════════════════════════════════════════════
// Module_Registry boundary tests — Requirements 3.1–3.7
// ═══════════════════════════════════════════════════════════════════════

test "Module_Registry: module with 0 imports is valid" {
    var reg: Module_Registry = .{};
    const handle = try reg.register("mymod", "src/main.sig");
    try testing.expectEqual(@as(Module_Handle, 0), handle);
    try testing.expectEqual(@as(usize, 0), reg.entries[0].import_count);
}

test "Module_Registry: module with exactly MAX_IMPORTS_PER_MODULE imports succeeds" {
    var reg: Module_Registry = .{};
    const handle = try reg.register("mymod", "src/main.sig");
    for (0..MAX_IMPORTS_PER_MODULE) |i| {
        var name_buf: [NAME_BUF_SIZE]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "imp{d}", .{i}) catch unreachable;
        try reg.addImport(handle, name, "lib/dep.sig");
    }
    try testing.expectEqual(@as(usize, MAX_IMPORTS_PER_MODULE), reg.entries[0].import_count);
}

test "Module_Registry: import beyond MAX_IMPORTS_PER_MODULE returns CapacityExceeded" {
    var reg: Module_Registry = .{};
    const handle = try reg.register("mymod", "src/main.sig");
    for (0..MAX_IMPORTS_PER_MODULE) |i| {
        var name_buf: [NAME_BUF_SIZE]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "imp{d}", .{i}) catch unreachable;
        try reg.addImport(handle, name, "lib/dep.sig");
    }
    try testing.expectError(error.CapacityExceeded, reg.addImport(handle, "overflow", "lib/x.sig"));
}

test "Module_Registry: duplicate module name returns CapacityExceeded" {
    var reg: Module_Registry = .{};
    _ = try reg.register("sig", "lib/sig/sig.zig");
    try testing.expectError(error.CapacityExceeded, reg.register("sig", "lib/sig/other.zig"));
    try testing.expectEqual(@as(usize, 1), reg.count);
}

test "Module_Registry: findByName returns correct handle" {
    var reg: Module_Registry = .{};
    _ = try reg.register("alpha", "a.sig");
    _ = try reg.register("beta", "b.sig");
    try testing.expectEqual(@as(?Module_Handle, 0), reg.findByName("alpha"));
    try testing.expectEqual(@as(?Module_Handle, 1), reg.findByName("beta"));
    try testing.expect(reg.findByName("gamma") == null);
}

// ═══════════════════════════════════════════════════════════════════════
// Path operations boundary tests — Requirements 4.1–4.7
// ═══════════════════════════════════════════════════════════════════════

test "pathJoin: empty segments are skipped" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const segments = [_][]const u8{ "src", "", "main.sig" };
    const result = try sig_fs.joinPath(&buf, &segments);
    // Empty segment should be skipped, result is "src{sep}main.sig"
    var expected_buf: [32]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "src{c}main.sig", .{path_sep}) catch unreachable;
    try testing.expectEqualSlices(u8, expected, result);
}

test "pathJoin: single segment produces no separator" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const segments = [_][]const u8{"hello"};
    const result = try sig_fs.joinPath(&buf, &segments);
    try testing.expectEqualSlices(u8, "hello", result);
}

test "pathJoin: uses platform separator" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const segments = [_][]const u8{ "a", "b", "c" };
    const result = try sig_fs.joinPath(&buf, &segments);
    var expected_buf: [32]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "a{c}b{c}c", .{ path_sep, path_sep }) catch unreachable;
    try testing.expectEqualSlices(u8, expected, result);
}

test "pathResolve: .. escaping absolute root returns DepthExceeded" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    // Build an absolute path with path_sep prefix, then try to escape with ..
    var root_buf: [8]u8 = undefined;
    root_buf[0] = path_sep;
    @memcpy(root_buf[1..4], "usr");
    const root = root_buf[0..4]; // "/usr"

    // Resolve "../../.." against "/usr" — should try to go above root.
    var rel_buf: [16]u8 = undefined;
    rel_buf[0] = '.';
    rel_buf[1] = '.';
    rel_buf[2] = path_sep;
    rel_buf[3] = '.';
    rel_buf[4] = '.';
    rel_buf[5] = path_sep;
    rel_buf[6] = '.';
    rel_buf[7] = '.';
    const rel = rel_buf[0..8]; // "../../.."

    const result = pathResolve(&buf, root, rel);
    try testing.expectError(error.DepthExceeded, result);
}

test "normalizePath: collapses . and consecutive separators" {
    var buf: [PATH_BUF_SIZE]u8 = undefined;
    var input_buf: [32]u8 = undefined;
    // Build "a/./b" with platform separator
    input_buf[0] = 'a';
    input_buf[1] = path_sep;
    input_buf[2] = '.';
    input_buf[3] = path_sep;
    input_buf[4] = 'b';
    const result = try normalizePath(&buf, input_buf[0..5]);
    var expected_buf: [8]u8 = undefined;
    expected_buf[0] = 'a';
    expected_buf[1] = path_sep;
    expected_buf[2] = 'b';
    try testing.expectEqualSlices(u8, expected_buf[0..3], result);
}

// ═══════════════════════════════════════════════════════════════════════
// Topological sort boundary tests — Requirements 5.1–5.6
// ═══════════════════════════════════════════════════════════════════════

test "topologicalSort: single node returns that node" {
    var graph: Dependency_Graph = .{};
    graph.node_count = 1;
    // Node 0 has no deps.
    var out: [MAX_STEPS]Step_Handle = undefined;
    const sorted = try graph.topologicalSort(&out);
    try testing.expectEqual(@as(usize, 1), sorted.len);
    try testing.expectEqual(@as(Step_Handle, 0), sorted[0]);
}

test "topologicalSort: linear chain A->B->C returns [C, B, A]" {
    // A(2) depends on B(1), B(1) depends on C(0).
    // In "depends-on" representation: adj[2]=[1], adj[1]=[0], adj[0]=[]
    var graph: Dependency_Graph = .{};
    graph.node_count = 3;
    // Node 2 depends on node 1.
    graph.adj[2][0] = 1;
    graph.adj_counts[2] = 1;
    // Node 1 depends on node 0.
    graph.adj[1][0] = 0;
    graph.adj_counts[1] = 1;

    var out: [MAX_STEPS]Step_Handle = undefined;
    const sorted = try graph.topologicalSort(&out);
    try testing.expectEqual(@as(usize, 3), sorted.len);
    // C(0) must come first, then B(1), then A(2).
    try testing.expectEqual(@as(Step_Handle, 0), sorted[0]);
    try testing.expectEqual(@as(Step_Handle, 1), sorted[1]);
    try testing.expectEqual(@as(Step_Handle, 2), sorted[2]);
}

test "topologicalSort: diamond graph respects all edges" {
    // Diamond: D(3) depends on B(1) and C(2); B(1) depends on A(0); C(2) depends on A(0).
    var graph: Dependency_Graph = .{};
    graph.node_count = 4;
    graph.adj[1][0] = 0;
    graph.adj_counts[1] = 1; // B depends on A
    graph.adj[2][0] = 0;
    graph.adj_counts[2] = 1; // C depends on A
    graph.adj[3][0] = 1;
    graph.adj[3][1] = 2;
    graph.adj_counts[3] = 2; // D depends on B and C

    var out: [MAX_STEPS]Step_Handle = undefined;
    const sorted = try graph.topologicalSort(&out);
    try testing.expectEqual(@as(usize, 4), sorted.len);

    // Build position map.
    var pos: [4]usize = undefined;
    for (sorted, 0..) |h, p| {
        pos[@as(usize, h)] = p;
    }
    // A before B, A before C, B before D, C before D.
    try testing.expect(pos[0] < pos[1]);
    try testing.expect(pos[0] < pos[2]);
    try testing.expect(pos[1] < pos[3]);
    try testing.expect(pos[2] < pos[3]);
}

test "topologicalSort: cycle returns DepthExceeded" {
    var graph: Dependency_Graph = .{};
    graph.node_count = 2;
    graph.adj[0][0] = 1;
    graph.adj_counts[0] = 1;
    graph.adj[1][0] = 0;
    graph.adj_counts[1] = 1;

    var out: [MAX_STEPS]Step_Handle = undefined;
    try testing.expectError(error.DepthExceeded, graph.topologicalSort(&out));
}

test "readySet: returns nodes with all deps completed" {
    var graph: Dependency_Graph = .{};
    graph.node_count = 3;
    graph.adj[1][0] = 0;
    graph.adj_counts[1] = 1; // 1 depends on 0
    graph.adj[2][0] = 1;
    graph.adj_counts[2] = 1; // 2 depends on 1

    var completed: containers.BoundedBitSet(MAX_STEPS) = .{};
    try completed.set(0); // Only node 0 is done.

    var out: [MAX_STEPS]Step_Handle = undefined;
    const ready = graph.readySet(&completed, &out);
    // Node 1 should be ready (its dep 0 is done). Node 2 is not (dep 1 not done).
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqual(@as(Step_Handle, 1), ready[0]);
}

test "propagateFailure: skips transitive dependents" {
    // 0 -> 1 -> 2 (chain). Fail 0 → 1 and 2 should be skipped.
    var graph: Dependency_Graph = .{};
    graph.node_count = 3;
    graph.adj[1][0] = 0;
    graph.adj_counts[1] = 1;
    graph.adj[2][0] = 1;
    graph.adj_counts[2] = 1;

    var skipped: containers.BoundedBitSet(MAX_STEPS) = .{};
    graph.propagateFailure(0, &skipped);

    try testing.expect(skipped.isSet(0));
    try testing.expect(skipped.isSet(1));
    try testing.expect(skipped.isSet(2));
}

// ═══════════════════════════════════════════════════════════════════════
// Cache_Map boundary tests — Requirements 8.1–8.8
// ═══════════════════════════════════════════════════════════════════════

test "Cache_Map: 0 entries serialize/deserialize round-trip" {
    var cache: Cache_Map = .{};
    var buf: [HEADER_SIZE + MAX_CACHE_ENTRIES * RECORD_SIZE]u8 = undefined;
    const written = cache.serializeToBuffer(&buf).?;
    try testing.expectEqual(@as(usize, HEADER_SIZE), written);

    var loaded: Cache_Map = .{};
    loaded.deserializeFromBuffer(buf[0..written]);
    try testing.expectEqual(@as(usize, 0), loaded.count);
}

test "Cache_Map: fill to MAX_CACHE_ENTRIES succeeds" {
    var cache: Cache_Map = .{};
    for (0..MAX_CACHE_ENTRIES) |i| {
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "s{d}", .{i}) catch unreachable;
        try cache.put(name, makeHash(@intCast(i)), @intCast(i));
    }
    try testing.expectEqual(@as(usize, MAX_CACHE_ENTRIES), cache.count);
}

test "Cache_Map: entry beyond MAX_CACHE_ENTRIES triggers eviction" {
    var cache: Cache_Map = .{};
    for (0..MAX_CACHE_ENTRIES) |i| {
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "s{d}", .{i}) catch unreachable;
        try cache.put(name, makeHash(@intCast(i)), @intCast(i));
    }
    try testing.expectEqual(@as(usize, MAX_CACHE_ENTRIES), cache.count);

    // One more triggers auto-eviction of the oldest (timestamp 0 = "s0").
    try cache.put("new_entry", makeHash(0xFF), 9999);
    try testing.expectEqual(@as(usize, MAX_CACHE_ENTRIES), cache.count);
    try testing.expect(cache.lookup("new_entry") != null);
    try testing.expect(cache.lookup("s0") == null); // evicted
}

test "Cache_Map: serialize/deserialize preserves all entries" {
    var cache: Cache_Map = .{};
    try cache.put("alpha", makeHash(0x01), 100);
    try cache.put("beta", makeHash(0x02), 200);
    try cache.put("gamma", makeHash(0x03), 300);

    var buf: [HEADER_SIZE + MAX_CACHE_ENTRIES * RECORD_SIZE]u8 = undefined;
    const written = cache.serializeToBuffer(&buf).?;

    var loaded: Cache_Map = .{};
    loaded.deserializeFromBuffer(buf[0..written]);
    try testing.expectEqual(@as(usize, 3), loaded.count);
    try testing.expectEqualSlices(u8, &makeHash(0x01), &loaded.lookup("alpha").?);
    try testing.expectEqualSlices(u8, &makeHash(0x02), &loaded.lookup("beta").?);
    try testing.expectEqualSlices(u8, &makeHash(0x03), &loaded.lookup("gamma").?);
}

// ═══════════════════════════════════════════════════════════════════════
// Option parsing tests — Requirements 14.1–14.8
// ═══════════════════════════════════════════════════════════════════════

test "parseOption: -Doptimize=Debug stores key and value" {
    var map: Option_Map = .{};
    try parseOption(&map, "-Doptimize=Debug");
    const val = map.getValue("optimize");
    try testing.expect(val != null);
    try testing.expectEqualSlices(u8, "Debug", val.?);
}

test "parseOption: -Dsingle-threaded stores boolean true" {
    var map: Option_Map = .{};
    try parseOption(&map, "-Dsingle-threaded");
    const val = map.getValue("single-threaded");
    try testing.expect(val != null);
    try testing.expectEqualSlices(u8, "true", val.?);
}

test "parseOption: -Dmem-leak-frames=4 stores integer as string" {
    var map: Option_Map = .{};
    try parseOption(&map, "-Dmem-leak-frames=4");
    const val = map.getValue("mem-leak-frames");
    try testing.expect(val != null);
    try testing.expectEqualSlices(u8, "4", val.?);
}

test "getOption: bool type returns true for 'true'" {
    var map: Option_Map = .{};
    try parseOption(&map, "-Dsingle-threaded");
    const result = getOption(bool, &map, "single-threaded");
    try testing.expect(result != null);
    try testing.expectEqual(true, result.?);
}

test "getOption: integer type parses decimal string" {
    var map: Option_Map = .{};
    try parseOption(&map, "-Dmem-leak-frames=4");
    const result = getOption(i64, &map, "mem-leak-frames");
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 4), result.?);
}

test "getOption: enum type matches field name" {
    var map: Option_Map = .{};
    try parseOption(&map, "-Doptimize=Debug");
    const result = getOption(Optimize_Mode, &map, "optimize");
    try testing.expect(result != null);
    try testing.expectEqual(Optimize_Mode.Debug, result.?);
}

test "getOption: string type returns raw value" {
    var map: Option_Map = .{};
    try parseOption(&map, "-Dprefix=/usr/local");
    const result = getOption([]const u8, &map, "prefix");
    try testing.expect(result != null);
    try testing.expectEqualSlices(u8, "/usr/local", result.?);
}

test "getOption: missing key returns null" {
    var map: Option_Map = .{};
    try testing.expect(getOption(bool, &map, "nonexistent") == null);
}

// ═══════════════════════════════════════════════════════════════════════
// Target_Triple tests — Requirement 9.4
// ═══════════════════════════════════════════════════════════════════════

test "Target_Triple: x86_64-linux-gnu parse and format round-trip" {
    const triple = try Target_Triple.parse("x86_64-linux-gnu");
    try testing.expectEqualSlices(u8, "x86_64", triple.arch[0..triple.arch_len]);
    try testing.expectEqualSlices(u8, "linux", triple.os[0..triple.os_len]);
    try testing.expectEqualSlices(u8, "gnu", triple.abi[0..triple.abi_len]);

    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const formatted = try triple.format(&buf);
    try testing.expectEqualSlices(u8, "x86_64-linux-gnu", formatted);
}

test "Target_Triple: aarch64-macos-none parse and format round-trip" {
    const triple = try Target_Triple.parse("aarch64-macos-none");
    try testing.expectEqualSlices(u8, "aarch64", triple.arch[0..triple.arch_len]);
    try testing.expectEqualSlices(u8, "macos", triple.os[0..triple.os_len]);
    try testing.expectEqualSlices(u8, "none", triple.abi[0..triple.abi_len]);

    var buf: [PATH_BUF_SIZE]u8 = undefined;
    const formatted = try triple.format(&buf);
    try testing.expectEqualSlices(u8, "aarch64-macos-none", formatted);
}

test "Target_Triple: parse with no dashes returns BufferTooSmall" {
    try testing.expectError(error.BufferTooSmall, Target_Triple.parse("nodashes"));
}

test "Target_Triple: parse with one dash returns BufferTooSmall" {
    try testing.expectError(error.BufferTooSmall, Target_Triple.parse("x86_64-linux"));
}

// ═══════════════════════════════════════════════════════════════════════
// Compile command construction test — Requirements 9.1, 9.2
// ═══════════════════════════════════════════════════════════════════════

test "buildCompileCommand: simple source produces correct argv" {
    var cmd: Command_Buffer = .{};

    const opts = Compile_Options{
        .source_path = "src/main.sig",
        .output_name = "myapp",
        .cache_dir = ".sig-cache",
        .optimize = .Debug,
        .target = null,
        .imports = &[_]Import_Entry{},
        .compiler_path = "",
    };

    try buildCompileCommand(&cmd, opts);

    // Expected: sig build-exe src/main.sig -O Debug --cache-dir .sig-cache --name myapp
    try testing.expectEqual(@as(usize, 9), cmd.arg_count);
    try testing.expectEqualSlices(u8, "sig", cmd.getArg(0));
    try testing.expectEqualSlices(u8, "build-exe", cmd.getArg(1));
    try testing.expectEqualSlices(u8, "src/main.sig", cmd.getArg(2));
    try testing.expectEqualSlices(u8, "-O", cmd.getArg(3));
    try testing.expectEqualSlices(u8, "Debug", cmd.getArg(4));
    try testing.expectEqualSlices(u8, "--cache-dir", cmd.getArg(5));
    try testing.expectEqualSlices(u8, ".sig-cache", cmd.getArg(6));
    try testing.expectEqualSlices(u8, "--name", cmd.getArg(7));
    try testing.expectEqualSlices(u8, "myapp", cmd.getArg(8));
}

test "buildCompileCommand: with target triple adds -target flag" {
    var cmd: Command_Buffer = .{};

    var triple = try Target_Triple.parse("x86_64-linux-gnu");

    const opts = Compile_Options{
        .source_path = "src/main.sig",
        .output_name = "myapp",
        .cache_dir = ".cache",
        .optimize = .ReleaseFast,
        .target = &triple,
        .imports = &[_]Import_Entry{},
        .compiler_path = "/usr/bin/sig",
    };

    try buildCompileCommand(&cmd, opts);

    // Expected: /usr/bin/sig build-exe src/main.sig -O ReleaseFast -target x86_64-linux-gnu --cache-dir .cache --name myapp
    try testing.expectEqual(@as(usize, 11), cmd.arg_count);
    try testing.expectEqualSlices(u8, "/usr/bin/sig", cmd.getArg(0));
    try testing.expectEqualSlices(u8, "build-exe", cmd.getArg(1));
    try testing.expectEqualSlices(u8, "src/main.sig", cmd.getArg(2));
    try testing.expectEqualSlices(u8, "-O", cmd.getArg(3));
    try testing.expectEqualSlices(u8, "ReleaseFast", cmd.getArg(4));
    try testing.expectEqualSlices(u8, "-target", cmd.getArg(5));
    try testing.expectEqualSlices(u8, "x86_64-linux-gnu", cmd.getArg(6));
    try testing.expectEqualSlices(u8, "--cache-dir", cmd.getArg(7));
    try testing.expectEqualSlices(u8, ".cache", cmd.getArg(8));
    try testing.expectEqualSlices(u8, "--name", cmd.getArg(9));
    try testing.expectEqualSlices(u8, "myapp", cmd.getArg(10));
}

test "buildCompileCommand: with imports adds --mod flags" {
    var cmd: Command_Buffer = .{};

    var imp: Import_Entry = .{};
    @memcpy(imp.name[0..3], "sig");
    imp.name_len = 3;
    @memcpy(imp.path[0..15], "lib/sig/sig.zig");
    imp.path_len = 15;

    const imports = [_]Import_Entry{imp};

    const opts = Compile_Options{
        .source_path = "src/main.sig",
        .output_name = "app",
        .cache_dir = ".cache",
        .optimize = .Debug,
        .target = null,
        .imports = &imports,
        .compiler_path = "",
    };

    try buildCompileCommand(&cmd, opts);

    // Expected: sig build-exe src/main.sig --mod sig:lib/sig/sig.zig -O Debug --cache-dir .cache --name app
    try testing.expectEqual(@as(usize, 11), cmd.arg_count);
    try testing.expectEqualSlices(u8, "sig", cmd.getArg(0));
    try testing.expectEqualSlices(u8, "build-exe", cmd.getArg(1));
    try testing.expectEqualSlices(u8, "src/main.sig", cmd.getArg(2));
    try testing.expectEqualSlices(u8, "--mod", cmd.getArg(3));
    try testing.expectEqualSlices(u8, "sig:lib/sig/sig.zig", cmd.getArg(4));
    try testing.expectEqualSlices(u8, "-O", cmd.getArg(5));
    try testing.expectEqualSlices(u8, "Debug", cmd.getArg(6));
    try testing.expectEqualSlices(u8, "--cache-dir", cmd.getArg(7));
    try testing.expectEqualSlices(u8, ".cache", cmd.getArg(8));
    try testing.expectEqualSlices(u8, "--name", cmd.getArg(9));
    try testing.expectEqualSlices(u8, "app", cmd.getArg(10));
}

// ═══════════════════════════════════════════════════════════════════════
// shouldExcludeFile tests — Requirement 9.3
// ═══════════════════════════════════════════════════════════════════════

test "shouldExcludeFile: README.md is excluded" {
    try testing.expect(shouldExcludeFile("README.md"));
}

test "shouldExcludeFile: .gz suffix is excluded" {
    try testing.expect(shouldExcludeFile("data.gz"));
}

test "shouldExcludeFile: test.zig suffix is excluded" {
    try testing.expect(shouldExcludeFile("my_test.zig"));
}

test "shouldExcludeFile: .sig file is not excluded" {
    try testing.expect(!shouldExcludeFile("main.sig"));
}

test "shouldExcludeFile: regular .zig file is not excluded" {
    try testing.expect(!shouldExcludeFile("main.zig"));
}
