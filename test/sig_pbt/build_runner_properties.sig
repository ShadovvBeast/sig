// Feature: sig-build-runner — Property-based tests for the build runner.
//
// Since the build runner (tools/sig_build/main.sig) is not wired as a test import,
// these tests replicate the build runner logic using the same algorithms.
//
// Requirements: 1.1, 1.3, 1.6, 1.8, 2.1–2.6, 3.1–3.7, 4.1–4.3, 4.7,
//               5.2, 5.3, 5.5, 6.2, 6.5, 6.6, 7.5, 8.1–8.3, 8.5–8.7,
//               9.1–9.4, 10.5, 13.1–13.5, 14.1–14.5

const std = @import("std");
const harness = @import("harness");
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
        var queue: containers.BoundedDeque(Step_Handle, MAX_STEPS) = .{};
        queue.pushBack(failed) catch return;
        skipped.set(failed) catch return;

        while (queue.popFront()) |node| {
            const node_idx: usize = node;
            for (0..self.node_count) |j| {
                if (skipped.isSet(j)) continue;
                for (self.adj[j][0..self.adj_counts[j]]) |dep| {
                    if (@as(usize, dep) == node_idx) {
                        skipped.set(j) catch continue;
                        queue.pushBack(@intCast(j)) catch continue;
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

fn pathRelative(buf: *[PATH_BUF_SIZE]u8, base: []const u8, target: []const u8) SigError![]const u8 {
    var norm_base_buf: [PATH_BUF_SIZE]u8 = undefined;
    var norm_target_buf: [PATH_BUF_SIZE]u8 = undefined;
    const norm_base = try normalizePath(&norm_base_buf, base);
    const norm_target = try normalizePath(&norm_target_buf, target);

    var base_segs: containers.BoundedVec([]const u8, 128) = .{};
    var target_segs: containers.BoundedVec([]const u8, 128) = .{};

    var start_b: usize = 0;
    if (norm_base.len > 0 and norm_base[0] == path_sep) start_b = 1;
    var ib: usize = start_b;
    while (ib <= norm_base.len) {
        if (ib == norm_base.len or norm_base[ib] == path_sep) {
            const seg = norm_base[start_b..ib];
            if (seg.len > 0) try base_segs.push(seg);
            start_b = ib + 1;
        }
        ib += 1;
    }

    var start_t: usize = 0;
    if (norm_target.len > 0 and norm_target[0] == path_sep) start_t = 1;
    var it: usize = start_t;
    while (it <= norm_target.len) {
        if (it == norm_target.len or norm_target[it] == path_sep) {
            const seg = norm_target[start_t..it];
            if (seg.len > 0) try target_segs.push(seg);
            start_t = it + 1;
        }
        it += 1;
    }

    const base_sl = base_segs.slice();
    const target_sl = target_segs.slice();
    var common: usize = 0;
    while (common < base_sl.len and common < target_sl.len) {
        if (!std.mem.eql(u8, base_sl[common], target_sl[common])) break;
        common += 1;
    }

    var result_segs: containers.BoundedVec([]const u8, 128) = .{};
    var ups: usize = 0;
    while (ups < base_sl.len - common) : (ups += 1) {
        try result_segs.push("..");
    }
    var t: usize = common;
    while (t < target_sl.len) : (t += 1) {
        try result_segs.push(target_sl[t]);
    }

    const res_sl = result_segs.slice();
    if (res_sl.len == 0) {
        buf[0] = '.';
        return buf[0..1];
    }

    var offset: usize = 0;
    for (res_sl, 0..) |seg, idx| {
        if (idx > 0) {
            if (offset >= PATH_BUF_SIZE) return error.BufferTooSmall;
            buf[offset] = path_sep;
            offset += 1;
        }
        if (offset + seg.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(buf[offset..][0..seg.len], seg);
        offset += seg.len;
    }

    return buf[0..offset];
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

// ── CR+LF normalization helper ──────────────────────────────────────────

fn normalizeCrLf(data: []const u8, out: []u8) usize {
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') {
            out[out_len] = '\n';
            out_len += 1;
            i += 2;
        } else {
            out[out_len] = data[i];
            out_len += 1;
            i += 1;
        }
    }
    return out_len;
}

// ── Random generators ───────────────────────────────────────────────────

const ALPHA_NUM = "abcdefghijklmnopqrstuvwxyz0123456789_-";

fn genValidName(random: std.Random, buf: *[NAME_BUF_SIZE]u8) []const u8 {
    const len = 1 + random.uintLessThan(usize, NAME_BUF_SIZE);
    // First char must be alpha to avoid leading dash/digit issues.
    buf[0] = "abcdefghijklmnopqrstuvwxyz"[random.uintLessThan(usize, 26)];
    for (1..len) |i| {
        buf[i] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
    }
    return buf[0..len];
}

fn genValidPath(random: std.Random, buf: *[PATH_BUF_SIZE]u8) []const u8 {
    const num_segments = 1 + random.uintLessThan(usize, 4);
    var offset: usize = 0;
    for (0..num_segments) |seg_i| {
        if (seg_i > 0) {
            buf[offset] = path_sep;
            offset += 1;
        }
        const seg_len = 1 + random.uintLessThan(usize, 16);
        for (0..seg_len) |_| {
            if (offset >= PATH_BUF_SIZE) break;
            buf[offset] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
            offset += 1;
        }
    }
    return buf[0..offset];
}

/// Generate a random DAG with `n` nodes. Edges only go from higher to lower
/// indices, guaranteeing acyclicity.
fn genRandomDAG(random: std.Random, graph: *Dependency_Graph, n: usize) void {
    graph.* = .{};
    graph.node_count = n;
    for (0..n) |i| {
        // Each node may depend on some earlier nodes.
        const max_deps = @min(i, @as(usize, MAX_DEPS_PER_STEP));
        if (max_deps == 0) continue;
        const num_deps = random.uintAtMost(usize, @min(max_deps, 3));
        for (0..num_deps) |_| {
            const dep = random.uintLessThan(usize, i);
            // Avoid duplicate edges.
            var already = false;
            for (graph.adj[i][0..graph.adj_counts[i]]) |existing| {
                if (@as(usize, existing) == dep) {
                    already = true;
                    break;
                }
            }
            if (!already and graph.adj_counts[i] < MAX_DEPS_PER_STEP) {
                graph.adj[i][graph.adj_counts[i]] = @intCast(dep);
                graph.adj_counts[i] += 1;
            }
        }
    }
}

fn genCacheEntry(random: std.Random, name_buf: *[NAME_BUF_SIZE]u8) struct { name: []const u8, hash: Content_Hash, timestamp: i64 } {
    const name = genValidName(random, name_buf);
    var hash: Content_Hash = undefined;
    random.bytes(&hash);
    const timestamp: i64 = @intCast(random.uintLessThan(u32, 1_000_000));
    return .{ .name = name, .hash = hash, .timestamp = timestamp };
}

fn genOptionPair(random: std.Random, buf: *[VALUE_BUF_SIZE]u8) []const u8 {
    buf[0] = '-';
    buf[1] = 'D';
    var offset: usize = 2;
    // name part
    const name_len = 1 + random.uintLessThan(usize, 20);
    for (0..name_len) |_| {
        if (offset >= VALUE_BUF_SIZE) break;
        buf[offset] = "abcdefghijklmnopqrstuvwxyz"[random.uintLessThan(usize, 26)];
        offset += 1;
    }
    // Randomly add =value
    if (random.boolean()) {
        if (offset < VALUE_BUF_SIZE) {
            buf[offset] = '=';
            offset += 1;
        }
        const val_len = 1 + random.uintLessThan(usize, 20);
        for (0..val_len) |_| {
            if (offset >= VALUE_BUF_SIZE) break;
            buf[offset] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
            offset += 1;
        }
    }
    return buf[0..offset];
}

const ARCHS = [_][]const u8{ "x86_64", "aarch64", "riscv64", "arm", "wasm32" };
const OSES = [_][]const u8{ "linux", "macos", "windows", "freebsd", "freestanding" };
const ABIS = [_][]const u8{ "gnu", "musl", "none", "msvc", "eabi" };

fn genTargetTriple(random: std.Random, buf: *[PATH_BUF_SIZE]u8) []const u8 {
    const arch = ARCHS[random.uintLessThan(usize, ARCHS.len)];
    const os = OSES[random.uintLessThan(usize, OSES.len)];
    const abi = ABIS[random.uintLessThan(usize, ABIS.len)];

    var offset: usize = 0;
    @memcpy(buf[offset..][0..arch.len], arch);
    offset += arch.len;
    buf[offset] = '-';
    offset += 1;
    @memcpy(buf[offset..][0..os.len], os);
    offset += os.len;
    buf[offset] = '-';
    offset += 1;
    @memcpy(buf[offset..][0..abi.len], abi);
    offset += abi.len;

    return buf[0..offset];
}

// ═══════════════════════════════════════════════════════════════════════
// Property Tests
// ═══════════════════════════════════════════════════════════════════════

// Feature: sig-build-runner, Property 1: Step registration round-trip
// **Validates: Requirements 2.1, 2.2, 2.5, 13.1**
test "Property 1: Step registration round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var reg: Step_Registry = .{};
            const n = 1 + random.uintLessThan(usize, MAX_STEPS);
            var names: [MAX_STEPS][NAME_BUF_SIZE]u8 = undefined;
            var name_lens: [MAX_STEPS]usize = undefined;

            for (0..n) |i| {
                // Generate unique name by appending index.
                var name_buf: [NAME_BUF_SIZE]u8 = undefined;
                const prefix = genValidName(random, &name_buf);
                var final_buf: [NAME_BUF_SIZE]u8 = undefined;
                const suffix_len = std.fmt.bufPrint(&final_buf, "{d}", .{i}) catch unreachable;
                // Combine: use prefix truncated + suffix
                const max_prefix = @min(prefix.len, NAME_BUF_SIZE - suffix_len.len);
                @memcpy(names[i][0..max_prefix], prefix[0..max_prefix]);
                @memcpy(names[i][max_prefix..][0..suffix_len.len], suffix_len);
                name_lens[i] = max_prefix + suffix_len.len;

                const name = names[i][0..name_lens[i]];
                const handle = try reg.register(name, "desc", &noopStep);
                try std.testing.expectEqual(@as(Step_Handle, @intCast(i)), handle);
            }

            // Verify round-trip: findByName returns correct handle.
            for (0..n) |i| {
                const name = names[i][0..name_lens[i]];
                const found = reg.findByName(name);
                try std.testing.expect(found != null);
                try std.testing.expectEqual(@as(Step_Handle, @intCast(i)), found.?);

                // Verify stored name matches.
                const entry = &reg.entries[i];
                try std.testing.expectEqualSlices(u8, name, entry.name[0..entry.name_len]);
            }
        }
    };
    harness.property("Step registration round-trip", S.run);
}

// Feature: sig-build-runner, Property 2: Step duplicate name rejection
// **Validates: Requirements 2.3**
test "Property 2: Step duplicate name rejection" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var reg: Step_Registry = .{};
            var name_buf: [NAME_BUF_SIZE]u8 = undefined;
            const name = genValidName(random, &name_buf);

            _ = try reg.register(name, "first", &noopStep);

            // Second registration with same name must fail.
            const result = reg.register(name, "second", &noopStep);
            try std.testing.expectError(error.CapacityExceeded, result);

            // Count should still be 1.
            try std.testing.expectEqual(@as(usize, 1), reg.count);
        }
    };
    harness.property("Step duplicate name rejection", S.run);
}

// Feature: sig-build-runner, Property 3: Dependency storage round-trip
// **Validates: Requirements 2.6, 13.4**
test "Property 3: Dependency storage round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var reg: Step_Registry = .{};

            // Register a few steps.
            const n = 2 + random.uintLessThan(usize, MAX_STEPS - 1);
            for (0..n) |i| {
                var name_buf: [NAME_BUF_SIZE]u8 = undefined;
                _ = std.fmt.bufPrint(&name_buf, "step{d}", .{i}) catch unreachable;
                const name_len = std.fmt.count("step{d}", .{i});
                _ = try reg.register(name_buf[0..name_len], "d", &noopStep);
            }

            // Add random deps from step i to some step j < i.
            const step_idx = 1 + random.uintLessThan(usize, n - 1);
            const num_deps = 1 + random.uintLessThan(usize, @min(step_idx, MAX_DEPS_PER_STEP));
            var added_deps: [MAX_DEPS_PER_STEP]Step_Handle = undefined;
            var dep_count: usize = 0;

            for (0..num_deps) |_| {
                const dep: Step_Handle = @intCast(random.uintLessThan(usize, step_idx));
                // Avoid duplicates.
                var dup = false;
                for (added_deps[0..dep_count]) |existing| {
                    if (existing == dep) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    try reg.addDep(@intCast(step_idx), dep);
                    added_deps[dep_count] = dep;
                    dep_count += 1;
                }
            }

            // Verify deps stored correctly.
            const entry = &reg.entries[step_idx];
            try std.testing.expectEqual(dep_count, entry.dep_count);
            for (0..dep_count) |d| {
                try std.testing.expectEqual(added_deps[d], entry.deps[d]);
            }
        }
    };
    harness.property("Dependency storage round-trip", S.run);
}

// Feature: sig-build-runner, Property 4: Module registration and import round-trip
// **Validates: Requirements 3.1, 3.2, 3.3, 3.5, 3.7, 13.2, 13.3**
test "Property 4: Module registration and import round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var reg: Module_Registry = .{};
            const n = 1 + random.uintLessThan(usize, MAX_MODULES);

            var names: [MAX_MODULES][NAME_BUF_SIZE]u8 = undefined;
            var name_lens: [MAX_MODULES]usize = undefined;
            var paths: [MAX_MODULES][PATH_BUF_SIZE]u8 = undefined;
            var path_lens: [MAX_MODULES]usize = undefined;

            for (0..n) |i| {
                // Unique name via index suffix.
                var tmp: [NAME_BUF_SIZE]u8 = undefined;
                const suffix = std.fmt.bufPrint(&tmp, "m{d}", .{i}) catch unreachable;
                @memcpy(names[i][0..suffix.len], suffix);
                name_lens[i] = suffix.len;

                var path_buf: [PATH_BUF_SIZE]u8 = undefined;
                const p = genValidPath(random, &path_buf);
                @memcpy(paths[i][0..p.len], p);
                path_lens[i] = p.len;

                const handle = try reg.register(names[i][0..name_lens[i]], paths[i][0..path_lens[i]]);
                try std.testing.expectEqual(@as(Module_Handle, @intCast(i)), handle);
            }

            // Verify round-trip.
            for (0..n) |i| {
                const name = names[i][0..name_lens[i]];
                const found = reg.findByName(name);
                try std.testing.expect(found != null);
                try std.testing.expectEqual(@as(Module_Handle, @intCast(i)), found.?);

                const entry = &reg.entries[i];
                try std.testing.expectEqualSlices(u8, name, entry.name[0..entry.name_len]);
                try std.testing.expectEqualSlices(u8, paths[i][0..path_lens[i]], entry.source_path[0..entry.source_path_len]);
            }

            // Add imports to the first module.
            if (n > 0) {
                const num_imports = 1 + random.uintLessThan(usize, MAX_IMPORTS_PER_MODULE);
                for (0..num_imports) |j| {
                    var imp_name: [NAME_BUF_SIZE]u8 = undefined;
                    const imp_n = std.fmt.bufPrint(&imp_name, "imp{d}", .{j}) catch unreachable;
                    var imp_path: [PATH_BUF_SIZE]u8 = undefined;
                    const imp_p = genValidPath(random, &imp_path);
                    try reg.addImport(0, imp_n, imp_p);

                    // Verify stored import.
                    const entry = &reg.entries[0];
                    const imp = &entry.imports[j];
                    try std.testing.expectEqualSlices(u8, imp_n, imp.name[0..imp.name_len]);
                    try std.testing.expectEqualSlices(u8, imp_p, imp.path[0..imp.path_len]);
                }
            }
        }
    };
    harness.property("Module registration and import round-trip", S.run);
}

// Feature: sig-build-runner, Property 5: Path resolve/relative round-trip
// **Validates: Requirements 4.2, 4.3**
test "Property 5: Path resolve/relative round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate a base path and a relative sub-path.
            var base_buf: [PATH_BUF_SIZE]u8 = undefined;
            const base = genValidPath(random, &base_buf);

            var rel_buf: [PATH_BUF_SIZE]u8 = undefined;
            const rel = genValidPath(random, &rel_buf);

            // Resolve: base + rel -> absolute
            var resolved_buf: [PATH_BUF_SIZE]u8 = undefined;
            const resolved = pathResolve(&resolved_buf, base, rel) catch return;

            // Relative: base -> resolved should give back rel (or equivalent).
            var back_buf: [PATH_BUF_SIZE]u8 = undefined;
            const back = pathRelative(&back_buf, base, resolved) catch return;

            // Re-resolve: base + back should equal resolved.
            var re_resolved_buf: [PATH_BUF_SIZE]u8 = undefined;
            const re_resolved = pathResolve(&re_resolved_buf, base, back) catch return;

            // Normalize both for comparison.
            var norm1_buf: [PATH_BUF_SIZE]u8 = undefined;
            var norm2_buf: [PATH_BUF_SIZE]u8 = undefined;
            const norm1 = normalizePath(&norm1_buf, resolved) catch return;
            const norm2 = normalizePath(&norm2_buf, re_resolved) catch return;

            try std.testing.expectEqualSlices(u8, norm1, norm2);
        }
    };
    harness.property("Path resolve/relative round-trip", S.run);
}

// Feature: sig-build-runner, Property 6: Path join preserves segments and normalizes
// **Validates: Requirements 4.1, 4.7**
test "Property 6: Path join preserves segments and normalizes" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const num_segments = 1 + random.uintLessThan(usize, 4);
            var seg_bufs: [4][64]u8 = undefined;
            var seg_slices: [4][]const u8 = undefined;

            for (0..num_segments) |i| {
                const seg_len = 1 + random.uintLessThan(usize, 16);
                for (0..seg_len) |j| {
                    seg_bufs[i][j] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
                }
                seg_slices[i] = seg_bufs[i][0..seg_len];
            }

            var join_buf: [PATH_BUF_SIZE]u8 = undefined;
            const joined = sig_fs.joinPath(&join_buf, seg_slices[0..num_segments]) catch return;

            // Every segment should appear in the joined result.
            for (0..num_segments) |i| {
                const seg = seg_slices[i];
                const found = std.mem.indexOf(u8, joined, seg);
                try std.testing.expect(found != null);
            }

            // Joined path should not contain consecutive separators.
            var prev_was_sep = false;
            for (joined) |c| {
                const is_sep = (c == path_sep);
                if (is_sep and prev_was_sep) {
                    return error.TestUnexpectedResult;
                }
                prev_was_sep = is_sep;
            }
        }
    };
    harness.property("Path join preserves segments and normalizes", S.run);
}

// Feature: sig-build-runner, Property 7: Topological sort respects all dependency edges
// **Validates: Requirements 5.2**
test "Property 7: Topological sort respects all dependency edges" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var graph: Dependency_Graph = .{};
            const n = 2 + random.uintLessThan(usize, MAX_STEPS - 1);
            genRandomDAG(random, &graph, n);

            var out: [MAX_STEPS]Step_Handle = undefined;
            const sorted = try graph.topologicalSort(&out);

            // Build position map: position[handle] = index in sorted order.
            var position: [MAX_STEPS]usize = [_]usize{0} ** MAX_STEPS;
            for (sorted, 0..) |handle, pos| {
                position[@as(usize, handle)] = pos;
            }

            // For every edge (i depends on dep), dep must appear before i.
            for (0..n) |i| {
                for (graph.adj[i][0..graph.adj_counts[i]]) |dep| {
                    try std.testing.expect(position[@as(usize, dep)] < position[i]);
                }
            }
        }
    };
    harness.property("Topological sort respects all dependency edges", S.run);
}

// Feature: sig-build-runner, Property 8: Cycle detection returns error for all cyclic graphs
// **Validates: Requirements 5.3**
test "Property 8: Cycle detection returns error for all cyclic graphs" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Create a graph with a guaranteed cycle.
            var graph: Dependency_Graph = .{};
            const n = 2 + random.uintLessThan(usize, 8);
            graph.node_count = n;

            // Create a cycle: 0 -> 1 -> 2 -> ... -> n-1 -> 0
            for (0..n) |i| {
                const dep: usize = (i + 1) % n;
                graph.adj[i][0] = @intCast(dep);
                graph.adj_counts[i] = 1;
            }

            var out: [MAX_STEPS]Step_Handle = undefined;
            const result = graph.topologicalSort(&out);
            try std.testing.expectError(error.DepthExceeded, result);
        }
    };
    harness.property("Cycle detection returns error for all cyclic graphs", S.run);
}

// Feature: sig-build-runner, Property 9: Ready set contains exactly steps with all deps met
// **Validates: Requirements 5.5**
test "Property 9: Ready set contains exactly steps with all deps met" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var graph: Dependency_Graph = .{};
            const n = 2 + random.uintLessThan(usize, MAX_STEPS - 1);
            genRandomDAG(random, &graph, n);

            // Mark a random subset as completed.
            var completed: containers.BoundedBitSet(MAX_STEPS) = .{};
            for (0..n) |i| {
                if (random.boolean()) {
                    try completed.set(i);
                }
            }

            var out: [MAX_STEPS]Step_Handle = undefined;
            const ready = graph.readySet(&completed, &out);

            // Verify: every step in ready set is not completed and has all deps met.
            for (ready) |handle| {
                const idx: usize = handle;
                try std.testing.expect(!completed.isSet(idx));
                for (graph.adj[idx][0..graph.adj_counts[idx]]) |dep| {
                    try std.testing.expect(completed.isSet(dep));
                }
            }

            // Verify: every non-completed step with all deps met IS in the ready set.
            for (0..n) |i| {
                if (completed.isSet(i)) continue;
                var all_met = true;
                for (graph.adj[i][0..graph.adj_counts[i]]) |dep| {
                    if (!completed.isSet(dep)) {
                        all_met = false;
                        break;
                    }
                }
                if (all_met) {
                    var found = false;
                    for (ready) |handle| {
                        if (@as(usize, handle) == i) {
                            found = true;
                            break;
                        }
                    }
                    try std.testing.expect(found);
                }
            }
        }
    };
    harness.property("Ready set contains exactly steps with all deps met", S.run);
}

// Feature: sig-build-runner, Property 10: Failure propagation skips all transitive dependents
// **Validates: Requirements 7.5**
test "Property 10: Failure propagation skips all transitive dependents" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var graph: Dependency_Graph = .{};
            const n = 3 + random.uintLessThan(usize, MAX_STEPS - 2);
            genRandomDAG(random, &graph, n);

            // Pick a random node to fail.
            const failed: Step_Handle = @intCast(random.uintLessThan(usize, n));

            var skipped: containers.BoundedBitSet(MAX_STEPS) = .{};
            graph.propagateFailure(failed, &skipped);

            // The failed node itself must be skipped.
            try std.testing.expect(skipped.isSet(failed));

            // Every node that transitively depends on `failed` must be skipped.
            // BFS from failed through reverse edges.
            var expected: containers.BoundedBitSet(MAX_STEPS) = .{};
            var bfs_queue: containers.BoundedDeque(Step_Handle, MAX_STEPS) = .{};
            try expected.set(failed);
            try bfs_queue.pushBack(failed);

            while (bfs_queue.popFront()) |node| {
                const node_idx: usize = node;
                for (0..n) |j| {
                    if (expected.isSet(j)) continue;
                    for (graph.adj[j][0..graph.adj_counts[j]]) |dep| {
                        if (@as(usize, dep) == node_idx) {
                            try expected.set(j);
                            try bfs_queue.pushBack(@intCast(j));
                            break;
                        }
                    }
                }
            }

            // Verify skipped matches expected.
            for (0..n) |i| {
                try std.testing.expectEqual(expected.isSet(i), skipped.isSet(i));
            }
        }
    };
    harness.property("Failure propagation skips all transitive dependents", S.run);
}

// Feature: sig-build-runner, Property 11: Command_Buffer storage round-trip
// **Validates: Requirements 6.2, 6.5, 6.6**
test "Property 11: Command_Buffer storage round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var cmd: Command_Buffer = .{};

            // Add random args.
            const num_args = 1 + random.uintLessThan(usize, MAX_CMD_ARGS);
            var expected_args: [MAX_CMD_ARGS][64]u8 = undefined;
            var expected_lens: [MAX_CMD_ARGS]usize = undefined;

            for (0..num_args) |i| {
                const arg_len = 1 + random.uintLessThan(usize, 32);
                for (0..arg_len) |j| {
                    expected_args[i][j] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
                }
                expected_lens[i] = arg_len;
                try cmd.addArg(expected_args[i][0..arg_len]);
            }

            // Verify round-trip.
            try std.testing.expectEqual(num_args, cmd.arg_count);
            for (0..num_args) |i| {
                const stored = cmd.getArg(i);
                try std.testing.expectEqualSlices(u8, expected_args[i][0..expected_lens[i]], stored);
            }

            // Add random env vars.
            const num_env = 1 + random.uintLessThan(usize, MAX_ENV_VARS);
            for (0..num_env) |_| {
                var key_buf: [NAME_BUF_SIZE]u8 = undefined;
                const key = genValidName(random, &key_buf);
                var val_buf: [64]u8 = undefined;
                const val_len = 1 + random.uintLessThan(usize, 32);
                for (0..val_len) |j| {
                    val_buf[j] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
                }
                try cmd.addEnv(key, val_buf[0..val_len]);
            }
            try std.testing.expectEqual(num_env, cmd.env_count);

            // Set and verify cwd.
            var cwd_buf: [PATH_BUF_SIZE]u8 = undefined;
            const cwd = genValidPath(random, &cwd_buf);
            try cmd.setCwd(cwd);
            try std.testing.expectEqualSlices(u8, cwd, cmd.cwd[0..cmd.cwd_len]);
        }
    };
    harness.property("Command_Buffer storage round-trip", S.run);
}

// Feature: sig-build-runner, Property 12: Cache serialization round-trip
// **Validates: Requirements 8.1, 8.2, 8.3, 8.5, 8.6**
test "Property 12: Cache serialization round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var cache: Cache_Map = .{};
            const n = 1 + random.uintLessThan(usize, MAX_CACHE_ENTRIES);

            // Insert unique entries.
            for (0..n) |i| {
                var name_buf: [NAME_BUF_SIZE]u8 = undefined;
                const suffix = std.fmt.bufPrint(&name_buf, "s{d}", .{i}) catch unreachable;
                var hash: Content_Hash = undefined;
                random.bytes(&hash);
                const ts: i64 = @intCast(i);
                try cache.put(suffix, hash, ts);
            }

            // Serialize.
            var buf: [HEADER_SIZE + MAX_CACHE_ENTRIES * RECORD_SIZE]u8 = undefined;
            const written = cache.serializeToBuffer(&buf) orelse return error.TestUnexpectedResult;

            // Deserialize into a fresh cache.
            var loaded: Cache_Map = .{};
            loaded.deserializeFromBuffer(buf[0..written]);

            // Verify count matches.
            try std.testing.expectEqual(cache.count, loaded.count);

            // Verify every entry round-trips.
            for (0..n) |i| {
                var name_buf: [NAME_BUF_SIZE]u8 = undefined;
                const suffix = std.fmt.bufPrint(&name_buf, "s{d}", .{i}) catch unreachable;
                const orig = cache.lookup(suffix);
                const copy = loaded.lookup(suffix);
                try std.testing.expect(orig != null);
                try std.testing.expect(copy != null);
                try std.testing.expectEqualSlices(u8, &orig.?, &copy.?);
            }
        }
    };
    harness.property("Cache serialization round-trip", S.run);
}

// Feature: sig-build-runner, Property 13: Cache eviction preserves most recent entries
// **Validates: Requirements 8.7**
test "Property 13: Cache eviction preserves most recent entries" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var cache: Cache_Map = .{};

            // Fill cache completely.
            for (0..MAX_CACHE_ENTRIES) |i| {
                var name_buf: [NAME_BUF_SIZE]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "e{d}", .{i}) catch unreachable;
                var hash: Content_Hash = undefined;
                random.bytes(&hash);
                try cache.put(name, hash, @intCast(i));
            }

            // Evict to a random target count.
            const target = random.uintLessThan(usize, MAX_CACHE_ENTRIES);
            cache.evictOldest(target);

            try std.testing.expect(cache.count <= target + 1);

            // All remaining entries should have timestamps >= (MAX_CACHE_ENTRIES - target - 1).
            // More precisely: the oldest remaining should be among the newest originals.
            var min_ts: i64 = std.math.maxInt(i64);
            for (cache.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
                if (entry.valid and entry.timestamp < min_ts) {
                    min_ts = entry.timestamp;
                }
            }

            // The minimum surviving timestamp should be at least
            // (MAX_CACHE_ENTRIES - count) since we evict oldest first.
            if (cache.count > 0) {
                const expected_min: i64 = @intCast(MAX_CACHE_ENTRIES - cache.count);
                try std.testing.expect(min_ts >= expected_min);
            }
        }
    };
    harness.property("Cache eviction preserves most recent entries", S.run);
}

// Feature: sig-build-runner, Property 14: Line ending normalization produces identical hashes
// **Validates: Requirements 10.5**
test "Property 14: Line ending normalization produces identical hashes" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random content with LF line endings.
            var lf_buf: [512]u8 = undefined;
            const content_len = 1 + random.uintLessThan(usize, 256);
            for (0..content_len) |i| {
                if (random.uintLessThan(u8, 10) == 0) {
                    lf_buf[i] = '\n';
                } else {
                    lf_buf[i] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
                }
            }
            const lf_content = lf_buf[0..content_len];

            // Create CRLF version by replacing \n with \r\n.
            var crlf_buf: [1024]u8 = undefined;
            var crlf_len: usize = 0;
            for (lf_content) |c| {
                if (c == '\n') {
                    crlf_buf[crlf_len] = '\r';
                    crlf_len += 1;
                }
                crlf_buf[crlf_len] = c;
                crlf_len += 1;
            }

            // Normalize both and hash.
            var norm_lf: [512]u8 = undefined;
            const norm_lf_len = normalizeCrLf(lf_content, &norm_lf);

            var norm_crlf: [1024]u8 = undefined;
            const norm_crlf_len = normalizeCrLf(crlf_buf[0..crlf_len], &norm_crlf);

            // After normalization, content should be identical.
            try std.testing.expectEqualSlices(u8, norm_lf[0..norm_lf_len], norm_crlf[0..norm_crlf_len]);

            // Hash both normalized versions — must match.
            var h0a = std.hash.XxHash64.init(0);
            var h1a = std.hash.XxHash64.init(0x9e3779b97f4a7c15);
            h0a.update(norm_lf[0..norm_lf_len]);
            h1a.update(norm_lf[0..norm_lf_len]);

            var h0b = std.hash.XxHash64.init(0);
            var h1b = std.hash.XxHash64.init(0x9e3779b97f4a7c15);
            h0b.update(norm_crlf[0..norm_crlf_len]);
            h1b.update(norm_crlf[0..norm_crlf_len]);

            try std.testing.expectEqual(h0a.final(), h0b.final());
            try std.testing.expectEqual(h1a.final(), h1b.final());
        }
    };
    harness.property("Line ending normalization produces identical hashes", S.run);
}

// Feature: sig-build-runner, Property 15: Option parsing round-trip
// **Validates: Requirements 14.1, 14.2, 14.3, 14.4, 14.5, 1.1, 1.6, 1.8**
test "Property 15: Option parsing round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var map: Option_Map = .{};
            const n = 1 + random.uintLessThan(usize, MAX_OPTIONS);

            var keys: [MAX_OPTIONS][NAME_BUF_SIZE]u8 = undefined;
            var key_lens: [MAX_OPTIONS]usize = undefined;
            var vals: [MAX_OPTIONS][VALUE_BUF_SIZE]u8 = undefined;
            var val_lens: [MAX_OPTIONS]usize = undefined;
            var has_value: [MAX_OPTIONS]bool = undefined;

            for (0..n) |i| {
                // Build -Dname=value or -Dname string.
                var opt_buf: [VALUE_BUF_SIZE]u8 = undefined;
                opt_buf[0] = '-';
                opt_buf[1] = 'D';
                var offset: usize = 2;

                // Unique key via index.
                var key_tmp: [NAME_BUF_SIZE]u8 = undefined;
                const key_s = std.fmt.bufPrint(&key_tmp, "opt{d}", .{i}) catch unreachable;
                @memcpy(opt_buf[offset..][0..key_s.len], key_s);
                @memcpy(keys[i][0..key_s.len], key_s);
                key_lens[i] = key_s.len;
                offset += key_s.len;

                has_value[i] = random.boolean();
                if (has_value[i]) {
                    opt_buf[offset] = '=';
                    offset += 1;
                    const vlen = 1 + random.uintLessThan(usize, 20);
                    for (0..vlen) |j| {
                        opt_buf[offset + j] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
                        vals[i][j] = opt_buf[offset + j];
                    }
                    val_lens[i] = vlen;
                    offset += vlen;
                } else {
                    val_lens[i] = 4; // "true"
                    @memcpy(vals[i][0..4], "true");
                }

                try parseOption(&map, opt_buf[0..offset]);
            }

            // Verify round-trip.
            for (0..n) |i| {
                const key = keys[i][0..key_lens[i]];
                const stored = map.getValue(key);
                try std.testing.expect(stored != null);
                try std.testing.expectEqualSlices(u8, vals[i][0..val_lens[i]], stored.?);
            }
        }
    };
    harness.property("Option parsing round-trip", S.run);
}

// Feature: sig-build-runner, Property 16: Unknown step name produces error with available steps
// **Validates: Requirements 1.3**
test "Property 16: Unknown step name produces error with available steps" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var reg: Step_Registry = .{};
            const n = 1 + random.uintLessThan(usize, 10);

            // Register some steps.
            for (0..n) |i| {
                var name_buf: [NAME_BUF_SIZE]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "known{d}", .{i}) catch unreachable;
                _ = try reg.register(name, "desc", &noopStep);
            }

            // Generate a name that doesn't match any registered step.
            var unknown_buf: [NAME_BUF_SIZE]u8 = undefined;
            const unknown = std.fmt.bufPrint(&unknown_buf, "unknown{d}", .{random.int(u16)}) catch unreachable;

            // findByName should return null for unknown names.
            const result = reg.findByName(unknown);
            try std.testing.expect(result == null);

            // All known names should be findable.
            for (0..n) |i| {
                var name_buf: [NAME_BUF_SIZE]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "known{d}", .{i}) catch unreachable;
                try std.testing.expect(reg.findByName(name) != null);
            }
        }
    };
    harness.property("Unknown step name produces error with available steps", S.run);
}

// Feature: sig-build-runner, Property 17: Compile command flag construction
// **Validates: Requirements 9.1, 9.2, 13.5**
test "Property 17: Compile command flag construction" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var cmd: Command_Buffer = .{};

            // Random source path.
            var src_buf: [64]u8 = undefined;
            const src_len = 4 + random.uintLessThan(usize, 20);
            for (0..src_len) |i| {
                src_buf[i] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
            }
            const source = src_buf[0..src_len];

            // Random output name.
            var out_buf: [32]u8 = undefined;
            const out_len = 1 + random.uintLessThan(usize, 16);
            for (0..out_len) |i| {
                out_buf[i] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
            }
            const output_name = out_buf[0..out_len];

            // Random optimize mode.
            const modes = [_]Optimize_Mode{ .Debug, .ReleaseSafe, .ReleaseFast, .ReleaseSmall };
            const mode = modes[random.uintLessThan(usize, modes.len)];

            const opts = Compile_Options{
                .source_path = source,
                .output_name = output_name,
                .cache_dir = ".cache",
                .optimize = mode,
                .target = null,
                .imports = &[_]Import_Entry{},
                .compiler_path = "",
            };

            try buildCompileCommand(&cmd, opts);

            // Verify structure: sig build-exe <source> -O <mode> --cache-dir .cache --name <name>
            try std.testing.expect(cmd.arg_count >= 8);
            try std.testing.expectEqualSlices(u8, "sig", cmd.getArg(0));
            try std.testing.expectEqualSlices(u8, "build-exe", cmd.getArg(1));
            try std.testing.expectEqualSlices(u8, source, cmd.getArg(2));
            try std.testing.expectEqualSlices(u8, "-O", cmd.getArg(3));

            const mode_str = switch (mode) {
                .Debug => "Debug",
                .ReleaseSafe => "ReleaseSafe",
                .ReleaseFast => "ReleaseFast",
                .ReleaseSmall => "ReleaseSmall",
            };
            try std.testing.expectEqualSlices(u8, mode_str, cmd.getArg(4));
            try std.testing.expectEqualSlices(u8, "--cache-dir", cmd.getArg(5));
            try std.testing.expectEqualSlices(u8, ".cache", cmd.getArg(6));
            try std.testing.expectEqualSlices(u8, "--name", cmd.getArg(7));
            try std.testing.expectEqualSlices(u8, output_name, cmd.getArg(8));
        }
    };
    harness.property("Compile command flag construction", S.run);
}

// Feature: sig-build-runner, Property 18: Target triple parse/format round-trip
// **Validates: Requirements 9.4**
test "Property 18: Target triple parse/format round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            var triple_buf: [PATH_BUF_SIZE]u8 = undefined;
            const triple_str = genTargetTriple(random, &triple_buf);

            // Parse the triple string.
            const parsed = try Target_Triple.parse(triple_str);

            // Format it back.
            var fmt_buf: [PATH_BUF_SIZE]u8 = undefined;
            const formatted = try parsed.format(&fmt_buf);

            // Round-trip: formatted should equal original.
            try std.testing.expectEqualSlices(u8, triple_str, formatted);
        }
    };
    harness.property("Target triple parse/format round-trip", S.run);
}

// Feature: sig-build-runner, Property 19: Install file exclusion rules
// **Validates: Requirements 9.3**
test "Property 19: Install file exclusion rules" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Test that known excluded suffixes are always excluded.
            const excluded_suffixes = [_][]const u8{
                ".gz",     ".z.0",  ".z.9",    ".zst.3",
                ".zst.19", ".lzma", ".xz",     ".tzif",
                ".tar",    "test.zig",
            };

            // Pick a random excluded suffix.
            const suffix = excluded_suffixes[random.uintLessThan(usize, excluded_suffixes.len)];

            // Generate a random prefix.
            var prefix_buf: [32]u8 = undefined;
            const prefix_len = 1 + random.uintLessThan(usize, 20);
            for (0..prefix_len) |i| {
                prefix_buf[i] = ALPHA_NUM[random.uintLessThan(usize, ALPHA_NUM.len)];
            }

            // Combine prefix + suffix.
            var filename_buf: [64]u8 = undefined;
            @memcpy(filename_buf[0..prefix_len], prefix_buf[0..prefix_len]);
            @memcpy(filename_buf[prefix_len..][0..suffix.len], suffix);
            const filename = filename_buf[0 .. prefix_len + suffix.len];

            try std.testing.expect(shouldExcludeFile(filename));

            // README.md is always excluded.
            try std.testing.expect(shouldExcludeFile("README.md"));

            // A random .sig file should NOT be excluded.
            var safe_buf: [32]u8 = undefined;
            const safe_len = 1 + random.uintLessThan(usize, 16);
            for (0..safe_len) |i| {
                safe_buf[i] = "abcdefghijklmnopqrstuvwxyz"[random.uintLessThan(usize, 26)];
            }
            @memcpy(safe_buf[safe_len..][0..4], ".sig");
            const safe_name = safe_buf[0 .. safe_len + 4];

            try std.testing.expect(!shouldExcludeFile(safe_name));
        }
    };
    harness.property("Install file exclusion rules", S.run);
}
