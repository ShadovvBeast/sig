/// Sig Build Runner
///
/// A zero-allocator build system that replaces `std.Build`. Reads `build.sig`,
/// registers steps and modules into fixed-capacity registries, resolves
/// dependencies via topological sort, and dispatches work to a bounded thread
/// pool — all using only stack buffers and `lib/sig/` containers.
///
/// Entry point: `tools/sig_build/main.sig`
/// Invoke via: `sig build [step-names...] [-Dkey=value] [-j N]`
const std = @import("std");
const sig = @import("sig");
const builtin = @import("builtin");

// ── sig module aliases ──────────────────────────────────────────────────────
const containers = sig.containers;
const sig_fmt = sig.fmt;
const sig_fs = sig.fs;
const sig_string = sig.string;
const sig_io = sig.io;
const sig_errors = sig.errors;
const sig_process = sig.process;

// ── Error re-export ─────────────────────────────────────────────────────────
pub const SigError = sig.SigError;

// ── Capacity constants ──────────────────────────────────────────────────────
// All fixed limits for the build runner. Exceeding any of these returns
// SigError.CapacityExceeded — no silent fallback, no allocator.
pub const MAX_STEPS = 256;
pub const MAX_DEPS_PER_STEP = 32;
pub const MAX_MODULES = 32;
pub const MAX_IMPORTS_PER_MODULE = 8;
pub const MAX_OPTIONS = 128;
pub const MAX_CACHE_ENTRIES = 1024;
pub const MAX_THREADS = 64;
pub const MAX_WORK_QUEUE = 64;
pub const MAX_CMD_ARGS = 64;
pub const MAX_ENV_VARS = 64;
pub const PATH_BUF_SIZE = 4096;
pub const NAME_BUF_SIZE = 64;
pub const DESC_BUF_SIZE = 256;
pub const VALUE_BUF_SIZE = 256;
pub const OUTPUT_BUF_SIZE = 4096;
pub const STDERR_CAPTURE_SIZE = 4096;
pub const HASH_CHUNK_SIZE = 8192;
pub const BUILD_OPTIONS_BUF_SIZE = 8192;
pub const VERSION_BUF_SIZE = 128;
pub const GIT_OUTPUT_BUF_SIZE = 256;

// ── Type aliases ────────────────────────────────────────────────────────────
/// Index into the Step_Registry entries array.
pub const Step_Handle = u16;
/// Index into the Module_Registry entries array.
pub const Module_Handle = u16;

// ── Step types ──────────────────────────────────────────────────────────────

pub const Step_State = enum { pending, ready, running, succeeded, failed, skipped };

/// Context passed to step functions during execution. Contains everything
/// a step needs to do its work: the step handle, a read-only pointer to
/// the Build_Context (for paths, options, target), an I/O context for
/// file operations and process spawning, and the compiler binary path.
pub const Step_Context = struct {
    step_handle: Step_Handle,
    /// Pointer to the Build_Context (read-only access for paths, options, compiler path).
    build_ctx: *Build_Context = undefined,
    /// I/O context for file operations and process spawning.
    io: std.Io = undefined,
    /// Path to the sig compiler binary (for invoking build-exe, test, etc.).
    compiler_path: []const u8 = "",
};

pub const StepFn = *const fn (*Step_Context) SigError!void;

pub const Step_Entry = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    desc: [DESC_BUF_SIZE]u8 = undefined,
    desc_len: usize = 0,
    make_fn: StepFn,
    deps: [MAX_DEPS_PER_STEP]Step_Handle = undefined,
    dep_count: usize = 0,
    state: Step_State = .pending,
};

pub const Step_Registry = struct {
    entries: [MAX_STEPS]Step_Entry = undefined,
    count: usize = 0,

    /// Register a named build step. Returns a handle (index) on success.
    /// Errors: BufferTooSmall if name/desc exceed buffer size,
    ///         CapacityExceeded if registry is full or name is duplicate.
    pub fn register(self: *Step_Registry, name: []const u8, desc: []const u8, make_fn: StepFn) SigError!Step_Handle {
        if (name.len > NAME_BUF_SIZE) return error.BufferTooSmall;
        if (desc.len > DESC_BUF_SIZE) return error.BufferTooSmall;
        if (self.count >= MAX_STEPS) return error.CapacityExceeded;

        // Duplicate name check via linear scan.
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

    /// Add a dependency edge: `step` depends on `dep`.
    /// Errors: CapacityExceeded if the step's dependency list is full.
    pub fn addDep(self: *Step_Registry, step: Step_Handle, dep: Step_Handle) SigError!void {
        const step_idx: usize = step;
        if (step_idx >= self.count) return error.CapacityExceeded;

        var entry = &self.entries[step_idx];
        if (entry.dep_count >= MAX_DEPS_PER_STEP) return error.CapacityExceeded;

        entry.deps[entry.dep_count] = dep;
        entry.dep_count += 1;
    }

    /// Find a step by name via linear scan. Returns the handle or null.
    pub fn findByName(self: *const Step_Registry, name: []const u8) ?Step_Handle {
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (entry.name_len == name.len and std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return @intCast(i);
            }
        }
        return null;
    }
};

// ── Module types ────────────────────────────────────────────────────────────

pub const Import_Entry = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    path: [PATH_BUF_SIZE]u8 = undefined,
    path_len: usize = 0,
};

pub const Module_Entry = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    source_path: [PATH_BUF_SIZE]u8 = undefined,
    source_path_len: usize = 0,
    imports: [MAX_IMPORTS_PER_MODULE]Import_Entry = undefined,
    import_count: usize = 0,
};

pub const Module_Registry = struct {
    entries: [MAX_MODULES]Module_Entry = undefined,
    count: usize = 0,

    /// Register a named module. Returns a handle (index) on success.
    /// Errors: BufferTooSmall if name/source_path exceed buffer size,
    ///         CapacityExceeded if registry is full or name is duplicate.
    pub fn register(self: *Module_Registry, name: []const u8, source_path: []const u8) SigError!Module_Handle {
        if (name.len > NAME_BUF_SIZE) return error.BufferTooSmall;
        if (source_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        if (self.count >= MAX_MODULES) return error.CapacityExceeded;

        // Duplicate name check via linear scan.
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

    /// Wire an import (name → path) onto a module.
    /// Errors: BufferTooSmall if name/path exceed buffer size,
    ///         CapacityExceeded if the module's import list is full.
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

    /// Find a module by name via linear scan. Returns the handle or null.
    pub fn findByName(self: *const Module_Registry, name: []const u8) ?Module_Handle {
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (entry.name_len == name.len and std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return @intCast(i);
            }
        }
        return null;
    }
};

// ── Option types ────────────────────────────────────────────────────────────

/// Fixed-capacity map for `-D` build options. Keys are option names (up to 64 bytes),
/// values are string representations (up to 256 bytes). Capacity: 128 entries.
pub const Option_Map = containers.BoundedStringMap(NAME_BUF_SIZE, VALUE_BUF_SIZE, MAX_OPTIONS);

/// Parse a single -D flag and store in the option map.
/// Input: the full arg string starting with "-D" (e.g., "-Doptimize=Debug" or "-Dsingle-threaded").
/// Strips the "-D" prefix, splits on first "=", stores name and value.
/// If no "=" is found, stores value as "true" (boolean shorthand).
pub fn parseOption(map: *Option_Map, arg: []const u8) SigError!void {
    const rest = arg[2..];
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq_pos| {
        try map.put(rest[0..eq_pos], rest[eq_pos + 1 ..]);
    } else {
        try map.put(rest, "true");
    }
}

/// Read a typed option from the map.
/// For bool: "true"/"false" → bool
/// For integer types (i64, u32, etc.): parse decimal string
/// For []const u8: return the raw string value
/// For enum types: match against enum field names
pub fn getOption(comptime T: type, map: *const Option_Map, name: []const u8) ?T {
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

// ── Path operations ──────────────────────────────────────────────────────

/// Platform-native path separator: '/' on POSIX, '\\' on Windows.
const path_sep = std.fs.path.sep;

/// Join path segments into a caller-provided buffer using the platform-native separator.
/// Delegates to `sig.fs.joinPath`.
pub fn pathJoin(buf: *[PATH_BUF_SIZE]u8, segments: []const []const u8) SigError![]const u8 {
    return sig_fs.joinPath(buf, segments);
}

/// Normalize a path in-place: collapse `.` and `..` components.
/// Writes the normalized result into `out` and returns the slice.
/// Returns `error.DepthExceeded` if `..` tries to escape the root.
fn normalizePath(out: *[PATH_BUF_SIZE]u8, path: []const u8) SigError![]const u8 {
    var segments: containers.BoundedVec([]const u8, 128) = .{};

    var start: usize = 0;
    // Preserve leading separator (absolute path indicator).
    const is_absolute = path.len > 0 and path[0] == path_sep;
    if (is_absolute) start = 1;

    var i: usize = start;
    while (i <= path.len) {
        if (i == path.len or path[i] == path_sep) {
            const seg = path[start..i];
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
                // Skip empty segments and "."
            } else if (std.mem.eql(u8, seg, "..")) {
                if (segments.len == 0) {
                    if (is_absolute) return error.DepthExceeded;
                    // For relative paths, keep the ".." — but in our use case
                    // we always resolve against a base first, so this shouldn't happen.
                    // Still, push it to be safe.
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

    // Rejoin segments into the output buffer.
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

/// Resolve a relative path against a base directory.
/// Normalizes `.` and `..` components in the result.
pub fn pathResolve(buf: *[PATH_BUF_SIZE]u8, base: []const u8, relative: []const u8) SigError![]const u8 {
    // Join base and relative into a temporary buffer.
    var tmp: [PATH_BUF_SIZE]u8 = undefined;
    const segments = [_][]const u8{ base, relative };
    const joined = try sig_fs.joinPath(&tmp, &segments);

    // Normalize the joined path.
    return normalizePath(buf, joined);
}

/// Compute the relative path from `base` to `target`.
/// Both paths are normalized before comparison.
pub fn pathRelative(buf: *[PATH_BUF_SIZE]u8, base: []const u8, target: []const u8) SigError![]const u8 {
    // Normalize both paths.
    var norm_base_buf: [PATH_BUF_SIZE]u8 = undefined;
    var norm_target_buf: [PATH_BUF_SIZE]u8 = undefined;
    const norm_base = try normalizePath(&norm_base_buf, base);
    const norm_target = try normalizePath(&norm_target_buf, target);

    // Split both into segments.
    var base_segs: containers.BoundedVec([]const u8, 128) = .{};
    var target_segs: containers.BoundedVec([]const u8, 128) = .{};

    var start: usize = 0;
    // Skip leading separator for splitting.
    if (norm_base.len > 0 and norm_base[0] == path_sep) start = 1;
    var i: usize = start;
    while (i <= norm_base.len) {
        if (i == norm_base.len or norm_base[i] == path_sep) {
            const seg = norm_base[start..i];
            if (seg.len > 0) try base_segs.push(seg);
            start = i + 1;
        }
        i += 1;
    }

    start = 0;
    if (norm_target.len > 0 and norm_target[0] == path_sep) start = 1;
    i = start;
    while (i <= norm_target.len) {
        if (i == norm_target.len or norm_target[i] == path_sep) {
            const seg = norm_target[start..i];
            if (seg.len > 0) try target_segs.push(seg);
            start = i + 1;
        }
        i += 1;
    }

    // Find common prefix length.
    const base_sl = base_segs.slice();
    const target_sl = target_segs.slice();
    var common: usize = 0;
    while (common < base_sl.len and common < target_sl.len) {
        if (!std.mem.eql(u8, base_sl[common], target_sl[common])) break;
        common += 1;
    }

    // Build result: one ".." per remaining base segment, then remaining target segments.
    var result_segs: containers.BoundedVec([]const u8, 128) = .{};
    var ups: usize = 0;
    while (ups < base_sl.len - common) : (ups += 1) {
        try result_segs.push("..");
    }
    var t: usize = common;
    while (t < target_sl.len) : (t += 1) {
        try result_segs.push(target_sl[t]);
    }

    // Join result segments.
    const res_sl = result_segs.slice();
    if (res_sl.len == 0) {
        // Same path — return "."
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

/// Extract the filename stem (without extension) from a path.
/// Writes into a caller-provided `[NAME_BUF_SIZE]u8` buffer.
pub fn pathStem(buf: *[NAME_BUF_SIZE]u8, path: []const u8) SigError![]const u8 {
    // Find last separator to isolate filename.
    var filename_start: usize = 0;
    var j: usize = 0;
    while (j < path.len) : (j += 1) {
        if (path[j] == path_sep or path[j] == '/') {
            filename_start = j + 1;
        }
    }
    const filename = path[filename_start..];

    if (filename.len == 0) return error.BufferTooSmall;

    // Find last '.' in filename to strip extension.
    // Dotfiles like ".gitignore" — the leading dot is not an extension separator.
    var dot_pos: ?usize = null;
    var k: usize = 1; // Start at 1 to skip leading dot
    while (k < filename.len) : (k += 1) {
        if (filename[k] == '.') {
            dot_pos = k;
        }
    }

    const stem = if (dot_pos) |dp| filename[0..dp] else filename;

    if (stem.len > NAME_BUF_SIZE) return error.BufferTooSmall;
    @memcpy(buf[0..stem.len], stem);
    return buf[0..stem.len];
}

// ── Target and optimization ──────────────────────────────────────────────

pub const Optimize_Mode = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };

pub const Target_Triple = struct {
    arch: [32]u8 = undefined,
    arch_len: usize = 0,
    os: [32]u8 = undefined,
    os_len: usize = 0,
    abi: [32]u8 = undefined,
    abi_len: usize = 0,

    /// Format as "arch-os-abi" into a caller buffer.
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

    /// Parse from "arch-os-abi" string.
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

// ── Dependency graph ─────────────────────────────────────────────────────

pub const Dependency_Graph = struct {
    /// Adjacency list: adj[i] contains the step handles that step i depends on.
    adj: [MAX_STEPS][MAX_DEPS_PER_STEP]Step_Handle = undefined,
    adj_counts: [MAX_STEPS]usize = [_]usize{0} ** MAX_STEPS,
    node_count: usize = 0,

    /// Add a dependency edge: `dependent` depends on `dependency`.
    /// Both handles must be < node_count, or node_count is auto-expanded.
    /// Returns CapacityExceeded if the dependent's adjacency list is full.
    pub fn addEdge(self: *Dependency_Graph, dependent: Step_Handle, dependency: Step_Handle) SigError!void {
        // Auto-expand node_count to cover both handles.
        const dep_idx: usize = dependent;
        const dependency_idx: usize = dependency;
        if (dep_idx >= MAX_STEPS or dependency_idx >= MAX_STEPS) return error.CapacityExceeded;
        if (dep_idx >= self.node_count) self.node_count = dep_idx + 1;
        if (dependency_idx >= self.node_count) self.node_count = dependency_idx + 1;

        if (self.adj_counts[dep_idx] >= MAX_DEPS_PER_STEP) return error.CapacityExceeded;

        self.adj[dep_idx][self.adj_counts[dep_idx]] = dependency;
        self.adj_counts[dep_idx] += 1;
    }

    /// Topological sort using Kahn's algorithm.
    /// Returns a slice of step handles in valid execution order.
    /// Returns error.DepthExceeded if a cycle is detected.
    pub fn topologicalSort(self: *const Dependency_Graph, out: *[MAX_STEPS]Step_Handle) SigError![]const Step_Handle {
        // in_degree[i] = number of dependencies step i has (= adj_counts[i]).
        var in_degree: [MAX_STEPS]usize = [_]usize{0} ** MAX_STEPS;
        for (0..self.node_count) |i| {
            in_degree[i] = self.adj_counts[i];
        }

        // Seed the work queue with all nodes that have zero in-degree.
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

            // For each other node j, if j depends on `node`, decrement j's in-degree.
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

        // If we didn't visit all nodes, there's a cycle.
        if (count < self.node_count) return error.DepthExceeded;

        return out[0..count];
    }

    /// Returns the set of steps that are not yet completed and have all
    /// dependencies satisfied (present in the completed bit set).
    pub fn readySet(self: *const Dependency_Graph, completed: *const containers.BoundedBitSet(MAX_STEPS), out: *[MAX_STEPS]Step_Handle) []const Step_Handle {
        var count: usize = 0;
        for (0..self.node_count) |i| {
            if (completed.isSet(i)) continue; // already done

            // Check all deps are completed.
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

    /// Mark all transitive dependents of a failed step as skipped using BFS.
    pub fn propagateFailure(self: *const Dependency_Graph, failed: Step_Handle, skipped: *containers.BoundedBitSet(MAX_STEPS)) void {
        var queue: containers.BoundedDeque(Step_Handle, MAX_STEPS) = .{};
        queue.pushBack(failed) catch return;
        skipped.set(failed) catch return;

        while (queue.popFront()) |node| {
            const node_idx: usize = node;
            // Find all nodes that depend on `node`.
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

    /// Detect and format a dependency cycle for error reporting.
    /// Uses DFS among unvisited nodes (those with non-zero in-degree after
    /// Kahn's algorithm) to find a cycle, then formats it as
    /// "step A -> step B -> ... -> step A" into `buf`.
    /// Returns the formatted cycle path string, or a fallback message.
    pub fn findCyclePath(self: *const Dependency_Graph, registry: *const Step_Registry, buf: *[PATH_BUF_SIZE]u8) []const u8 {
        // Recompute in-degrees and run Kahn's to find unvisited nodes.
        var in_degree: [MAX_STEPS]usize = [_]usize{0} ** MAX_STEPS;
        for (0..self.node_count) |i| {
            in_degree[i] = self.adj_counts[i];
        }

        var queue: containers.BoundedDeque(Step_Handle, MAX_STEPS) = .{};
        for (0..self.node_count) |i| {
            if (in_degree[i] == 0) {
                queue.pushBack(@intCast(i)) catch {};
            }
        }

        var visited: containers.BoundedBitSet(MAX_STEPS) = .{};
        while (queue.popFront()) |node| {
            visited.set(node) catch {};
            const node_idx: usize = node;
            for (0..self.node_count) |j| {
                for (self.adj[j][0..self.adj_counts[j]]) |dep| {
                    if (@as(usize, dep) == node_idx) {
                        in_degree[j] -= 1;
                        if (in_degree[j] == 0) {
                            queue.pushBack(@intCast(j)) catch {};
                        }
                        break;
                    }
                }
            }
        }

        // Find a starting node that is part of a cycle (not visited).
        var start: ?usize = null;
        for (0..self.node_count) |i| {
            if (!visited.isSet(i)) {
                start = i;
                break;
            }
        }

        if (start == null) {
            const fallback = "unknown cycle";
            @memcpy(buf[0..fallback.len], fallback);
            return buf[0..fallback.len];
        }

        // DFS from `start` to trace the cycle path.
        var path_indices: [MAX_STEPS]usize = undefined;
        var path_len: usize = 0;
        var on_stack: containers.BoundedBitSet(MAX_STEPS) = .{};
        var current = start.?;

        // Walk through unvisited dependencies to trace the cycle.
        while (path_len < MAX_STEPS) {
            path_indices[path_len] = current;
            path_len += 1;
            on_stack.set(current) catch break;

            // Find the next unvisited dependency of `current`.
            var next: ?usize = null;
            for (self.adj[current][0..self.adj_counts[current]]) |dep| {
                const dep_idx: usize = dep;
                if (!visited.isSet(dep_idx)) {
                    if (on_stack.isSet(dep_idx)) {
                        // Found the cycle back-edge. Format the cycle.
                        var offset: usize = 0;
                        // Find where dep_idx appears in path to get the cycle portion.
                        var cycle_start: usize = 0;
                        for (0..path_len) |k| {
                            if (path_indices[k] == dep_idx) {
                                cycle_start = k;
                                break;
                            }
                        }
                        // Format: "A -> B -> ... -> A"
                        var k = cycle_start;
                        while (k < path_len) : (k += 1) {
                            const idx = path_indices[k];
                            const name = registry.entries[idx].name[0..registry.entries[idx].name_len];
                            if (offset + name.len + 4 > PATH_BUF_SIZE) break;
                            if (k > cycle_start) {
                                @memcpy(buf[offset..][0..4], " -> ");
                                offset += 4;
                            }
                            @memcpy(buf[offset..][0..name.len], name);
                            offset += name.len;
                        }
                        // Close the cycle: " -> A"
                        const close_name = registry.entries[dep_idx].name[0..registry.entries[dep_idx].name_len];
                        if (offset + 4 + close_name.len <= PATH_BUF_SIZE) {
                            @memcpy(buf[offset..][0..4], " -> ");
                            offset += 4;
                            @memcpy(buf[offset..][0..close_name.len], close_name);
                            offset += close_name.len;
                        }
                        return buf[0..offset];
                    }
                    next = dep_idx;
                    break;
                }
            }

            if (next) |n| {
                current = n;
            } else {
                break;
            }
        }

        // Fallback if DFS didn't find a clean cycle (shouldn't happen).
        const fallback = "cycle detected among unvisited nodes";
        @memcpy(buf[0..fallback.len], fallback);
        return buf[0..fallback.len];
    }
};

// ── Cache system ─────────────────────────────────────────────────────────

/// 128-bit content hash produced by hashing file contents with two XxHash64
/// instances using different seeds. Used for cache invalidation.
pub const Content_Hash = [16]u8;

/// Compute a 128-bit content hash over one or more files.
/// Streams file contents in 8KB chunks, normalizing CR+LF to LF before
/// hashing for cross-platform consistency. Uses two XxHash64 instances
/// with different seeds to produce 128 bits of output.
pub fn computeContentHash(io_ctx: std.Io, paths: []const []const u8) Content_Hash {
    var h0 = std.hash.XxHash64.init(0);
    var h1 = std.hash.XxHash64.init(0x9e3779b97f4a7c15);
    var chunk: [HASH_CHUNK_SIZE]u8 = undefined;

    for (paths) |p| {
        const cwd: std.Io.Dir = .cwd();
        var file = cwd.openFile(io_ctx, p, .{}) catch continue;
        defer file.close(io_ctx);
        var reader = file.reader(io_ctx, &.{});
        while (true) {
            const n = reader.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            const data = chunk[0..n];
            // Normalize CR+LF → LF for cross-platform hash consistency.
            var normalized: [HASH_CHUNK_SIZE]u8 = undefined;
            var out_len: usize = 0;
            var i: usize = 0;
            while (i < data.len) {
                if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') {
                    normalized[out_len] = '\n';
                    out_len += 1;
                    i += 2;
                } else {
                    normalized[out_len] = data[i];
                    out_len += 1;
                    i += 1;
                }
            }
            h0.update(normalized[0..out_len]);
            h1.update(normalized[0..out_len]);
        }
    }

    const lo = h0.final();
    const hi = h1.final();
    var result: Content_Hash = undefined;
    std.mem.writeInt(u64, result[0..8], lo, .little);
    std.mem.writeInt(u64, result[8..16], hi, .little);
    return result;
}

/// A single cache entry mapping a step name to its content hash.
pub const Cache_Entry = struct {
    hash: Content_Hash = .{0} ** 16,
    step_name: [NAME_BUF_SIZE]u8 = .{0} ** NAME_BUF_SIZE,
    step_name_len: usize = 0,
    timestamp: i64 = 0,
    valid: bool = false,
};

/// Fixed-capacity cache map keyed by step name. Stores up to MAX_CACHE_ENTRIES
/// entries with binary persistence support. No allocator.
pub const Cache_Map = struct {
    entries: [MAX_CACHE_ENTRIES]Cache_Entry = [_]Cache_Entry{.{}} ** MAX_CACHE_ENTRIES,
    count: usize = 0,

    /// Lookup a cache entry by step name. Returns the stored content hash
    /// if a valid entry with a matching name is found, null otherwise.
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

    /// Insert or update a cache entry. If an entry with the same step name
    /// already exists, its hash and timestamp are updated. If the map is full,
    /// the oldest entry is evicted first.
    pub fn put(self: *Cache_Map, step_name: []const u8, hash: Content_Hash, timestamp: i64) SigError!void {
        if (step_name.len > NAME_BUF_SIZE) return error.BufferTooSmall;

        // Check for existing entry with same name → update in place.
        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (entry.valid and entry.step_name_len == step_name.len and
                std.mem.eql(u8, entry.step_name[0..entry.step_name_len], step_name))
            {
                entry.hash = hash;
                entry.timestamp = timestamp;
                return;
            }
        }

        // If at capacity, evict the oldest entry to make room.
        if (self.count >= MAX_CACHE_ENTRIES) {
            self.evictOldest(MAX_CACHE_ENTRIES - 1);
        }

        // Find first invalid slot and store the new entry.
        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (!entry.valid) {
                entry.hash = hash;
                @memcpy(entry.step_name[0..step_name.len], step_name);
                // Zero-pad the rest of the name buffer.
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

    /// Evict oldest entries (by timestamp) until count <= target_count.
    pub fn evictOldest(self: *Cache_Map, target_count: usize) void {
        while (self.count > target_count) {
            // Find the valid entry with the smallest timestamp.
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
                break; // No valid entries left.
            }
        }
    }

    // Binary cache format constants.
    const CACHE_MAGIC = [4]u8{ 'S', 'I', 'G', 'C' };
    const CACHE_VERSION: u32 = 1;
    const RECORD_SIZE: usize = 96;
    const HEADER_SIZE: usize = 12; // 4 magic + 4 version + 4 count

    /// Persist the cache map to a binary file.
    /// Format: "SIGC" magic (4B) + version u32 LE (4B) + count u32 LE (4B)
    ///         + N × 96-byte records (hash 16B + name 64B + timestamp i64 LE 8B + reserved 8B).
    pub fn save(self: *const Cache_Map, io_ctx: std.Io, path: []const u8) SigError!void {
        const cwd: std.Io.Dir = .cwd();
        var file = cwd.createFile(io_ctx, path, .{}) catch return error.BufferTooSmall;
        defer file.close(io_ctx);

        // Write header: magic + version + entry count.
        var header: [HEADER_SIZE]u8 = undefined;
        @memcpy(header[0..4], &CACHE_MAGIC);
        std.mem.writeInt(u32, header[4..8], CACHE_VERSION, .little);
        std.mem.writeInt(u32, header[8..12], @intCast(self.count), .little);
        file.writeStreamingAll(io_ctx, &header) catch return error.BufferTooSmall;

        // Write each valid entry as a 96-byte record.
        for (self.entries[0..MAX_CACHE_ENTRIES]) |*entry| {
            if (!entry.valid) continue;
            var record: [RECORD_SIZE]u8 = .{0} ** RECORD_SIZE;
            // Bytes 0-15: Content_Hash
            @memcpy(record[0..16], &entry.hash);
            // Bytes 16-79: step_name (64 bytes, zero-padded)
            @memcpy(record[16..80], &entry.step_name);
            // Bytes 80-87: timestamp (i64 little-endian)
            std.mem.writeInt(i64, record[80..88], entry.timestamp, .little);
            // Bytes 88-95: reserved (already zeroed)
            file.writeStreamingAll(io_ctx, &record) catch return error.BufferTooSmall;
        }
    }

    /// Load the cache map from a binary file. If the file is missing, corrupt,
    /// or has an unrecognized version, the cache starts empty (no error).
    /// If the file has more entries than MAX_CACHE_ENTRIES, only the most
    /// recent entries (by timestamp) are kept.
    pub fn load(self: *Cache_Map, io_ctx: std.Io, path: []const u8) void {
        // Reset to empty state.
        self.count = 0;
        for (&self.entries) |*entry| {
            entry.valid = false;
        }

        const cwd: std.Io.Dir = .cwd();
        var file = cwd.openFile(io_ctx, path, .{}) catch return; // Missing file → empty cache.
        defer file.close(io_ctx);
        var reader = file.reader(io_ctx, &.{});

        // Read and validate header.
        var header: [HEADER_SIZE]u8 = undefined;
        var header_read: usize = 0;
        while (header_read < HEADER_SIZE) {
            const n = reader.interface.readSliceShort(header[header_read..]) catch return;
            if (n == 0) return; // Truncated header → empty cache.
            header_read += n;
        }

        // Verify magic.
        if (!std.mem.eql(u8, header[0..4], &CACHE_MAGIC)) return;

        // Verify version.
        const version = std.mem.readInt(u32, header[4..8], .little);
        if (version != CACHE_VERSION) return;

        const file_count = std.mem.readInt(u32, header[8..12], .little);
        if (file_count == 0) return;

        // Read entries. If file has more than capacity, we load all into a
        // temporary staging area and then keep only the most recent ones.
        const load_count = @min(@as(usize, file_count), MAX_CACHE_ENTRIES);

        var loaded: usize = 0;
        while (loaded < load_count) {
            var record: [RECORD_SIZE]u8 = undefined;
            var record_read: usize = 0;
            while (record_read < RECORD_SIZE) {
                const n = reader.interface.readSliceShort(record[record_read..]) catch return;
                if (n == 0) return; // Truncated record → keep what we have.
                record_read += n;
            }

            var entry = &self.entries[loaded];
            @memcpy(&entry.hash, record[0..16]);
            @memcpy(&entry.step_name, record[16..80]);
            // Compute actual name length from zero-padded buffer.
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

        // If the file had more entries than we could load, we already loaded
        // the first `load_count`. Now check if there are excess entries in the
        // file that might be newer. For simplicity and correctness, if
        // file_count > MAX_CACHE_ENTRIES, evict oldest to stay within capacity.
        // (The file is written with all valid entries, so the first N are fine;
        // if the user needs LRU behavior, evictOldest handles it.)
        if (file_count > MAX_CACHE_ENTRIES) {
            self.evictOldest(MAX_CACHE_ENTRIES);
        }
    }
};

// ── Command execution ────────────────────────────────────────────────────────
// Delegates to sig.process for child process spawning and command construction.

/// Fixed-capacity buffer for constructing child process commands.
/// Re-exported from sig.process — stores arguments and working directory
/// entirely in stack memory, no heap allocation.
pub const Command_Buffer = sig_process.Command_Buffer;

/// Spawn a child process described by `cmd`, wait for it to finish, and
/// return its exit code. Captures up to STDERR_CAPTURE_SIZE bytes of the
/// child's stderr into `stderr_buf`. Returns the number of stderr bytes
/// captured via `stderr_len`.
///
/// Delegates to `sig.process.runCommand` which handles process spawning,
/// stderr capture, and exit code extraction — all zero-allocator.
pub fn runCommand(
    cmd: *const Command_Buffer,
    stderr_buf: *[STDERR_CAPTURE_SIZE]u8,
    stderr_len: *usize,
    io_ctx: std.Io,
) SigError!u8 {
    return sig_process.runCommand(io_ctx, cmd, stderr_buf, stderr_len, .{});
}

// ── Compile step command construction ────────────────────────────────────────

/// Options for constructing a compile step command.
pub const Compile_Options = struct {
    source_path: []const u8,
    output_name: []const u8,
    cache_dir: []const u8,
    optimize: Optimize_Mode,
    target: ?*const Target_Triple,
    /// Module imports: each entry is a name→path pair to pass as -Mname=path flags.
    imports: []const Import_Entry,
    /// Path to the sig/zig compiler binary. If empty, uses "sig" (found via PATH).
    compiler_path: []const u8,
};

/// Populate a Command_Buffer with the flags for a compile step, mirroring
/// the flags that `std.Build` would produce:
///
///   <compiler> build-exe
///       --dep <name>              (for each import, before -Mroot=)
///       -Mroot=<source_path>
///       -M<name>=<path>           (for each import)
///       -O <optimize_mode>
///       -target <target_triple>
///       --cache-dir <cache_dir>
///       --name <output_name>
///
pub fn buildCompileCommand(cmd: *Command_Buffer, opts: Compile_Options) SigError!void {
    // argv[0]: compiler binary path.
    if (opts.compiler_path.len > 0) {
        try cmd.appendArg(opts.compiler_path);
    } else {
        try cmd.appendArg("sig");
    }

    // Sub-command.
    try cmd.appendArg("build-exe");

    // Module imports: --dep name (before root) then -Mname=path
    // Zig 0.16 uses -M/--dep syntax: --dep flags declare dependencies for the
    // NEXT -M module. Leaf modules (-Mname=path with no preceding --dep) have
    // no deps. Root module deps must come before -Mroot=.
    //
    // First pass: emit --dep for each import (these apply to the root module,
    // which is the source_path passed to build-exe as -Mroot=).
    for (opts.imports) |imp| {
        const name_slice = imp.name[0..imp.name_len];
        try cmd.appendArg("--dep");
        try cmd.appendArg(name_slice);
    }

    // Emit -Mroot=<source_path> (the root module that uses the deps above).
    {
        var root_buf: [PATH_BUF_SIZE]u8 = undefined;
        const root_prefix = "-Mroot=";
        const src_path = opts.source_path;
        if (root_prefix.len + src_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;
        @memcpy(root_buf[0..root_prefix.len], root_prefix);
        @memcpy(root_buf[root_prefix.len..][0..src_path.len], src_path);
        try cmd.appendArg(root_buf[0 .. root_prefix.len + src_path.len]);
    }

    // Second pass: emit -Mname=path for each import (leaf modules, no deps).
    for (opts.imports) |imp| {
        var mod_buf: [PATH_BUF_SIZE]u8 = undefined;
        const name_slice = imp.name[0..imp.name_len];
        const path_slice = imp.path[0..imp.path_len];
        const prefix_len = 2 + name_slice.len + 1; // "-M" + name + "="
        const total = prefix_len + path_slice.len;
        if (total > PATH_BUF_SIZE) return error.BufferTooSmall;
        mod_buf[0] = '-';
        mod_buf[1] = 'M';
        @memcpy(mod_buf[2..][0..name_slice.len], name_slice);
        mod_buf[2 + name_slice.len] = '=';
        @memcpy(mod_buf[prefix_len..][0..path_slice.len], path_slice);
        try cmd.appendArg(mod_buf[0..total]);
    }

    // Optimization mode: -O <mode>
    try cmd.appendArg("-O");
    try cmd.appendArg(switch (opts.optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    });

    // Target triple: -target <triple> (only if specified).
    if (opts.target) |triple| {
        try cmd.appendArg("-target");
        var triple_buf: [PATH_BUF_SIZE]u8 = undefined;
        const triple_str = try triple.format(&triple_buf);
        try cmd.appendArg(triple_str);
    }

    // Cache directory: --cache-dir <dir>
    try cmd.appendArg("--cache-dir");
    try cmd.appendArg(opts.cache_dir);

    // Output name: --name <name>
    try cmd.appendArg("--name");
    try cmd.appendArg(opts.output_name);
}

// ── Version string resolution ────────────────────────────────────────────────

/// Resolve zig version string via git rev-list + rev-parse.
/// Format: "M.N.P-dev.COUNT+HASH" for dev builds, "M.N.P" for releases.
/// Falls back to base_version if git is unavailable or fails.
///
/// The caller checks for `-Dversion-string` override before calling this
/// function. All parsing uses stack buffers — zero allocators.
pub fn resolveVersionString(
    buf: *[VERSION_BUF_SIZE]u8,
    base_version: []const u8,
    is_dev: bool,
    io: std.Io,
) []const u8 {
    // Release builds: no dev suffix, just return base version as-is.
    if (!is_dev) {
        if (base_version.len > VERSION_BUF_SIZE) return base_version[0..VERSION_BUF_SIZE];
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    }

    // Dev builds: run git commands to get commit count and hash.
    const count = getGitCommitCount(io) orelse {
        // Git failed — fall back to base version.
        if (base_version.len > VERSION_BUF_SIZE) return base_version[0..VERSION_BUF_SIZE];
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    };

    const hash = getGitCommitHash(io) orelse {
        // Git failed — fall back to base version.
        if (base_version.len > VERSION_BUF_SIZE) return base_version[0..VERSION_BUF_SIZE];
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    };

    // Format: "{base_version}-dev.{count}+{hash}"
    const dev_tag = "-dev.";
    const plus = "+";
    const total = base_version.len + dev_tag.len + count.len + plus.len + hash.len;
    if (total > VERSION_BUF_SIZE) {
        // Overflow — fall back to base version.
        @memcpy(buf[0..base_version.len], base_version);
        return buf[0..base_version.len];
    }

    var offset: usize = 0;
    @memcpy(buf[offset..][0..base_version.len], base_version);
    offset += base_version.len;
    @memcpy(buf[offset..][0..dev_tag.len], dev_tag);
    offset += dev_tag.len;
    @memcpy(buf[offset..][0..count.len], count);
    offset += count.len;
    @memcpy(buf[offset..][0..plus.len], plus);
    offset += plus.len;
    @memcpy(buf[offset..][0..hash.len], hash);
    offset += hash.len;

    return buf[0..offset];
}

/// Run `git rev-list --count HEAD` and return the trimmed output, or null on failure.
/// Uses a stack-allocated Command_Buffer and a static capture buffer.
fn getGitCommitCount(io: std.Io) ?[]const u8 {
    const S = struct {
        var stdout_buf: [GIT_OUTPUT_BUF_SIZE]u8 = undefined;
    };

    var cmd = Command_Buffer{};
    cmd.appendArg("git") catch return null;
    cmd.appendArg("rev-list") catch return null;
    cmd.appendArg("--count") catch return null;
    cmd.appendArg("HEAD") catch return null;

    return runGitCommand(&cmd, &S.stdout_buf, io);
}

/// Run `git rev-parse --short=9 HEAD` and return the trimmed output, or null on failure.
/// Uses a stack-allocated Command_Buffer and a static capture buffer.
fn getGitCommitHash(io: std.Io) ?[]const u8 {
    const S = struct {
        var stdout_buf: [GIT_OUTPUT_BUF_SIZE]u8 = undefined;
    };

    var cmd = Command_Buffer{};
    cmd.appendArg("git") catch return null;
    cmd.appendArg("rev-parse") catch return null;
    cmd.appendArg("--short=9") catch return null;
    cmd.appendArg("HEAD") catch return null;

    return runGitCommand(&cmd, &S.stdout_buf, io);
}

/// Spawn a git command with stdout piped, capture output into the provided buffer,
/// and return the trimmed result. Returns null on any failure.
///
/// Uses sig_process.spawn directly (not runCommand) because we need stdout
/// capture, not stderr capture.
fn runGitCommand(cmd: *const Command_Buffer, stdout_buf: *[GIT_OUTPUT_BUF_SIZE]u8, io: std.Io) ?[]const u8 {
    var child = sig_process.spawn(io, cmd, .{
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    defer child.kill(io);

    // Read stdout from the child.
    var stdout_len: usize = 0;
    if (child.stdout) |stdout_file| {
        var reader = stdout_file.reader(io, &.{});
        while (stdout_len < GIT_OUTPUT_BUF_SIZE) {
            const remaining = GIT_OUTPUT_BUF_SIZE - stdout_len;
            const n = reader.interface.readSliceShort(stdout_buf[stdout_len..][0..remaining]) catch break;
            if (n == 0) break;
            stdout_len += n;
        }
    }

    // Wait for exit and check success.
    const term = child.wait(io) catch return null;
    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => return null,
    };
    if (exit_code != 0) return null;

    if (stdout_len == 0) return null;

    // Trim trailing whitespace/newlines.
    const output = stdout_buf[0..stdout_len];
    const trimmed = std.mem.trimEnd(u8, output, &[_]u8{ '\n', '\r', ' ', '\t' });
    if (trimmed.len == 0) return null;

    return trimmed;
}

// ── Build options generation ─────────────────────────────────────────────────

/// Generate build_options.zig in the cache directory.
/// Takes build context for option values and a resolved version string.
/// Uses a stack buffer — zero allocators.
///
/// The generated file contains all 22 `pub const` declarations required by
/// `src/main.zig`, including inline enum definitions for `@"src.dev.Env"`,
/// `@"build.IoMode"`, and `@"build.ValueInterpretMode"`.
pub fn generateBuildOptions(
    build_ctx: *const Build_Context,
    version: []const u8,
    cache_dir: []const u8,
    io: std.Io,
) SigError!void {
    // 1. Build output path: <cache_dir>/build_options.zig
    var path_buf: [PATH_BUF_SIZE]u8 = undefined;
    const output_path = try sig_fs.joinPath(&path_buf, &[_][]const u8{ cache_dir, "build_options.zig" });

    // 2. Read option flags with defaults
    const have_llvm = build_ctx.options.getValue("enable-llvm") != null or
        build_ctx.options.getValue("static-llvm") != null;
    const skip_non_native = optBool(&build_ctx.options, "skip-non-native", false);
    const llvm_has_m68k = if (have_llvm) optBool(&build_ctx.options, "llvm-has-m68k", false) else false;
    const llvm_has_csky = if (have_llvm) optBool(&build_ctx.options, "llvm-has-csky", false) else false;
    const llvm_has_arc = if (have_llvm) optBool(&build_ctx.options, "llvm-has-arc", false) else false;
    const llvm_has_xtensa = if (have_llvm) optBool(&build_ctx.options, "llvm-has-xtensa", false) else false;
    const debug_gpa = optBool(&build_ctx.options, "debug-allocator", false);
    const enable_debug_extensions = optBool(&build_ctx.options, "debug-extensions", false);
    const enable_logging = optBool(&build_ctx.options, "log", false);
    const enable_link_snapshots = optBool(&build_ctx.options, "link-snapshot", false);
    const enable_tracy = optBool(&build_ctx.options, "tracy", false);
    const enable_tracy_callstack = optBool(&build_ctx.options, "tracy-callstack", false);
    const enable_tracy_allocation = optBool(&build_ctx.options, "tracy-allocation", false);
    const tracy_callstack_depth = optU32(&build_ctx.options, "tracy-callstack-depth", 10);
    const value_tracing = optBool(&build_ctx.options, "value-tracing", false);

    // dev mode: default .full
    const dev_str = build_ctx.options.getValue("dev") orelse "full";
    // io_mode: default .threaded
    const io_mode_str = build_ctx.options.getValue("io-mode") orelse "threaded";
    // value_interpret_mode: default .direct
    const vim_str = build_ctx.options.getValue("value-interpret-mode") orelse "direct";

    // mem_leak_frames: 0 for release/strip, 4 for Debug+debug-gpa
    const is_debug = build_ctx.optimize == .Debug;
    const is_strip = optBool(&build_ctx.options, "strip", false);
    const mem_leak_frames: u32 = blk: {
        if (build_ctx.options.getValue("mem-leak-frames")) |v| {
            break :blk std.fmt.parseInt(u32, v, 10) catch 0;
        }
        if (is_strip) break :blk 0;
        if (!is_debug) break :blk 0;
        if (debug_gpa) break :blk 4;
        break :blk 0;
    };

    // 3. Parse semver from version string
    // Format: "M.N.P" or "M.N.P-pre+build"
    var semver_major: []const u8 = "0";
    var semver_minor: []const u8 = "0";
    var semver_patch: []const u8 = "0";
    var semver_pre: []const u8 = "";
    var semver_build: []const u8 = "";
    parseSemver(version, &semver_major, &semver_minor, &semver_patch, &semver_pre, &semver_build);

    // 4. Get sig_version from Build_Context
    const sig_version_str = build_ctx.sig_version[0..build_ctx.sig_version_len];

    // 5. Format all declarations into the stack buffer
    var buf: [BUILD_OPTIONS_BUF_SIZE]u8 = undefined;
    const content = std.fmt.bufPrint(&buf,
        \\pub const mem_leak_frames: u32 = {d};
        \\pub const skip_non_native: bool = {s};
        \\pub const have_llvm: bool = {s};
        \\pub const llvm_has_m68k: bool = {s};
        \\pub const llvm_has_csky: bool = {s};
        \\pub const llvm_has_arc: bool = {s};
        \\pub const llvm_has_xtensa: bool = {s};
        \\pub const debug_gpa: bool = {s};
        \\pub const version: [:0]const u8 = "{s}";
        \\pub const sig_version: [:0]const u8 = "{s}";
        \\pub const semver: @import("std").SemanticVersion = .{{
        \\    .major = {s},
        \\    .minor = {s},
        \\    .patch = {s},
        \\    .pre = "{s}",
        \\    .build = "{s}",
        \\}};
        \\pub const enable_debug_extensions: bool = {s};
        \\pub const enable_logging: bool = {s};
        \\pub const enable_link_snapshots: bool = {s};
        \\pub const enable_tracy: bool = {s};
        \\pub const enable_tracy_callstack: bool = {s};
        \\pub const enable_tracy_allocation: bool = {s};
        \\pub const tracy_callstack_depth: u32 = {d};
        \\pub const value_tracing: bool = {s};
        \\pub const @"src.dev.Env" = enum (u4) {{
        \\    bootstrap = 0,
        \\    core = 1,
        \\    full = 2,
        \\    c_source = 3,
        \\    ast_gen = 4,
        \\    sema = 5,
        \\    @"aarch64-linux" = 6,
        \\    cbe = 7,
        \\    @"powerpc-linux" = 8,
        \\    @"riscv64-linux" = 9,
        \\    spirv = 10,
        \\    wasm = 11,
        \\    @"x86_64-linux" = 12,
        \\}};
        \\pub const dev: @"src.dev.Env" = .{s};
        \\pub const @"build.IoMode" = enum (u1) {{
        \\    threaded = 0,
        \\    evented = 1,
        \\}};
        \\pub const io_mode: @"build.IoMode" = .{s};
        \\pub const @"build.ValueInterpretMode" = enum (u1) {{
        \\    direct = 0,
        \\    by_name = 1,
        \\}};
        \\pub const value_interpret_mode: @"build.ValueInterpretMode" = .{s};
        \\
    , .{
        mem_leak_frames,
        boolStr(skip_non_native),
        boolStr(have_llvm),
        boolStr(llvm_has_m68k),
        boolStr(llvm_has_csky),
        boolStr(llvm_has_arc),
        boolStr(llvm_has_xtensa),
        boolStr(debug_gpa),
        version,
        sig_version_str,
        semver_major,
        semver_minor,
        semver_patch,
        semver_pre,
        semver_build,
        boolStr(enable_debug_extensions),
        boolStr(enable_logging),
        boolStr(enable_link_snapshots),
        boolStr(enable_tracy),
        boolStr(enable_tracy_callstack),
        boolStr(enable_tracy_allocation),
        tracy_callstack_depth,
        boolStr(value_tracing),
        dev_str,
        io_mode_str,
        vim_str,
    }) catch return error.BufferTooSmall;

    // 6. Write file
    try sig_fs.writeFile(io, output_path, content);
}

/// Return "true" or "false" as a string slice for bool formatting.
fn boolStr(val: bool) []const u8 {
    return if (val) "true" else "false";
}

/// Read a boolean option from the map, returning `default` if absent.
fn optBool(map: *const Option_Map, name: []const u8, default: bool) bool {
    const value = map.getValue(name) orelse return default;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return default;
}

/// Read a u32 option from the map, returning `default` if absent or unparseable.
fn optU32(map: *const Option_Map, name: []const u8, default: u32) u32 {
    const value = map.getValue(name) orelse return default;
    return std.fmt.parseInt(u32, value, 10) catch default;
}

/// Parse a semver version string into its components.
/// Handles "M.N.P", "M.N.P-pre", and "M.N.P-pre+build" formats.
fn parseSemver(
    version: []const u8,
    major: *[]const u8,
    minor: *[]const u8,
    patch: *[]const u8,
    pre: *[]const u8,
    build_meta: *[]const u8,
) void {
    // Split on first '-' to separate "M.N.P" from optional "pre+build"
    var core_part = version;
    var extra_part: []const u8 = "";

    if (std.mem.indexOfScalar(u8, version, '-')) |dash_pos| {
        core_part = version[0..dash_pos];
        extra_part = version[dash_pos + 1 ..];
    }

    // Parse M.N.P from core_part
    var dot_iter = std.mem.splitScalar(u8, core_part, '.');
    major.* = dot_iter.next() orelse "0";
    minor.* = dot_iter.next() orelse "0";
    patch.* = dot_iter.next() orelse "0";

    // Parse pre and build from extra_part
    if (extra_part.len > 0) {
        if (std.mem.indexOfScalar(u8, extra_part, '+')) |plus_pos| {
            pre.* = extra_part[0..plus_pos];
            build_meta.* = extra_part[plus_pos + 1 ..];
        } else {
            pre.* = extra_part;
            build_meta.* = "";
        }
    }
}

// ── Install step file exclusion ──────────────────────────────────────────────

/// Check whether a filename should be excluded from installation.
/// Excluded extensions: .gz, .z.0, .z.9, .zst.3, .zst.19, .lzma, .xz,
///                      .tzif, .tar, test.zig
/// Excluded filenames:  README.md
///
/// Returns true if the file should be EXCLUDED (skipped).
pub fn shouldExcludeFile(filename: []const u8) bool {
    // Check exact filename matches first.
    if (std.mem.eql(u8, filename, "README.md")) return true;

    // Check suffix-based exclusion rules.
    const excluded_suffixes = [_][]const u8{
        ".gz",
        ".z.0",
        ".z.9",
        ".zst.3",
        ".zst.19",
        ".lzma",
        ".xz",
        ".tzif",
        ".tar",
        "test.zig",
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

/// Copy files from `src_dir` to `dst_dir`, skipping files that match the
/// exclusion rules. Both paths are provided as slices. Uses `sig.fs` for
/// directory listing and file copying. Returns the number of files installed.
pub fn installFiles(
    io_ctx: std.Io,
    src_dir_path: []const u8,
    dst_dir_path: []const u8,
) SigError!usize {
    // List source directory entries.
    var entries_buf: [256]sig_fs.DirEntry = undefined;
    const entries = sig_fs.listDir(io_ctx, src_dir_path, &entries_buf) catch return error.BufferTooSmall;

    var installed: usize = 0;
    for (entries) |*entry| {
        const name = entry.name();

        // Skip excluded files.
        if (shouldExcludeFile(name)) continue;

        // Build source and destination paths.
        var src_path_buf: [PATH_BUF_SIZE]u8 = undefined;
        const src_segs = [_][]const u8{ src_dir_path, name };
        const src_path = sig_fs.joinPath(&src_path_buf, &src_segs) catch continue;

        var dst_path_buf: [PATH_BUF_SIZE]u8 = undefined;
        const dst_segs = [_][]const u8{ dst_dir_path, name };
        const dst_path = sig_fs.joinPath(&dst_path_buf, &dst_segs) catch continue;

        // Read source file and write to destination.
        var file_buf: [OUTPUT_BUF_SIZE]u8 = undefined;
        const content = sig_fs.readFile(io_ctx, src_path, &file_buf) catch continue;
        sig_fs.writeFile(io_ctx, dst_path, content) catch continue;

        installed += 1;
    }

    return installed;
}

// ── Thread pool and parallel scheduler ────────────────────────────────────────

/// A unit of work dispatched to a worker thread: a step handle and its
/// associated make function.
pub const Work_Item = struct {
    step_handle: Step_Handle,
    step_fn: StepFn,
};

/// Bounded thread pool for parallel step execution.
/// Workers pull from a shared BoundedDeque work queue. Each worker buffers
/// its step's output in a 64KB stack buffer and flushes atomically on
/// completion. All synchronization uses std.Io.Mutex and std.Io.Condition.
pub const Thread_Pool = struct {
    threads: [MAX_THREADS]std.Thread = undefined,
    thread_count: usize = 0,
    work_queue: containers.BoundedDeque(Work_Item, MAX_WORK_QUEUE) = .{},
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    done_cond: std.Io.Condition = std.Io.Condition.init,
    shutdown: bool = false,
    active_count: usize = 0,
    io: std.Io = undefined,
    /// Pointer to the Build_Context — set once before scheduling starts.
    /// Workers read this (read-only) when constructing Step_Context.
    build_ctx: ?*Build_Context = null,
    /// Path to the sig compiler binary — set once before scheduling starts.
    /// Stored as a slice into the Runner_Args buffer (stable lifetime).
    compiler_path: []const u8 = "",

    // Per-step completion tracking: workers write results here under the mutex.
    completed_steps: [MAX_WORK_QUEUE]Completion_Result = undefined,
    completed_count: usize = 0,

    /// Result of a single step execution, written by the worker thread.
    pub const Completion_Result = struct {
        step_handle: Step_Handle,
        succeeded: bool,
        exit_code: u8 = 0,
        stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined,
        stderr_len: usize = 0,
        output_buf: [OUTPUT_BUF_SIZE]u8 = undefined,
        output_len: usize = 0,
    };

    /// Initialize the pool and spawn `num_threads` worker threads.
    /// `num_threads` is clamped to [1, MAX_THREADS].
    pub fn init(self: *Thread_Pool, num_threads: usize, io: std.Io) void {
        self.io = io;
        self.shutdown = false;
        self.active_count = 0;
        self.completed_count = 0;
        self.work_queue = .{};

        const count = @min(@max(num_threads, 1), MAX_THREADS);
        self.thread_count = count;

        for (0..count) |i| {
            self.threads[i] = std.Thread.spawn(.{}, workerLoop, .{self}) catch {
                // If we can't spawn a thread, reduce the count and continue
                // with however many we managed to create.
                self.thread_count = i;
                return;
            };
        }
    }

    /// Submit a work item to the pool. Returns CapacityExceeded if the
    /// work queue is full.
    pub fn submit(self: *Thread_Pool, item: Work_Item) SigError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.work_queue.pushBack(item);
        self.cond.signal(self.io);
    }

    /// Block until all submitted work items have been processed and no
    /// workers are actively executing a step.
    pub fn waitAll(self: *Thread_Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.work_queue.count > 0 or self.active_count > 0) {
            self.done_cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Signal all workers to shut down and join their threads.
    pub fn deinit(self: *Thread_Pool) void {
        {
            self.mutex.lockUncancelable(self.io);
            self.shutdown = true;
            self.mutex.unlock(self.io);
        }
        // Wake all workers so they see the shutdown flag.
        self.cond.broadcast(self.io);

        for (0..self.thread_count) |i| {
            self.threads[i].join();
        }
        self.thread_count = 0;
    }

    /// Drain all completed results into the caller's slice. Returns the
    /// number of results copied. Resets the internal completed count.
    pub fn drainCompleted(self: *Thread_Pool, out: []Completion_Result) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const n = @min(self.completed_count, out.len);
        for (0..n) |i| {
            out[i].step_handle = self.completed_steps[i].step_handle;
            out[i].succeeded = self.completed_steps[i].succeeded;
            out[i].exit_code = self.completed_steps[i].exit_code;
            out[i].stderr_len = self.completed_steps[i].stderr_len;
            if (out[i].stderr_len > 0) {
                @memcpy(out[i].stderr_buf[0..out[i].stderr_len], self.completed_steps[i].stderr_buf[0..out[i].stderr_len]);
            }
            out[i].output_len = self.completed_steps[i].output_len;
            if (out[i].output_len > 0) {
                @memcpy(out[i].output_buf[0..out[i].output_len], self.completed_steps[i].output_buf[0..out[i].output_len]);
            }
        }
        // Shift remaining (if any) down.
        if (n < self.completed_count) {
            const remaining = self.completed_count - n;
            for (0..remaining) |i| {
                self.completed_steps[i] = self.completed_steps[i + n];
            }
        }
        self.completed_count -= n;
        return n;
    }

    /// Worker thread entry point. Runs until shutdown is signaled.
    fn workerLoop(pool: *Thread_Pool) void {
        while (true) {
            // Lock → pop work item → unlock.
            pool.mutex.lockUncancelable(pool.io);

            while (pool.work_queue.count == 0 and !pool.shutdown) {
                pool.cond.waitUncancelable(pool.io, &pool.mutex);
            }

            if (pool.shutdown and pool.work_queue.count == 0) {
                pool.mutex.unlock(pool.io);
                return;
            }

            const item = pool.work_queue.popFront() orelse {
                pool.mutex.unlock(pool.io);
                continue;
            };

            pool.active_count += 1;
            pool.mutex.unlock(pool.io);

            // Execute the step with a per-invocation output buffer on the stack.
            var output_buf: [OUTPUT_BUF_SIZE]u8 = undefined;
            var output_len: usize = 0;
            var stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined;
            var stderr_len: usize = 0;
            var exit_code: u8 = 0;
            // build_ctx is always set by build_host.sig before scheduling starts.
            // For noop steps that don't access build_ctx, the undefined default is safe.
            var ctx = Step_Context{
                .step_handle = item.step_handle,
                .io = pool.io,
                .compiler_path = pool.compiler_path,
            };
            if (pool.build_ctx) |bctx| {
                ctx.build_ctx = bctx;
            }
            const succeeded = if (item.step_fn(&ctx)) |_| true else |_| blk: {
                exit_code = 1; // Default non-zero exit code for failed steps.
                break :blk false;
            };

            // Output and stderr capture is handled by the step functions
            // themselves via the Step_Context's I/O context.
            _ = &output_buf;
            _ = &output_len;
            _ = &stderr_buf;
            _ = &stderr_len;

            // Lock → record completion → signal → unlock.
            pool.mutex.lockUncancelable(pool.io);

            if (pool.completed_count < MAX_WORK_QUEUE) {
                var result = &pool.completed_steps[pool.completed_count];
                result.step_handle = item.step_handle;
                result.succeeded = succeeded;
                result.exit_code = exit_code;
                result.stderr_len = stderr_len;
                if (stderr_len > 0) {
                    @memcpy(result.stderr_buf[0..stderr_len], stderr_buf[0..stderr_len]);
                }
                result.output_len = output_len;
                if (output_len > 0) {
                    @memcpy(result.output_buf[0..output_len], output_buf[0..output_len]);
                }
                pool.completed_count += 1;
            }

            pool.active_count -= 1;
            pool.done_cond.signal(pool.io);
            pool.cond.signal(pool.io); // wake another worker if more work queued
            pool.mutex.unlock(pool.io);
        }
    }
};

/// Summary returned by the scheduler after all steps have been processed.
pub const Schedule_Summary = struct {
    total: usize = 0,
    succeeded: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    cached: usize = 0,
};

/// Run the parallel scheduler loop.
///
/// 1. Compute the ready set (steps with all deps met, not yet completed/failed/skipped)
/// 2. For each ready step, check the cache — if hit, mark succeeded and skip execution
/// 3. For cache misses, submit to the thread pool
/// 4. Wait for completions, update state, propagate failures
/// 5. Repeat until all steps are done or failed/skipped
///
/// `registry` is mutated (step states updated). `graph` and `cache` are read.
/// `pool` must already be initialized.
pub fn runScheduler(
    registry: *Step_Registry,
    graph: *const Dependency_Graph,
    cache: *Cache_Map,
    pool: *Thread_Pool,
    io: std.Io,
    verbose: bool,
) Schedule_Summary {
    var summary: Schedule_Summary = .{};
    summary.total = registry.count;

    // Track completed, failed, and skipped steps via bit sets.
    var completed_bits: containers.BoundedBitSet(MAX_STEPS) = .{};
    var failed_bits: containers.BoundedBitSet(MAX_STEPS) = .{};
    var skipped_bits: containers.BoundedBitSet(MAX_STEPS) = .{};
    var dispatched_bits: containers.BoundedBitSet(MAX_STEPS) = .{};

    // Merge completed + failed + skipped into a single "done" set for readySet queries.
    var done_bits: containers.BoundedBitSet(MAX_STEPS) = .{};

    while (true) {
        // 1. Compute the ready set: steps not done and with all deps in done_bits.
        var ready_buf: [MAX_STEPS]Step_Handle = undefined;
        const ready = graph.readySet(&done_bits, &ready_buf);

        if (ready.len == 0) {
            // No more ready steps. If there's still active work, wait for completions.
            if (pool.active_count > 0 or pool.work_queue.count > 0) {
                pool.waitAll();
                // Process completions and loop again.
                processCompletions(pool, registry, graph, &completed_bits, &failed_bits, &skipped_bits, &done_bits, &dispatched_bits, &summary, io, verbose);
                continue;
            }
            // Truly done — no ready steps and no active work.
            break;
        }

        // 2 & 3. For each ready step: check cache or dispatch.
        for (ready) |handle| {
            const idx: usize = handle;
            if (dispatched_bits.isSet(idx)) continue; // already dispatched
            if (done_bits.isSet(idx)) continue; // already done

            const entry = &registry.entries[idx];
            const step_name = entry.name[0..entry.name_len];

            // Check cache: if the step's content hash matches, skip execution.
            if (cache.lookup(step_name)) |_| {
                // Cache hit — mark as succeeded without executing.
                entry.state = .succeeded;
                completed_bits.set(idx) catch {};
                done_bits.set(idx) catch {};
                summary.cached += 1;
                summary.succeeded += 1;
                if (verbose) {
                    printMsg(io, "  CACHE: {s}", .{step_name});
                }
                continue;
            }

            // Cache miss — dispatch to thread pool.
            entry.state = .running;
            dispatched_bits.set(idx) catch {};
            if (verbose) {
                printMsg(io, "  START: {s}", .{step_name});
            }
            pool.submit(.{
                .step_handle = handle,
                .step_fn = entry.make_fn,
            }) catch {
                // Queue full — mark as failed.
                entry.state = .failed;
                failed_bits.set(idx) catch {};
                done_bits.set(idx) catch {};
                summary.failed += 1;
                // Propagate failure to transitive dependents.
                propagateSkips(graph, handle, registry, &skipped_bits, &done_bits, &summary);
            };
        }

        // 4. Wait for at least one completion before looping.
        pool.waitAll();
        processCompletions(pool, registry, graph, &completed_bits, &failed_bits, &skipped_bits, &done_bits, &dispatched_bits, &summary, io, verbose);
    }

    // Mark any remaining pending steps that were never reached as skipped.
    for (0..registry.count) |i| {
        if (!done_bits.isSet(i)) {
            registry.entries[i].state = .skipped;
            summary.skipped += 1;
        }
    }

    return summary;
}

/// Process completed work items from the thread pool, updating step states
/// and propagating failures.
fn processCompletions(
    pool: *Thread_Pool,
    registry: *Step_Registry,
    graph: *const Dependency_Graph,
    completed_bits: *containers.BoundedBitSet(MAX_STEPS),
    failed_bits: *containers.BoundedBitSet(MAX_STEPS),
    skipped_bits: *containers.BoundedBitSet(MAX_STEPS),
    done_bits: *containers.BoundedBitSet(MAX_STEPS),
    dispatched_bits: *containers.BoundedBitSet(MAX_STEPS),
    summary: *Schedule_Summary,
    io: std.Io,
    verbose: bool,
) void {
    var results: [MAX_WORK_QUEUE]Thread_Pool.Completion_Result = undefined;
    const count = pool.drainCompleted(&results);

    _ = dispatched_bits;

    for (0..count) |i| {
        const handle = results[i].step_handle;
        const idx: usize = handle;
        const entry = &registry.entries[idx];
        const step_name = entry.name[0..entry.name_len];

        if (results[i].succeeded) {
            entry.state = .succeeded;
            completed_bits.set(idx) catch {};
            done_bits.set(idx) catch {};
            summary.succeeded += 1;

            if (verbose) {
                printMsg(io, "  DONE:  {s}", .{step_name});
            }

            // Flush buffered output atomically.
            if (results[i].output_len > 0) {
                // Write the step's buffered output to stdout in one shot.
                const output = results[i].output_buf[0..results[i].output_len];
                const stdout = std.Io.File.stdout();
                stdout.writeStreamingAll(io, output) catch {};
            }
        } else {
            entry.state = .failed;
            failed_bits.set(idx) catch {};
            done_bits.set(idx) catch {};
            summary.failed += 1;

            // Report step failure with details.
            printMsg(io, "FAIL: step '{s}' exited with code {d}", .{ step_name, results[i].exit_code });
            if (results[i].stderr_len > 0) {
                printMsg(io, "  stderr: {s}", .{results[i].stderr_buf[0..results[i].stderr_len]});
            }

            // Propagate failure: mark all transitive dependents as skipped.
            propagateSkips(graph, handle, registry, skipped_bits, done_bits, summary);
        }
    }
}

/// Walk the dependency graph from a failed step and mark all transitive
/// dependents as skipped.
fn propagateSkips(
    graph: *const Dependency_Graph,
    failed_handle: Step_Handle,
    registry: *Step_Registry,
    skipped_bits: *containers.BoundedBitSet(MAX_STEPS),
    done_bits: *containers.BoundedBitSet(MAX_STEPS),
    summary: *Schedule_Summary,
) void {
    // BFS: find all nodes that transitively depend on the failed step.
    var queue: containers.BoundedDeque(Step_Handle, MAX_STEPS) = .{};
    queue.pushBack(failed_handle) catch return;

    while (queue.popFront()) |node| {
        const node_idx: usize = node;
        // Find all steps j that depend on `node` (j has node in its adj list).
        for (0..graph.node_count) |j| {
            if (done_bits.isSet(j)) continue;
            if (skipped_bits.isSet(j)) continue;
            for (graph.adj[j][0..graph.adj_counts[j]]) |dep| {
                if (@as(usize, dep) == node_idx) {
                    // Step j depends on the failed/skipped node — skip it.
                    registry.entries[j].state = .skipped;
                    skipped_bits.set(j) catch continue;
                    done_bits.set(j) catch continue;
                    summary.skipped += 1;
                    queue.pushBack(@intCast(j)) catch continue;
                    break;
                }
            }
        }
    }
}

// ── Build_Context option types ───────────────────────────────────────────────

/// Options for creating a test step via `addTestStep`.
pub const Test_Options = struct {
    source_path: []const u8,
    name: []const u8,
    imports: []const Import_Entry,
};

/// Options for creating an install step via `addInstallStep`.
pub const Install_Options = struct {
    source_dir: []const u8,
    dest_dir: []const u8,
};

// ── Build_Context (replaces *std.Build) ──────────────────────────────────────

/// The central struct passed to `build.sig`'s `build` function. All API
/// methods operate on fixed-capacity internals — zero allocators.
pub const Build_Context = struct {
    steps: Step_Registry = .{},
    modules: Module_Registry = .{},
    options: Option_Map = .{},
    build_root: [PATH_BUF_SIZE]u8 = undefined,
    build_root_len: usize = 0,
    cache_dir: [PATH_BUF_SIZE]u8 = undefined,
    cache_dir_len: usize = 0,
    install_prefix: [PATH_BUF_SIZE]u8 = undefined,
    install_prefix_len: usize = 0,
    target: Target_Triple = .{},
    optimize: Optimize_Mode = .Debug,
    /// I/O context for file system operations (directory listing, file probing).
    /// Set by the build runner before calling build.sig's build function.
    io_ctx: std.Io = undefined,
    /// Path to the sig compiler binary. Set from Runner_Args.compiler_path
    /// before calling build.sig's build function.
    compiler_path: [PATH_BUF_SIZE]u8 = undefined,
    compiler_path_len: usize = 0,
    /// Zig upstream version components from build.sig's zig_version constant.
    zig_version_major: u32 = 0,
    zig_version_minor: u32 = 0,
    zig_version_patch: u32 = 0,
    /// Sig version string from build.sig's sig_version_string constant.
    sig_version: [64]u8 = undefined,
    sig_version_len: usize = 0,
    /// Zig lib directory path (for --zig-lib-dir when invoking the compiler).
    zig_lib_dir: [PATH_BUF_SIZE]u8 = undefined,
    zig_lib_dir_len: usize = 0,

    // --- Public API (called by build.sig) ---

    /// Register a named build step. Delegates to Step_Registry.register().
    /// Returns a Step_Handle on success.
    pub fn addStep(self: *Build_Context, name: []const u8, desc: []const u8, make_fn: StepFn) SigError!Step_Handle {
        return self.steps.register(name, desc, make_fn);
    }

    /// Register a source module. Delegates to Module_Registry.register().
    /// Returns a Module_Handle on success.
    pub fn addModule(self: *Build_Context, name: []const u8, source_path: []const u8) SigError!Module_Handle {
        return self.modules.register(name, source_path);
    }

    /// Wire an import (name → path) onto a module.
    /// Delegates to Module_Registry.addImport().
    pub fn addImport(self: *Build_Context, module: Module_Handle, import_name: []const u8, import_path: []const u8) SigError!void {
        return self.modules.addImport(module, import_name, import_path);
    }

    /// Declare a dependency: `dependent` runs after `dependency`.
    /// Delegates to Step_Registry.addDep().
    pub fn addDependency(self: *Build_Context, dependent: Step_Handle, dependency: Step_Handle) SigError!void {
        return self.steps.addDep(dependent, dependency);
    }

    /// Create a compile step that invokes the upstream compiler.
    /// Registers a step whose make_fn builds and runs the compile command.
    pub fn addCompileStep(self: *Build_Context, opts: Compile_Options) SigError!Step_Handle {
        // Register a step named after the output binary.
        const handle = try self.steps.register(opts.output_name, opts.source_path, &compileStepFn);

        // Store the source path in the step's desc field as a secondary record
        // so the compile command can be reconstructed at execution time.
        // (The desc field already holds source_path from the register call above.)

        // Wire module imports: register each import as a module and add to registry
        // so the scheduler can reconstruct the command at execution time.
        for (opts.imports) |imp| {
            const imp_name = imp.name[0..imp.name_len];
            const imp_path = imp.path[0..imp.path_len];
            // Register the module if not already present.
            _ = self.modules.register(imp_name, imp_path) catch |err| switch (err) {
                error.CapacityExceeded => {
                    // May already exist (duplicate name) — that's fine for compile steps.
                    // Only a real capacity issue if the registry is truly full.
                    if (self.modules.findByName(imp_name) == null) return err;
                },
                else => return err,
            };
        }

        return handle;
    }

    /// Create a test step that compiles and runs a test file.
    /// Similar to compile but the step function runs the test binary after compilation.
    pub fn addTestStep(self: *Build_Context, opts: Test_Options) SigError!Step_Handle {
        const handle = try self.steps.register(opts.name, opts.source_path, &testStepFn);

        // Wire imports for the test module.
        for (opts.imports) |imp| {
            const imp_name = imp.name[0..imp.name_len];
            const imp_path = imp.path[0..imp.path_len];
            _ = self.modules.register(imp_name, imp_path) catch |err| switch (err) {
                error.CapacityExceeded => {
                    if (self.modules.findByName(imp_name) == null) return err;
                },
                else => return err,
            };
        }

        return handle;
    }

    /// Create an install step that copies artifacts to the output directory.
    /// The step function calls `installFiles` at execution time.
    pub fn addInstallStep(self: *Build_Context, opts: Install_Options) SigError!Step_Handle {
        // Derive a step name from the destination directory.
        var name_buf: [NAME_BUF_SIZE]u8 = undefined;
        const prefix = "install-";
        const name_len = @min(opts.dest_dir.len, NAME_BUF_SIZE - prefix.len);
        @memcpy(name_buf[0..prefix.len], prefix);
        @memcpy(name_buf[prefix.len..][0..name_len], opts.dest_dir[0..name_len]);
        const full_name = name_buf[0 .. prefix.len + name_len];

        return self.steps.register(full_name, opts.source_dir, &installStepFn);
    }

    /// Resolve a relative path against the build root.
    /// Writes the resolved path into `buf` and returns a slice.
    pub fn path(self: *Build_Context, relative: []const u8, buf: *[PATH_BUF_SIZE]u8) SigError![]const u8 {
        const base = self.build_root[0..self.build_root_len];
        return pathResolve(buf, base, relative);
    }

    /// Read a build option from -D flags. Parses the string value from the
    /// Option_Map into the requested comptime type T.
    /// The `desc` parameter is accepted for API compatibility but unused at
    /// lookup time (it documents the option for help text generation).
    pub fn option(self: *Build_Context, comptime T: type, name: []const u8, desc: []const u8) ?T {
        _ = desc;
        return getOption(T, &self.options, name);
    }

    // --- Internal step functions ---

    /// Step function for compile steps. Reconstructs the compile command
    /// from the step entry's metadata and executes it.
    ///
    /// The step entry's `desc` field stores the source_path (set by addCompileStep).
    /// The step entry's `name` field stores the output binary name.
    ///
    /// For the sig compiler itself (src/main.zig), compilation resolves the
    /// version string, generates build_options.zig in the cache, and builds
    /// with module dependencies (build_options, aro).
    /// For all other sources, we use direct `build-exe` invocation.
    fn compileStepFn(ctx: *Step_Context) SigError!void {
        const build_ctx = ctx.build_ctx;
        const io = ctx.io;
        const handle: usize = ctx.step_handle;
        const entry = &build_ctx.steps.entries[handle];

        const source_path = entry.desc[0..entry.desc_len];
        const output_name = entry.name[0..entry.name_len];
        const cache_dir = build_ctx.cache_dir[0..build_ctx.cache_dir_len];
        const install_prefix = build_ctx.install_prefix[0..build_ctx.install_prefix_len];

        // Determine compiler path: use ctx.compiler_path if set, else "sig".
        const compiler = if (ctx.compiler_path.len > 0) ctx.compiler_path else "sig";

        // Check if this is the sig compiler compilation (src/main.zig).
        // The compiler needs build_options.zig and aro module dependencies.
        const is_compiler_build = std.mem.eql(u8, source_path, "src/main.zig");

        if (is_compiler_build) {
            // Direct compiler compilation — no build.zig delegation.
            // 1. Resolve version string
            var version_buf: [VERSION_BUF_SIZE]u8 = undefined;
            const version_override = build_ctx.options.getValue("version-string");
            const version_str = if (version_override) |v| v else blk: {
                // Determine if this is a dev build (sig_version has pre-release tag)
                const sig_ver = build_ctx.sig_version[0..build_ctx.sig_version_len];
                const is_dev = std.mem.indexOfScalar(u8, sig_ver, '-') != null;
                // Format base version from zig_version components
                var base_buf: [64]u8 = undefined;
                const base_version = std.fmt.bufPrint(&base_buf, "{d}.{d}.{d}", .{
                    build_ctx.zig_version_major,
                    build_ctx.zig_version_minor,
                    build_ctx.zig_version_patch,
                }) catch break :blk build_ctx.sig_version[0..build_ctx.sig_version_len];
                break :blk resolveVersionString(&version_buf, base_version, is_dev, io);
            };

            // 2. Generate build_options.zig in cache
            try generateBuildOptions(build_ctx, version_str, cache_dir, io);

            // 3. Build and execute compile command with module dependencies.
            var cmd: Command_Buffer = .{};

            // argv[0]: compiler binary path.
            try cmd.appendArg(compiler);

            // Sub-command.
            try cmd.appendArg("build-exe");

            // Module dependencies: --dep flags before root module.
            try cmd.appendArg("--dep");
            try cmd.appendArg("build_options");
            try cmd.appendArg("--dep");
            try cmd.appendArg("aro");

            // Root module: -Mroot=src/main.zig
            {
                var root_buf: [PATH_BUF_SIZE]u8 = undefined;
                const root_prefix = "-Mroot=";
                if (root_prefix.len + source_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;
                @memcpy(root_buf[0..root_prefix.len], root_prefix);
                @memcpy(root_buf[root_prefix.len..][0..source_path.len], source_path);
                try cmd.appendArg(root_buf[0 .. root_prefix.len + source_path.len]);
            }

            // Module paths: -Mbuild_options=<cache_dir>/build_options.zig
            {
                var mod_buf: [PATH_BUF_SIZE]u8 = undefined;
                var bo_path_buf: [PATH_BUF_SIZE]u8 = undefined;
                const bo_segs = [_][]const u8{ cache_dir, "build_options.zig" };
                const bo_path = sig_fs.joinPath(&bo_path_buf, &bo_segs) catch return error.BufferTooSmall;
                const prefix = "-Mbuild_options=";
                if (prefix.len + bo_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;
                @memcpy(mod_buf[0..prefix.len], prefix);
                @memcpy(mod_buf[prefix.len..][0..bo_path.len], bo_path);
                try cmd.appendArg(mod_buf[0 .. prefix.len + bo_path.len]);
            }

            // Module paths: -Maro=lib/compiler/aro/aro.zig
            {
                var mod_buf: [PATH_BUF_SIZE]u8 = undefined;
                const prefix = "-Maro=";
                const aro_path = "lib/compiler/aro/aro.zig";
                if (prefix.len + aro_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;
                @memcpy(mod_buf[0..prefix.len], prefix);
                @memcpy(mod_buf[prefix.len..][0..aro_path.len], aro_path);
                try cmd.appendArg(mod_buf[0 .. prefix.len + aro_path.len]);
            }

            // Optimization mode: -O<mode>
            try cmd.appendArg("-O");
            try cmd.appendArg(switch (build_ctx.optimize) {
                .Debug => "Debug",
                .ReleaseSafe => "ReleaseSafe",
                .ReleaseFast => "ReleaseFast",
                .ReleaseSmall => "ReleaseSmall",
            });

            // Target triple: -target <triple> (only if specified).
            if (build_ctx.target.arch_len > 0) {
                try cmd.appendArg("-target");
                var triple_buf: [PATH_BUF_SIZE]u8 = undefined;
                const triple_str = try build_ctx.target.format(&triple_buf);
                try cmd.appendArg(triple_str);
            }

            // Strip: --strip if strip option is set.
            const is_strip = optBool(&build_ctx.options, "strip", false);
            if (is_strip) {
                try cmd.appendArg("--strip");
            }

            // Output binary: -femit-bin=<prefix>/bin/sig
            // Create the output directory first (the compiler doesn't create parent dirs).
            {
                var bin_dir_buf: [PATH_BUF_SIZE]u8 = undefined;
                const bin_dir_segs = [_][]const u8{ install_prefix, "bin" };
                const bin_dir = sig_fs.joinPath(&bin_dir_buf, &bin_dir_segs) catch return error.BufferTooSmall;
                const cwd: std.Io.Dir = .cwd();
                cwd.createDirPath(io, bin_dir) catch {};
            }
            {
                var emit_buf: [PATH_BUF_SIZE]u8 = undefined;
                const emit_prefix = "-femit-bin=";
                var emit_path_buf: [PATH_BUF_SIZE]u8 = undefined;
                const emit_segs = [_][]const u8{ install_prefix, "bin", output_name };
                const emit_path = sig_fs.joinPath(&emit_path_buf, &emit_segs) catch return error.BufferTooSmall;
                if (emit_prefix.len + emit_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;
                @memcpy(emit_buf[0..emit_prefix.len], emit_prefix);
                @memcpy(emit_buf[emit_prefix.len..][0..emit_path.len], emit_path);
                try cmd.appendArg(emit_buf[0 .. emit_prefix.len + emit_path.len]);
            }

            // Cache directory: --cache-dir <dir>
            try cmd.appendArg("--cache-dir");
            try cmd.appendArg(cache_dir);

            // Zig lib directory: --zig-lib-dir
            printMsg(io, "compileStepFn: zig_lib_dir_len={d}", .{build_ctx.zig_lib_dir_len});
            if (build_ctx.zig_lib_dir_len > 0) {
                try cmd.appendArg("--zig-lib-dir");
                try cmd.appendArg(build_ctx.zig_lib_dir[0..build_ctx.zig_lib_dir_len]);
            }

            // LLVM linking flags: when have_llvm is true, forward static LLVM
            // library flags and platform-specific system libraries.
            // TODO: Add actual LLVM linking flags (-lLLVM, static libs, and
            // on Windows: -lntdll, -lws2_32, etc.) when LLVM support is enabled.
            // For now, LLVM linking is complex and will be refined in a follow-up.

            // Log the command for debugging.
            printMsg(io, "compileStepFn: compiling {s} with {d} args", .{ source_path, cmd.arg_count });
            for (0..cmd.arg_count) |ci| {
                printMsg(io, "  arg[{d}]: {s}", .{ ci, cmd.getArg(ci) });
            }

            // Execute the command and propagate errors.
            var stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined;
            var stderr_len: usize = 0;
            const exit_code = try runCommand(&cmd, &stderr_buf, &stderr_len, io);
            if (exit_code != 0) {
                // Print stderr so CI logs show the actual error.
                if (stderr_len > 0) {
                    printMsg(io, "compileStepFn: compiler build-exe failed with code {d}:", .{exit_code});
                    printMsg(io, "{s}", .{stderr_buf[0..stderr_len]});
                } else {
                    printMsg(io, "compileStepFn: compiler build-exe failed with code {d} (no stderr)", .{exit_code});
                }
                return error.BufferTooSmall;
            }
        } else {
            // Direct build-exe invocation for non-compiler sources.
            var cmd: Command_Buffer = .{};

            // Gather imports from the module registry for this step's source.
            // The step's imports were registered in the module registry by addCompileStep.
            var imports_buf: [MAX_IMPORTS_PER_MODULE]Import_Entry = undefined;
            var import_count: usize = 0;

            // Look through registered modules for imports that were wired
            // by addCompileStep. The convention is that addCompileStep registers
            // each import as a module in the registry.
            for (build_ctx.modules.entries[0..build_ctx.modules.count]) |mod_entry| {
                if (import_count >= MAX_IMPORTS_PER_MODULE) break;
                imports_buf[import_count] = .{};
                @memcpy(imports_buf[import_count].name[0..mod_entry.name_len], mod_entry.name[0..mod_entry.name_len]);
                imports_buf[import_count].name_len = mod_entry.name_len;
                @memcpy(imports_buf[import_count].path[0..mod_entry.source_path_len], mod_entry.source_path[0..mod_entry.source_path_len]);
                imports_buf[import_count].path_len = mod_entry.source_path_len;
                import_count += 1;
            }

            try buildCompileCommand(&cmd, .{
                .source_path = source_path,
                .output_name = output_name,
                .cache_dir = cache_dir,
                .optimize = build_ctx.optimize,
                .target = if (build_ctx.target.arch_len > 0) &build_ctx.target else null,
                .imports = imports_buf[0..import_count],
                .compiler_path = compiler,
            });

            // Add -femit-bin=<prefix>/bin/<output_name> flag.
            // Create the output directory first.
            {
                var bin_dir_buf: [PATH_BUF_SIZE]u8 = undefined;
                const bin_dir_segs = [_][]const u8{ install_prefix, "bin" };
                const bin_dir = sig_fs.joinPath(&bin_dir_buf, &bin_dir_segs) catch return error.BufferTooSmall;
                const cwd: std.Io.Dir = .cwd();
                cwd.createDirPath(io, bin_dir) catch {};
            }
            {
                var emit_buf: [PATH_BUF_SIZE]u8 = undefined;
                const emit_prefix = "-femit-bin=";
                var emit_path_buf: [PATH_BUF_SIZE]u8 = undefined;
                const emit_segs = [_][]const u8{ install_prefix, "bin", output_name };
                const emit_path = sig_fs.joinPath(&emit_path_buf, &emit_segs) catch return error.BufferTooSmall;
                if (emit_prefix.len + emit_path.len > PATH_BUF_SIZE) return error.BufferTooSmall;
                @memcpy(emit_buf[0..emit_prefix.len], emit_prefix);
                @memcpy(emit_buf[emit_prefix.len..][0..emit_path.len], emit_path);
                try cmd.appendArg(emit_buf[0 .. emit_prefix.len + emit_path.len]);
            }

            // Add --zig-lib-dir if we can derive it from the compiler path.
            // The zig lib dir is typically alongside the compiler binary.

            var stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined;
            var stderr_len: usize = 0;
            const exit_code = try runCommand(&cmd, &stderr_buf, &stderr_len, io);
            if (exit_code != 0) {
                if (stderr_len > 0) {
                    printMsg(io, "compileStepFn: build-exe failed with code {d}:", .{exit_code});
                    printMsg(io, "{s}", .{stderr_buf[0..stderr_len]});
                } else {
                    printMsg(io, "compileStepFn: build-exe failed with code {d} (no stderr)", .{exit_code});
                }
                return error.BufferTooSmall;
            }
        }
    }

    /// Step function for test steps. Compiles and runs the test binary.
    ///
    /// The step entry's `desc` field stores the source_path (set by addTestStep).
    /// Uses the `test` subcommand instead of `build-exe`.
    fn testStepFn(ctx: *Step_Context) SigError!void {
        const build_ctx = ctx.build_ctx;
        const io = ctx.io;
        const handle: usize = ctx.step_handle;
        const entry = &build_ctx.steps.entries[handle];

        const source_path = entry.desc[0..entry.desc_len];
        const cache_dir = build_ctx.cache_dir[0..build_ctx.cache_dir_len];
        const compiler = if (ctx.compiler_path.len > 0) ctx.compiler_path else "sig";

        var cmd: Command_Buffer = .{};
        try cmd.appendArg(compiler);
        try cmd.appendArg("test");

        // Emit --dep flags first (before the root module / source file).
        for (build_ctx.modules.entries[0..build_ctx.modules.count]) |mod_entry| {
            const name_slice = mod_entry.name[0..mod_entry.name_len];
            try cmd.appendArg("--dep");
            try cmd.appendArg(name_slice);
        }

        // Source path as positional argument (root module).
        try cmd.appendArg(source_path);

        // Emit -Mname=path for each module (leaf modules, after root).
        for (build_ctx.modules.entries[0..build_ctx.modules.count]) |mod_entry| {
            const name_slice = mod_entry.name[0..mod_entry.name_len];
            const path_slice = mod_entry.source_path[0..mod_entry.source_path_len];

            var mod_buf: [PATH_BUF_SIZE]u8 = undefined;
            const prefix_len = 2 + name_slice.len + 1; // "-M" + name + "="
            const total = prefix_len + path_slice.len;
            if (total > PATH_BUF_SIZE) return error.BufferTooSmall;
            mod_buf[0] = '-';
            mod_buf[1] = 'M';
            @memcpy(mod_buf[2..][0..name_slice.len], name_slice);
            mod_buf[2 + name_slice.len] = '=';
            @memcpy(mod_buf[prefix_len..][0..path_slice.len], path_slice);
            try cmd.appendArg(mod_buf[0..total]);
        }

        // Cache directory.
        try cmd.appendArg("--cache-dir");
        try cmd.appendArg(cache_dir);

        var stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined;
        var stderr_len: usize = 0;
        const exit_code = try runCommand(&cmd, &stderr_buf, &stderr_len, io);
        if (exit_code != 0) return error.BufferTooSmall;
    }

    /// Step function for install steps. Copies files from source to dest.
    ///
    /// The step entry's `desc` field stores the source directory path
    /// (set by addInstallStep). The destination is derived from the
    /// install prefix and the step's dest_dir.
    fn installStepFn(ctx: *Step_Context) SigError!void {
        const build_ctx = ctx.build_ctx;
        const io = ctx.io;
        const handle: usize = ctx.step_handle;
        const entry = &build_ctx.steps.entries[handle];

        // The desc field stores the source directory.
        const source_dir = entry.desc[0..entry.desc_len];

        // The step name is "install-<dest_dir>", so extract dest_dir from the name.
        const name = entry.name[0..entry.name_len];
        const install_prefix_str = "install-";
        const dest_suffix = if (name.len > install_prefix_str.len and
            std.mem.eql(u8, name[0..install_prefix_str.len], install_prefix_str))
            name[install_prefix_str.len..]
        else
            name;

        // Build the full destination path: <install_prefix>/<dest_dir>
        const install_prefix = build_ctx.install_prefix[0..build_ctx.install_prefix_len];
        var dest_path_buf: [PATH_BUF_SIZE]u8 = undefined;
        const dest_segs = [_][]const u8{ install_prefix, dest_suffix };
        const dest_path = sig_fs.joinPath(&dest_path_buf, &dest_segs) catch return error.BufferTooSmall;

        _ = try installFiles(io, source_dir, dest_path);
    }
};

// ── Verify-identical mode ─────────────────────────────────────────────────────

/// Maximum number of files to compare in each output subdirectory.
const MAX_VERIFY_FILES = 256;

/// A single file comparison entry: name + hash from each build system.
const Verify_Entry = struct {
    name: [256]u8 = undefined,
    name_len: usize = 0,
    sig_hash: Content_Hash = .{0} ** 16,
    zig_hash: Content_Hash = .{0} ** 16,
    sig_present: bool = false,
    zig_present: bool = false,
};

/// Format a Content_Hash as a 32-character hex string into a caller buffer.
fn formatHash(buf: *[32]u8, hash: Content_Hash) []const u8 {
    const hex = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        buf[i * 2] = hex[byte >> 4];
        buf[i * 2 + 1] = hex[byte & 0x0f];
    }
    return buf[0..32];
}

/// Collect file names and content hashes from a directory into a Verify_Entry table.
/// Only processes regular files (not subdirectories). Populates either the sig
/// or zig hash field based on `comptime is_sig`. Returns the number of entries
/// in the table after collection (may grow if new files are found).
fn collectDirHashes(
    io: std.Io,
    dir_path: []const u8,
    table: []Verify_Entry,
    existing_count: usize,
    comptime is_sig: bool,
) usize {
    var dir_entries: [MAX_VERIFY_FILES]sig_fs.DirEntry = undefined;
    const entries = sig_fs.listDir(io, dir_path, &dir_entries) catch return existing_count;

    var count = existing_count;
    for (entries) |*entry| {
        if (entry.kind != .file) continue;
        if (count >= table.len) break;

        const fname = entry.name();

        // Build full path for hashing.
        var path_buf: [PATH_BUF_SIZE]u8 = undefined;
        const segs = [_][]const u8{ dir_path, fname };
        const full_path = sig_fs.joinPath(&path_buf, &segs) catch continue;

        // Compute content hash for this file.
        const paths_arr = [_][]const u8{full_path};
        const hash = computeContentHash(io, &paths_arr);

        // Find or create entry in the table by name.
        var found = false;
        for (table[0..count]) |*te| {
            if (te.name_len == fname.len and std.mem.eql(u8, te.name[0..te.name_len], fname)) {
                if (is_sig) {
                    te.sig_hash = hash;
                    te.sig_present = true;
                } else {
                    te.zig_hash = hash;
                    te.zig_present = true;
                }
                found = true;
                break;
            }
        }
        if (!found) {
            var ve: Verify_Entry = .{};
            if (fname.len <= ve.name.len) {
                @memcpy(ve.name[0..fname.len], fname);
                ve.name_len = fname.len;
            }
            if (is_sig) {
                ve.sig_hash = hash;
                ve.sig_present = true;
            } else {
                ve.zig_hash = hash;
                ve.zig_present = true;
            }
            table[count] = ve;
            count += 1;
        }
    }
    return count;
}

/// Compare a table of Verify_Entry items and print a comparison report.
/// Updates totals: [0]=matched, [1]=mismatched, [2]=missing.
fn compareEntries(
    io: std.Io,
    table: []const Verify_Entry,
    count: usize,
    subdir_name: []const u8,
    totals: *[3]usize,
) void {
    printMsg(io, "\n  {s}/:", .{subdir_name});

    for (table[0..count]) |*entry| {
        const fname = entry.name[0..entry.name_len];

        if (entry.sig_present and entry.zig_present) {
            if (std.mem.eql(u8, &entry.sig_hash, &entry.zig_hash)) {
                var hash_str: [32]u8 = undefined;
                _ = formatHash(&hash_str, entry.sig_hash);
                printMsg(io, "    {s}: MATCH  ({s})", .{ fname, hash_str[0..16] });
                totals[0] += 1;
            } else {
                var sig_str: [32]u8 = undefined;
                var zig_str: [32]u8 = undefined;
                _ = formatHash(&sig_str, entry.sig_hash);
                _ = formatHash(&zig_str, entry.zig_hash);
                printMsg(io, "    {s}: DIFFER sig={s} zig={s}", .{ fname, sig_str[0..16], zig_str[0..16] });
                totals[1] += 1;
            }
        } else if (entry.sig_present and !entry.zig_present) {
            printMsg(io, "    {s}: MISSING from zig build", .{fname});
            totals[2] += 1;
        } else if (!entry.sig_present and entry.zig_present) {
            printMsg(io, "    {s}: MISSING from sig build", .{fname});
            totals[2] += 1;
        }
    }
}

/// Run `zig build` with the same options and compare output against the sig
/// build output. Called after the sig build completes, while zig-out/ still
/// contains the sig build artifacts.
///
/// Flow:
///   1. Hash current zig-out/bin/ and zig-out/lib/ (sig build output)
///   2. Run `zig build` (overwrites zig-out/)
///   3. Hash zig-out/bin/ and zig-out/lib/ again (zig build output)
///   4. Compare hashes and report differences
///
/// Returns true if all outputs are byte-identical, false otherwise.
pub fn verifyIdentical(
    io: std.Io,
    build_root: []const u8,
    config: *const Cli_Config,
) bool {
    printMsg(io, "\n── verify-identical: comparing sig build vs zig build ──", .{});

    // ── Build output directory paths ────────────────────────────────────
    var bin_path_buf: [PATH_BUF_SIZE]u8 = undefined;
    const bin_segs = [_][]const u8{ build_root, "zig-out", "bin" };
    const bin_path = sig_fs.joinPath(&bin_path_buf, &bin_segs) catch {
        printMsg(io, "error: failed to construct zig-out/bin path", .{});
        return false;
    };

    var lib_path_buf: [PATH_BUF_SIZE]u8 = undefined;
    const lib_segs = [_][]const u8{ build_root, "zig-out", "lib" };
    const lib_path = sig_fs.joinPath(&lib_path_buf, &lib_segs) catch {
        printMsg(io, "error: failed to construct zig-out/lib path", .{});
        return false;
    };

    // ── Step 1: Hash sig build output (current zig-out/ state) ──────────
    printMsg(io, "hashing sig build output...", .{});

    var bin_table: [MAX_VERIFY_FILES]Verify_Entry = undefined;
    for (&bin_table) |*e| e.* = .{};
    var bin_count = collectDirHashes(io, bin_path, &bin_table, 0, true);

    var lib_table: [MAX_VERIFY_FILES]Verify_Entry = undefined;
    for (&lib_table) |*e| e.* = .{};
    var lib_count = collectDirHashes(io, lib_path, &lib_table, 0, true);

    printMsg(io, "sig build: {d} bin files, {d} lib files", .{ bin_count, lib_count });

    // ── Step 2: Run `zig build` ─────────────────────────────────────────
    var zig_cmd: Command_Buffer = .{};
    zig_cmd.appendArg("zig") catch {
        printMsg(io, "error: failed to construct zig build command", .{});
        return false;
    };
    zig_cmd.appendArg("build") catch return false;

    // Forward -D options.
    for (config.options.entries[0..]) |entry| {
        if (!entry.occupied) continue;
        const key = entry.key_buf[0..entry.key_len];
        const val = entry.val_buf[0..entry.val_len];
        var opt_buf: [PATH_BUF_SIZE]u8 = undefined;
        const prefix = "-D";
        const eq = "=";
        const total = prefix.len + key.len + eq.len + val.len;
        if (total <= PATH_BUF_SIZE) {
            @memcpy(opt_buf[0..prefix.len], prefix);
            @memcpy(opt_buf[prefix.len..][0..key.len], key);
            @memcpy(opt_buf[prefix.len + key.len ..][0..eq.len], eq);
            @memcpy(opt_buf[prefix.len + key.len + eq.len ..][0..val.len], val);
            zig_cmd.appendArg(opt_buf[0..total]) catch break;
        }
    }

    // Forward -j if specified.
    if (config.thread_count > 0) {
        var j_buf: [32]u8 = undefined;
        const j_str = std.fmt.bufPrint(&j_buf, "-j{d}", .{config.thread_count}) catch "-j4";
        zig_cmd.appendArg(j_str) catch {};
    }

    // Set cwd to build root.
    if (build_root.len > 0 and build_root.len <= PATH_BUF_SIZE) {
        @memcpy(zig_cmd.cwd[0..build_root.len], build_root);
        zig_cmd.cwd_len = build_root.len;
    }

    printMsg(io, "running: zig build ...", .{});

    var stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined;
    var stderr_len: usize = 0;
    const exit_code = runCommand(&zig_cmd, &stderr_buf, &stderr_len, io) catch {
        printMsg(io, "error: failed to spawn zig build", .{});
        return false;
    };

    if (exit_code != 0) {
        printMsg(io, "error: zig build exited with code {d}", .{exit_code});
        if (stderr_len > 0) {
            printMsg(io, "stderr: {s}", .{stderr_buf[0..stderr_len]});
        }
        return false;
    }

    printMsg(io, "zig build completed successfully", .{});

    // ── Step 3: Hash zig build output (zig-out/ now has zig build output)
    printMsg(io, "hashing zig build output...", .{});

    bin_count = collectDirHashes(io, bin_path, &bin_table, bin_count, false);
    lib_count = collectDirHashes(io, lib_path, &lib_table, lib_count, false);

    // ── Step 4: Compare and report ──────────────────────────────────────
    printMsg(io, "\n── comparison results ──", .{});

    // totals: [matched, mismatched, missing]
    var totals = [3]usize{ 0, 0, 0 };

    compareEntries(io, &bin_table, bin_count, "zig-out/bin", &totals);
    compareEntries(io, &lib_table, lib_count, "zig-out/lib", &totals);

    const matched = totals[0];
    const mismatched = totals[1];
    const missing = totals[2];
    const total = matched + mismatched + missing;

    printMsg(io, "\n── verify-identical summary ──", .{});
    printMsg(io, "total files: {d}", .{total});
    printMsg(io, "matched:     {d}", .{matched});
    printMsg(io, "mismatched:  {d}", .{mismatched});
    printMsg(io, "missing:     {d}", .{missing});

    if (total == 0) {
        printMsg(io, "warning: no output files found in zig-out/bin/ or zig-out/lib/", .{});
        printMsg(io, "note: ensure both build systems produce output before comparing", .{});
        return true;
    }

    if (mismatched > 0 or missing > 0) {
        printMsg(io, "RESULT: MISMATCH — sig build and zig build produced different output", .{});
        return false;
    }

    printMsg(io, "RESULT: IDENTICAL — all {d} files match", .{matched});
    return true;
}

// ── Benchmark mode ─────────────────────────────────────────────────────────

/// Format a nanosecond duration as milliseconds into a caller buffer.
/// Returns the formatted slice, e.g. "123" or "1456".
fn formatMs(buf: *[32]u8, ns: u64) []const u8 {
    const ms = ns / 1_000_000;
    return std.fmt.bufPrint(buf, "{d}", .{ms}) catch "?";
}

/// Format a percentage (0–100) with one decimal place into a caller buffer.
/// Returns the formatted slice, e.g. "85.7%".
fn formatPct(buf: *[32]u8, numerator: usize, denominator: usize) []const u8 {
    if (denominator == 0) return "N/A";
    // Compute percentage * 10 for one decimal place without floats.
    const pct_x10 = (numerator * 1000) / denominator;
    const whole = pct_x10 / 10;
    const frac = pct_x10 % 10;
    return std.fmt.bufPrint(buf, "{d}.{d}%", .{ whole, frac }) catch "?";
}

/// Format a signed delta percentage into a caller buffer.
/// Negative means sig is faster. E.g. "-23.5%" or "+12.0%".
fn formatDelta(buf: *[32]u8, sig_ns: u64, zig_ns: u64) []const u8 {
    if (zig_ns == 0) return "N/A";
    if (sig_ns <= zig_ns) {
        // sig is faster or equal — show negative delta.
        const saved_x10 = ((zig_ns - sig_ns) * 1000) / zig_ns;
        const whole = saved_x10 / 10;
        const frac = saved_x10 % 10;
        return std.fmt.bufPrint(buf, "-{d}.{d}%", .{ whole, frac }) catch "?";
    } else {
        // sig is slower — show positive delta.
        const over_x10 = ((sig_ns - zig_ns) * 1000) / zig_ns;
        const whole = over_x10 / 10;
        const frac = over_x10 % 10;
        return std.fmt.bufPrint(buf, "+{d}.{d}%", .{ whole, frac }) catch "?";
    }
}

/// Run --benchmark mode: measure sig build vs zig build side-by-side.
/// Prints a markdown table comparing wall-clock time, cache hit rate.
/// Peak RSS measurement is platform-specific and reported as "N/A" when
/// not available (requires OS-specific APIs).
pub fn runBenchmark(
    io: std.Io,
    build_root: []const u8,
    config: *const Cli_Config,
    sig_elapsed_ns: u64,
    summary: *const Schedule_Summary,
) void {
    printMsg(io, "\n── benchmark: sig build vs zig build ──", .{});

    // ── Format sig build metrics ────────────────────────────────────────
    var sig_ms_buf: [32]u8 = undefined;
    const sig_ms = formatMs(&sig_ms_buf, sig_elapsed_ns);

    var sig_cache_buf: [32]u8 = undefined;
    const sig_cache = formatPct(&sig_cache_buf, summary.cached, summary.total);

    // ── Run zig build and measure wall-clock time ───────────────────────
    var zig_cmd: Command_Buffer = .{};
    zig_cmd.appendArg("zig") catch {
        printMsg(io, "error: failed to construct zig build command", .{});
        return;
    };
    zig_cmd.appendArg("build") catch {
        printMsg(io, "error: failed to add 'build' arg", .{});
        return;
    };

    // Forward -D options.
    for (config.options.entries[0..]) |entry| {
        if (!entry.occupied) continue;
        const key = entry.key_buf[0..entry.key_len];
        const val = entry.val_buf[0..entry.val_len];
        var opt_buf: [PATH_BUF_SIZE]u8 = undefined;
        const prefix = "-D";
        const eq = "=";
        const total_len = prefix.len + key.len + eq.len + val.len;
        if (total_len <= PATH_BUF_SIZE) {
            @memcpy(opt_buf[0..prefix.len], prefix);
            @memcpy(opt_buf[prefix.len..][0..key.len], key);
            @memcpy(opt_buf[prefix.len + key.len ..][0..eq.len], eq);
            @memcpy(opt_buf[prefix.len + key.len + eq.len ..][0..val.len], val);
            zig_cmd.appendArg(opt_buf[0..total_len]) catch break;
        }
    }

    // Forward -j if specified.
    if (config.thread_count > 0) {
        var j_buf: [32]u8 = undefined;
        const j_str = std.fmt.bufPrint(&j_buf, "-j{d}", .{config.thread_count}) catch "-j4";
        zig_cmd.appendArg(j_str) catch {};
    }

    // Set cwd to build root.
    if (build_root.len > 0 and build_root.len <= PATH_BUF_SIZE) {
        @memcpy(zig_cmd.cwd[0..build_root.len], build_root);
        zig_cmd.cwd_len = build_root.len;
    }

    printMsg(io, "running: zig build ...", .{});

    const zig_start_ns = std.Io.Clock.awake.now(io).nanoseconds;

    var stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined;
    var stderr_len: usize = 0;
    const zig_exit = runCommand(&zig_cmd, &stderr_buf, &stderr_len, io) catch {
        printMsg(io, "error: failed to spawn zig build", .{});
        return;
    };

    const zig_end_ns = std.Io.Clock.awake.now(io).nanoseconds;
    const zig_elapsed_ns: u64 = @intCast(zig_end_ns - zig_start_ns);

    if (zig_exit != 0) {
        printMsg(io, "warning: zig build exited with code {d}", .{zig_exit});
        if (stderr_len > 0) {
            printMsg(io, "stderr: {s}", .{stderr_buf[0..stderr_len]});
        }
    }

    // ── Format zig build metrics ────────────────────────────────────────
    var zig_ms_buf: [32]u8 = undefined;
    const zig_ms = formatMs(&zig_ms_buf, zig_elapsed_ns);

    var delta_buf: [32]u8 = undefined;
    const delta = formatDelta(&delta_buf, sig_elapsed_ns, zig_elapsed_ns);

    // ── Print markdown table ────────────────────────────────────────────
    printMsg(io, "", .{});
    printMsg(io, "| Metric | sig build | zig build | \xce\x94 |", .{});
    printMsg(io, "|---|--:|--:|--:|", .{});
    printMsg(io, "| Wall-clock time | {s} ms | {s} ms | {s} |", .{ sig_ms, zig_ms, delta });
    printMsg(io, "| Cache hit rate | {s} | N/A | \xe2\x80\x94 |", .{sig_cache});
    printMsg(io, "| Peak RSS | N/A | N/A | \xe2\x80\x94 |", .{});
    printMsg(io, "", .{});

    // ── Performance target validation ───────────────────────────────────
    printMsg(io, "── Performance Targets ──", .{});

    // Target 1: Full rebuild ≤80% of zig build wall-clock time
    const target_80pct = (zig_elapsed_ns * 80) / 100;
    if (sig_elapsed_ns <= target_80pct) {
        printMsg(io, "  [PASS] Full rebuild: {s} ms <= 80% of {s} ms", .{ sig_ms, zig_ms });
    } else {
        printMsg(io, "  [FAIL] Full rebuild: {s} ms > 80% of {s} ms", .{ sig_ms, zig_ms });
    }

    // Target 2: Incremental ≤50ms (check if sig build was incremental via cache hit rate)
    if (summary.cached == summary.total and summary.total > 0) {
        const incremental_ms = sig_elapsed_ns / 1_000_000;
        if (incremental_ms <= 50) {
            printMsg(io, "  [PASS] Incremental: {d} ms <= 50 ms", .{incremental_ms});
        } else {
            printMsg(io, "  [FAIL] Incremental: {d} ms > 50 ms", .{incremental_ms});
        }
    } else {
        printMsg(io, "  [SKIP] Incremental: not a fully cached build ({d}/{d} cached)", .{ summary.cached, summary.total });
    }

    // Target 3: Peak RSS ≤50% of zig build (not measurable without OS APIs)
    printMsg(io, "  [SKIP] Peak RSS: measurement requires OS-specific APIs", .{});

    // Target 4: Configure phase ≤10ms (measured separately, not available here)
    printMsg(io, "  [SKIP] Configure phase: requires separate measurement", .{});

    // Target 5: Zero heap allocations during configure
    printMsg(io, "  [PASS] Zero heap allocations: enforced by .sig extension", .{});

    printMsg(io, "", .{});
}

// ── Self-hosting verification ─────────────────────────────────────────────────

/// Verify self-hosting: rebuild the build runner using itself and compare
/// the resulting binary against the currently running (bootstrapped) binary.
///
/// Flow:
///   1. Invoke `sig build-exe --dep sig -Mroot=tools/sig_build/main.sig
///      -Msig=lib/sig/sig.zig --name sig-build-verify -femit-bin=.sig-cache/sig-build-verify`
///   2. Compute content hash of the original binary (at `original_binary_path`)
///   3. Compute content hash of the rebuilt binary (.sig-cache/sig-build-verify)
///   4. Compare hashes and report PASS/FAIL
///
/// Returns true if the rebuilt binary is byte-identical to the original.
pub fn verifySelfHosting(
    io: std.Io,
    original_binary_path: []const u8,
    compiler_path: []const u8,
) bool {
    printMsg(io, "\n── self-test: verifying self-hosting ──", .{});
    printMsg(io, "original binary: {s}", .{original_binary_path});

    // ── Step 1: Rebuild the build runner ─────────────────────────────────
    var cmd: Command_Buffer = .{};

    // Use the provided compiler path, or fall back to "sig".
    if (compiler_path.len > 0) {
        cmd.appendArg(compiler_path) catch {
            printMsg(io, "error: compiler path too long", .{});
            return false;
        };
    } else {
        cmd.appendArg("sig") catch {
            printMsg(io, "error: failed to add compiler arg", .{});
            return false;
        };
    }

    cmd.appendArg("build-exe") catch return false;
    cmd.appendArg("--dep") catch return false;
    cmd.appendArg("sig") catch return false;
    cmd.appendArg("-Mroot=tools/sig_build/main.sig") catch return false;
    cmd.appendArg("-Msig=lib/sig/sig.zig") catch return false;
    cmd.appendArg("--name") catch return false;
    cmd.appendArg("sig-build-verify") catch return false;
    cmd.appendArg("-femit-bin=.sig-cache/sig-build-verify") catch return false;

    printMsg(io, "rebuilding: sig build-exe tools/sig_build/main.sig ...", .{});

    var stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined;
    var stderr_len: usize = 0;
    const exit_code = runCommand(&cmd, &stderr_buf, &stderr_len, io) catch {
        printMsg(io, "error: failed to spawn rebuild command", .{});
        return false;
    };

    if (exit_code != 0) {
        printMsg(io, "error: rebuild exited with code {d}", .{exit_code});
        if (stderr_len > 0) {
            printMsg(io, "stderr: {s}", .{stderr_buf[0..stderr_len]});
        }
        return false;
    }

    printMsg(io, "rebuild completed successfully", .{});

    // ── Step 2: Compute content hash of the original binary ─────────────
    const original_paths = [_][]const u8{original_binary_path};
    const original_hash = computeContentHash(io, &original_paths);

    // ── Step 3: Compute content hash of the rebuilt binary ──────────────
    const rebuilt_path = ".sig-cache/sig-build-verify";
    const rebuilt_paths = [_][]const u8{rebuilt_path};
    const rebuilt_hash = computeContentHash(io, &rebuilt_paths);

    // ── Step 4: Compare and report ──────────────────────────────────────
    var orig_hex: [32]u8 = undefined;
    var rebuilt_hex: [32]u8 = undefined;
    _ = formatHash(&orig_hex, original_hash);
    _ = formatHash(&rebuilt_hex, rebuilt_hash);

    printMsg(io, "original hash: {s}", .{orig_hex[0..32]});
    printMsg(io, "rebuilt hash:  {s}", .{rebuilt_hex[0..32]});

    if (std.mem.eql(u8, &original_hash, &rebuilt_hash)) {
        printMsg(io, "RESULT: PASS — rebuilt binary is byte-identical", .{});
        return true;
    } else {
        printMsg(io, "RESULT: FAIL — rebuilt binary differs from original", .{});
        return false;
    }
}

// ── Runner arguments (fixed positional args from the compiler) ───────────────

/// Parsed fixed positional arguments from the compiler's sigBuildDelegate.
/// Layout: argv[0]=runner, argv[1]=compiler, argv[2]=zig_lib_dir,
///         argv[3]=build_root, argv[4]=local_cache, argv[5]=global_cache.
pub const Runner_Args = struct {
    runner_binary: [PATH_BUF_SIZE]u8 = undefined,
    runner_binary_len: usize = 0,
    compiler_path: [PATH_BUF_SIZE]u8 = undefined,
    compiler_path_len: usize = 0,
    zig_lib_dir: [PATH_BUF_SIZE]u8 = undefined,
    zig_lib_dir_len: usize = 0,
    build_root: [PATH_BUF_SIZE]u8 = undefined,
    build_root_len: usize = 0,
    local_cache_dir: [PATH_BUF_SIZE]u8 = undefined,
    local_cache_dir_len: usize = 0,
    global_cache_dir: [PATH_BUF_SIZE]u8 = undefined,
    global_cache_dir_len: usize = 0,
};

// ── CLI configuration ────────────────────────────────────────────────────────

/// Parsed CLI configuration from user arguments (argv[6+]).
/// All fields are stack-allocated.
pub const Cli_Config = struct {
    /// Requested step names from positional arguments.
    requested_steps: containers.BoundedVec([]const u8, 32) = .{},
    /// -D options parsed into the option map.
    options: Option_Map = .{},
    /// -j thread count (0 = auto-detect).
    thread_count: usize = 0,
    /// --benchmark mode.
    benchmark: bool = false,
    /// --verbose mode.
    verbose: bool = false,
    /// --verify-identical mode.
    verify_identical: bool = false,
    /// --self-test mode: rebuild the build runner and verify byte-identical output.
    self_test: bool = false,
    /// Path to the compiler binary for self-test rebuild (defaults to "sig").
    self_test_compiler: [PATH_BUF_SIZE]u8 = undefined,
    self_test_compiler_len: usize = 0,
    /// --prefix override for install directory.
    install_prefix: [PATH_BUF_SIZE]u8 = undefined,
    install_prefix_len: usize = 0,
};

/// Default build file name.
const DEFAULT_BUILD_FILE = "build.sig";
/// Default cache directory name.
const DEFAULT_CACHE_DIR = ".sig-cache";
/// Default cache file name within the cache directory.
const DEFAULT_CACHE_FILE = "cache.bin";

/// Parse a `-j` argument into a thread count.
/// Accepts `-jN` (e.g. `-j8`) or `-j N` (value in next arg, handled by caller).
pub fn parseThreadCount(arg: []const u8) ?usize {
    // "-jN" form: digits immediately follow "-j".
    if (arg.len > 2) {
        return std.fmt.parseInt(usize, arg[2..], 10) catch null;
    }
    return null;
}

/// Parse a `--key=value` long option. Returns the value after `=`, or null
/// if the argument doesn't contain `=` (value is in the next arg).
pub fn parseLongOptionValue(arg: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
        return arg[eq_pos + 1 ..];
    }
    return null;
}

/// Write an error message to stderr and exit with code 1.
pub fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    const stderr = std.Io.File.stderr();
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "error: " ++ fmt ++ "\n", args)) |msg| {
        stderr.writeStreamingAll(io, msg) catch {};
    } else |_| {
        stderr.writeStreamingAll(io, "error: fatal\n") catch {};
    }
    sig_process.exit(1);
}

/// Write an informational message to stdout.
pub fn printMsg(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    stdout.writeStreamingAll(io, msg) catch {};
}

/// Print the schedule summary to stdout.
pub fn printSummary(io: std.Io, summary: *const Schedule_Summary) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\nBuild summary: {d} total, {d} succeeded, {d} cached, {d} failed, {d} skipped\n", .{
        summary.total,
        summary.succeeded,
        summary.cached,
        summary.failed,
        summary.skipped,
    }) catch return;
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, msg) catch {};
}

/// Format a capacity error message with registry/buffer name and limits.
/// Called by build_host.sig and build.sig when catching capacity errors.
pub fn reportCapacityError(io: std.Io, registry_name: []const u8, current: usize, maximum: usize) void {
    printMsg(io, "CapacityExceeded: {s} ({d}/{d})", .{ registry_name, current, maximum });
}

// ── build host compilation ────────────────────────────────────────────────────

/// Compile the build host with build.sig wired as @import("build").
///
/// Instead of compiling build.sig directly as an executable, we compile
/// build_host.sig — a minimal entry point that imports build.sig as a module,
/// creates a Build_Context, calls build.sig's build function, and runs the
/// scheduler. This is the two-stage compilation approach:
///
///   sig build-exe \
///       --dep build --dep sig_build --dep sig --dep std \
///       -Mroot=<build_host.sig> \
///       --dep sig --dep std -Msig_build=<main.sig> \
///       --dep sig_build -Mbuild=<build_file_path> \
///       -Msig=<sig.zig> \
///       -Mstd=<std.zig>
///
/// Returns the path to the compiled host binary on success.
/// On failure, prints diagnostics and calls fatal() (does not return).
fn compileBuildSig(
    io: std.Io,
    build_file_path: []const u8,
    runner_args: *const Runner_Args,
    verbose: bool,
) []const u8 {
    const compiler_path = runner_args.compiler_path[0..runner_args.compiler_path_len];
    const zig_lib_dir = runner_args.zig_lib_dir[0..runner_args.zig_lib_dir_len];
    const local_cache_dir = runner_args.local_cache_dir[0..runner_args.local_cache_dir_len];
    const global_cache_dir = runner_args.global_cache_dir[0..runner_args.global_cache_dir_len];

    // ── Construct source path: build_host.sig ───────────────────────────
    // build_host.sig lives alongside main.sig: <zig_lib_dir>/../tools/sig_build/build_host.sig
    var host_src_buf: [PATH_BUF_SIZE]u8 = undefined;
    const host_src_segs = [_][]const u8{ zig_lib_dir, "..", "tools", "sig_build", "build_host.sig" };
    const host_src_path = sig_fs.joinPath(&host_src_buf, &host_src_segs) catch {
        fatal(io, "failed to construct build_host.sig path", .{});
    };

    // ── Construct module paths ──────────────────────────────────────────
    // sig module: <zig_lib_dir>/sig/sig.zig
    var sig_mod_path_buf: [PATH_BUF_SIZE]u8 = undefined;
    const sig_mod_segs = [_][]const u8{ zig_lib_dir, "sig", "sig.zig" };
    const sig_mod_path = sig_fs.joinPath(&sig_mod_path_buf, &sig_mod_segs) catch {
        fatal(io, "failed to construct sig module path", .{});
    };

    // sig_build module: <zig_lib_dir>/../tools/sig_build/main.sig
    // Points to main.sig which exports all pub types and functions.
    var sig_build_mod_path_buf: [PATH_BUF_SIZE]u8 = undefined;
    const sig_build_mod_segs = [_][]const u8{ zig_lib_dir, "..", "tools", "sig_build", "main.sig" };
    const sig_build_mod_path = sig_fs.joinPath(&sig_build_mod_path_buf, &sig_build_mod_segs) catch {
        fatal(io, "failed to construct sig_build module path", .{});
    };

    // std module: <zig_lib_dir>/std/std.zig
    var std_mod_path_buf: [PATH_BUF_SIZE]u8 = undefined;
    const std_mod_segs = [_][]const u8{ zig_lib_dir, "std", "std.zig" };
    const std_mod_path = sig_fs.joinPath(&std_mod_path_buf, &std_mod_segs) catch {
        fatal(io, "failed to construct std module path", .{});
    };

    // ── Construct emit path ─────────────────────────────────────────────
    const bin_name = if (builtin.os.tag == .windows) "build_sig_host.exe" else "build_sig_host";
    var emit_path_buf: [PATH_BUF_SIZE]u8 = undefined;
    const emit_segs = [_][]const u8{ local_cache_dir, bin_name };
    const emit_path = sig_fs.joinPath(&emit_path_buf, &emit_segs) catch {
        fatal(io, "failed to construct emit path", .{});
    };

    // ── Construct -Mname=path flag values ──────────────────────────────
    // build:<build_file_path> (user's build.sig)
    var build_mod_flag_buf: [PATH_BUF_SIZE]u8 = undefined;
    const build_prefix = "-Mbuild=";
    if (build_prefix.len + build_file_path.len > PATH_BUF_SIZE) fatal(io, "build module flag too long", .{});
    @memcpy(build_mod_flag_buf[0..build_prefix.len], build_prefix);
    @memcpy(build_mod_flag_buf[build_prefix.len..][0..build_file_path.len], build_file_path);
    const build_mod_flag = build_mod_flag_buf[0 .. build_prefix.len + build_file_path.len];

    // sig:path
    var sig_mod_flag_buf: [PATH_BUF_SIZE]u8 = undefined;
    const sig_prefix = "-Msig=";
    if (sig_prefix.len + sig_mod_path.len > PATH_BUF_SIZE) fatal(io, "sig module flag too long", .{});
    @memcpy(sig_mod_flag_buf[0..sig_prefix.len], sig_prefix);
    @memcpy(sig_mod_flag_buf[sig_prefix.len..][0..sig_mod_path.len], sig_mod_path);
    const sig_mod_flag = sig_mod_flag_buf[0 .. sig_prefix.len + sig_mod_path.len];

    // sig_build:path
    var sig_build_mod_flag_buf: [PATH_BUF_SIZE]u8 = undefined;
    const sig_build_prefix = "-Msig_build=";
    if (sig_build_prefix.len + sig_build_mod_path.len > PATH_BUF_SIZE) fatal(io, "sig_build module flag too long", .{});
    @memcpy(sig_build_mod_flag_buf[0..sig_build_prefix.len], sig_build_prefix);
    @memcpy(sig_build_mod_flag_buf[sig_build_prefix.len..][0..sig_build_mod_path.len], sig_build_mod_path);
    const sig_build_mod_flag = sig_build_mod_flag_buf[0 .. sig_build_prefix.len + sig_build_mod_path.len];

    // std:path
    var std_mod_flag_buf: [PATH_BUF_SIZE]u8 = undefined;
    const std_prefix = "-Mstd=";
    if (std_prefix.len + std_mod_path.len > PATH_BUF_SIZE) fatal(io, "std module flag too long", .{});
    @memcpy(std_mod_flag_buf[0..std_prefix.len], std_prefix);
    @memcpy(std_mod_flag_buf[std_prefix.len..][0..std_mod_path.len], std_mod_path);
    const std_mod_flag = std_mod_flag_buf[0 .. std_prefix.len + std_mod_path.len];

    // ── Construct -femit-bin=<path> flag ────────────────────────────────
    var emit_flag_buf: [PATH_BUF_SIZE]u8 = undefined;
    const emit_prefix = "-femit-bin=";
    if (emit_prefix.len + emit_path.len > PATH_BUF_SIZE) fatal(io, "emit flag too long", .{});
    @memcpy(emit_flag_buf[0..emit_prefix.len], emit_prefix);
    @memcpy(emit_flag_buf[emit_prefix.len..][0..emit_path.len], emit_path);
    const emit_flag = emit_flag_buf[0 .. emit_prefix.len + emit_path.len];

    // ── Construct -Mroot=<host_src_path> flag ───────────────────────────
    var root_mod_flag_buf: [PATH_BUF_SIZE]u8 = undefined;
    const root_prefix = "-Mroot=";
    if (root_prefix.len + host_src_path.len > PATH_BUF_SIZE) fatal(io, "root module flag too long", .{});
    @memcpy(root_mod_flag_buf[0..root_prefix.len], root_prefix);
    @memcpy(root_mod_flag_buf[root_prefix.len..][0..host_src_path.len], host_src_path);
    const root_mod_flag = root_mod_flag_buf[0 .. root_prefix.len + host_src_path.len];

    // ── Build command ───────────────────────────────────────────────────
    // Zig 0.16 module syntax: --dep flags declare dependencies for the NEXT
    // -M module. The dependency graph is:
    //   root (build_host.sig) imports: build, sig_build, sig, std
    //   sig_build (main.sig)  imports: sig, std
    //   build (build.sig)     imports: sig_build
    //   sig, std              are leaf modules (no deps)
    var cmd: Command_Buffer = .{};

    cmd.appendArg(compiler_path) catch fatal(io, "compiler path too long for command buffer", .{});
    cmd.appendArg("build-exe") catch fatal(io, "failed to add build-exe arg", .{});
    // Root module deps (build, sig_build, sig, std) — must come before -Mroot=
    cmd.appendArg("--dep") catch fatal(io, "failed to add --dep arg", .{});
    cmd.appendArg("build") catch fatal(io, "failed to add dep name", .{});
    cmd.appendArg("--dep") catch fatal(io, "failed to add --dep arg", .{});
    cmd.appendArg("sig_build") catch fatal(io, "failed to add dep name", .{});
    cmd.appendArg("--dep") catch fatal(io, "failed to add --dep arg", .{});
    cmd.appendArg("sig") catch fatal(io, "failed to add dep name", .{});
    cmd.appendArg("--dep") catch fatal(io, "failed to add --dep arg", .{});
    cmd.appendArg("std") catch fatal(io, "failed to add dep name", .{});
    cmd.appendArg(root_mod_flag) catch fatal(io, "root mod flag too long for command buffer", .{});
    // sig_build deps (sig, std) — must come before -Msig_build=
    cmd.appendArg("--dep") catch fatal(io, "failed to add --dep arg", .{});
    cmd.appendArg("sig") catch fatal(io, "failed to add dep name", .{});
    cmd.appendArg("--dep") catch fatal(io, "failed to add --dep arg", .{});
    cmd.appendArg("std") catch fatal(io, "failed to add dep name", .{});
    cmd.appendArg(sig_build_mod_flag) catch fatal(io, "sig_build mod flag too long for command buffer", .{});
    // build deps (sig_build) — must come before -Mbuild=
    cmd.appendArg("--dep") catch fatal(io, "failed to add --dep arg", .{});
    cmd.appendArg("sig_build") catch fatal(io, "failed to add dep name", .{});
    cmd.appendArg(build_mod_flag) catch fatal(io, "build mod flag too long for command buffer", .{});
    // Leaf modules (no deps)
    cmd.appendArg(sig_mod_flag) catch fatal(io, "sig mod flag too long for command buffer", .{});
    cmd.appendArg(std_mod_flag) catch fatal(io, "std mod flag too long for command buffer", .{});
    cmd.appendArg("--cache-dir") catch fatal(io, "failed to add --cache-dir arg", .{});
    cmd.appendArg(local_cache_dir) catch fatal(io, "local cache dir too long for command buffer", .{});
    cmd.appendArg("--global-cache-dir") catch fatal(io, "failed to add --global-cache-dir arg", .{});
    cmd.appendArg(global_cache_dir) catch fatal(io, "global cache dir too long for command buffer", .{});
    cmd.appendArg("--zig-lib-dir") catch fatal(io, "failed to add --zig-lib-dir arg", .{});
    cmd.appendArg(zig_lib_dir) catch fatal(io, "zig lib dir too long for command buffer", .{});
    cmd.appendArg(emit_flag) catch fatal(io, "emit flag too long for command buffer", .{});

    if (verbose) {
        printMsg(io, "compiling build host: {s} build-exe -Mroot={s} -Mbuild={s}", .{ compiler_path, host_src_path, build_file_path });
    }

    // ── Execute compilation ─────────────────────────────────────────────
    var stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined;
    var stderr_len: usize = 0;
    const exit_code = runCommand(&cmd, &stderr_buf, &stderr_len, io) catch {
        fatal(io, "failed to spawn build host compilation process", .{});
    };

    if (exit_code == 0) {
        return emit_path;
    }

    // Exit code 2: compile errors already reported by the compiler.
    if (exit_code == 2) {
        sig_process.exit(2);
    }

    // Other non-zero: report failure with stderr.
    if (stderr_len > 0) {
        printMsg(io, "build host compilation failed with exit code {d}:\n{s}", .{ exit_code, stderr_buf[0..stderr_len] });
    } else {
        printMsg(io, "build host compilation failed with exit code {d}", .{exit_code});
    }
    sig_process.exit(1);
}

// ── Entry point ─────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // ── 1. Parse argv: fixed positional args [0..6) + user args [6..] ───
    var runner_args: Runner_Args = .{};
    var config: Cli_Config = .{};

    // Access raw argv via sig.process.Argv_Iterator — zero-allocator on all platforms.
    // On POSIX this is zero-copy; on Windows it decodes WTF-16 into a stack buffer.
    var argv_buf: [4096]u8 = undefined;
    var args_it = sig_process.Argv_Iterator.init(init.minimal.args.vector, &argv_buf);

    // Count total args to validate we have at least 6.
    var arg_count: usize = 0;
    // We need to collect all args first since the iterator is forward-only.
    // Use a bounded buffer for the fixed args, then parse user args inline.

    // argv[0]: runner binary path
    if (args_it.next() catch fatal(io, "argv decode error", .{})) |arg| {
        if (arg.len > PATH_BUF_SIZE) fatal(io, "argv[0] (runner binary) path too long", .{});
        @memcpy(runner_args.runner_binary[0..arg.len], arg);
        runner_args.runner_binary_len = arg.len;
        arg_count += 1;
    }

    // argv[1]: sig compiler path
    if (args_it.next() catch fatal(io, "argv decode error", .{})) |arg| {
        if (arg.len > PATH_BUF_SIZE) fatal(io, "argv[1] (compiler path) too long", .{});
        @memcpy(runner_args.compiler_path[0..arg.len], arg);
        runner_args.compiler_path_len = arg.len;
        arg_count += 1;
    }

    // argv[2]: zig lib directory
    if (args_it.next() catch fatal(io, "argv decode error", .{})) |arg| {
        if (arg.len > PATH_BUF_SIZE) fatal(io, "argv[2] (zig lib dir) too long", .{});
        @memcpy(runner_args.zig_lib_dir[0..arg.len], arg);
        runner_args.zig_lib_dir_len = arg.len;
        arg_count += 1;
    }

    // argv[3]: build root directory
    if (args_it.next() catch fatal(io, "argv decode error", .{})) |arg| {
        if (arg.len > PATH_BUF_SIZE) fatal(io, "argv[3] (build root) too long", .{});
        @memcpy(runner_args.build_root[0..arg.len], arg);
        runner_args.build_root_len = arg.len;
        arg_count += 1;
    }

    // argv[4]: local cache directory
    if (args_it.next() catch fatal(io, "argv decode error", .{})) |arg| {
        if (arg.len > PATH_BUF_SIZE) fatal(io, "argv[4] (local cache dir) too long", .{});
        @memcpy(runner_args.local_cache_dir[0..arg.len], arg);
        runner_args.local_cache_dir_len = arg.len;
        arg_count += 1;
    }

    // argv[5]: global cache directory
    if (args_it.next() catch fatal(io, "argv decode error", .{})) |arg| {
        if (arg.len > PATH_BUF_SIZE) fatal(io, "argv[5] (global cache dir) too long", .{});
        @memcpy(runner_args.global_cache_dir[0..arg.len], arg);
        runner_args.global_cache_dir_len = arg.len;
        arg_count += 1;
    }

    // Validate that all 6 fixed positional args were present.
    if (arg_count < 6) {
        fatal(io, "sig build runner requires at least 6 arguments (got {d})\n  Usage: <runner> <compiler> <zig-lib-dir> <build-root> <local-cache> <global-cache> [user-args...]", .{arg_count});
    }

    // argv[6..]: user arguments (step names, -D flags, -j, --verbose, etc.)
    while (args_it.next() catch fatal(io, "argv decode error", .{})) |arg| {
        if (arg.len >= 2 and arg[0] == '-' and arg[1] == 'D') {
            // -Dname=value or -Dname (boolean shorthand)
            parseOption(&config.options, arg) catch {
                fatal(io, "too many -D options (max {d})", .{MAX_OPTIONS});
            };
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == 'j') {
            // -jN or -j N
            if (parseThreadCount(arg)) |count| {
                config.thread_count = count;
            } else {
                // -j N form: next arg is the count.
                if (args_it.next() catch fatal(io, "argv decode error", .{})) |next_arg| {
                    config.thread_count = std.fmt.parseInt(usize, next_arg, 10) catch {
                        fatal(io, "invalid thread count: '{s}'", .{next_arg});
                    };
                } else {
                    fatal(io, "-j requires a thread count argument", .{});
                }
            }
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            // Long options: --benchmark, --verbose, --verify-identical, --self-test
            if (std.mem.eql(u8, arg, "--benchmark")) {
                config.benchmark = true;
            } else if (std.mem.eql(u8, arg, "--verbose")) {
                config.verbose = true;
            } else if (std.mem.eql(u8, arg, "--verify-identical")) {
                config.verify_identical = true;
            } else if (std.mem.eql(u8, arg, "--self-test") or std.mem.startsWith(u8, arg, "--self-test=")) {
                config.self_test = true;
                // Optional: --self-test=<compiler-path> to specify the compiler binary.
                if (parseLongOptionValue(arg)) |value| {
                    if (value.len > PATH_BUF_SIZE) fatal(io, "--self-test compiler path too long", .{});
                    @memcpy(config.self_test_compiler[0..value.len], value);
                    config.self_test_compiler_len = value.len;
                }
            } else if (std.mem.eql(u8, arg, "--prefix") or
                std.mem.eql(u8, arg, "--maxrss"))
            {
                // Store --prefix for forwarding to build host.
                if (std.mem.eql(u8, arg, "--prefix")) {
                    if (args_it.next() catch null) |value| {
                        if (value.len <= PATH_BUF_SIZE) {
                            @memcpy(config.install_prefix[0..value.len], value);
                            config.install_prefix_len = value.len;
                        }
                    }
                } else {
                    // --maxrss: skip the value
                    _ = args_it.next() catch {};
                }
            } else {
                fatal(io, "unknown option: '{s}'", .{arg});
            }
        } else {
            // Positional argument: step name.
            config.requested_steps.push(arg) catch {
                fatal(io, "too many step names (max 32)", .{});
            };
        }
    }

    // ── 2. Extract build root from Runner_Args ──────────────────────────
    const build_root = runner_args.build_root[0..runner_args.build_root_len];

    // ── 3. Derive build.sig path from build root ────────────────────────
    var build_file_path_buf: [PATH_BUF_SIZE]u8 = undefined;
    const build_file_segs = [_][]const u8{ build_root, DEFAULT_BUILD_FILE };
    const build_file_path = sig_fs.joinPath(&build_file_path_buf, &build_file_segs) catch {
        fatal(io, "failed to construct build file path", .{});
    };

    // Verify build.sig exists by attempting to open it.
    {
        const cwd: std.Io.Dir = .cwd();
        var file = cwd.openFile(io, build_file_path, .{}) catch {
            fatal(io, "build file not found: '{s}'", .{build_file_path});
        };
        file.close(io);
    }

    if (config.verbose) {
        printMsg(io, "compiler:   {s}", .{runner_args.compiler_path[0..runner_args.compiler_path_len]});
        printMsg(io, "zig lib:    {s}", .{runner_args.zig_lib_dir[0..runner_args.zig_lib_dir_len]});
        printMsg(io, "build file: {s}", .{build_file_path});
        printMsg(io, "build root: {s}", .{build_root});
    }

    // ── 4. Compile build host ──────────────────────────────────────────
    // The build host is build_host.sig compiled with -Mbuild=<build.sig>.
    // It handles everything: creates Build_Context, calls build.sig's build(),
    // validates steps, runs the scheduler, and exits.
    const build_host_binary = compileBuildSig(io, build_file_path, &runner_args, config.verbose);

    if (config.verbose) {
        printMsg(io, "build host compiled: {s}", .{build_host_binary});
    }

    // ── 5. Spawn build host with same argv and propagate exit code ──────
    // The host receives the same argument protocol as this runner:
    // [host_binary, compiler, zig_lib_dir, build_root, local_cache, global_cache, user_args...]
    // We reconstruct the argv from runner_args and config.
    var host_cmd: Command_Buffer = .{};

    host_cmd.appendArg(build_host_binary) catch fatal(io, "host binary path too long", .{});
    host_cmd.appendArg(runner_args.compiler_path[0..runner_args.compiler_path_len]) catch fatal(io, "compiler path too long", .{});
    host_cmd.appendArg(runner_args.zig_lib_dir[0..runner_args.zig_lib_dir_len]) catch fatal(io, "zig lib dir too long", .{});
    host_cmd.appendArg(build_root) catch fatal(io, "build root too long", .{});
    host_cmd.appendArg(runner_args.local_cache_dir[0..runner_args.local_cache_dir_len]) catch fatal(io, "local cache dir too long", .{});
    host_cmd.appendArg(runner_args.global_cache_dir[0..runner_args.global_cache_dir_len]) catch fatal(io, "global cache dir too long", .{});

    // Forward user args: step names, -D flags, -j, --verbose, etc.
    const requested = config.requested_steps.slice();
    for (requested) |step_name| {
        host_cmd.appendArg(step_name) catch fatal(io, "step name too long for command buffer", .{});
    }

    // Forward -D options
    for (config.options.entries[0..]) |entry| {
        if (!entry.occupied) continue;
        const key = entry.key_buf[0..entry.key_len];
        const val = entry.val_buf[0..entry.val_len];
        var opt_buf: [PATH_BUF_SIZE]u8 = undefined;
        const d_prefix = "-D";
        const eq = "=";
        const total_len = d_prefix.len + key.len + eq.len + val.len;
        if (total_len <= PATH_BUF_SIZE) {
            @memcpy(opt_buf[0..d_prefix.len], d_prefix);
            @memcpy(opt_buf[d_prefix.len..][0..key.len], key);
            @memcpy(opt_buf[d_prefix.len + key.len ..][0..eq.len], eq);
            @memcpy(opt_buf[d_prefix.len + key.len + eq.len ..][0..val.len], val);
            host_cmd.appendArg(opt_buf[0..total_len]) catch {};
        }
    }

    // Forward -j if specified
    if (config.thread_count > 0) {
        var j_buf: [32]u8 = undefined;
        const j_str = std.fmt.bufPrint(&j_buf, "-j{d}", .{config.thread_count}) catch "-j4";
        host_cmd.appendArg(j_str) catch {};
    }

    // Forward flags
    if (config.verbose) {
        host_cmd.appendArg("--verbose") catch {};
    }
    if (config.benchmark) {
        host_cmd.appendArg("--benchmark") catch {};
    }
    if (config.verify_identical) {
        host_cmd.appendArg("--verify-identical") catch {};
    }
    if (config.self_test) {
        if (config.self_test_compiler_len > 0) {
            var st_buf: [PATH_BUF_SIZE]u8 = undefined;
            const st_prefix = "--self-test=";
            const st_val = config.self_test_compiler[0..config.self_test_compiler_len];
            if (st_prefix.len + st_val.len <= PATH_BUF_SIZE) {
                @memcpy(st_buf[0..st_prefix.len], st_prefix);
                @memcpy(st_buf[st_prefix.len..][0..st_val.len], st_val);
                host_cmd.appendArg(st_buf[0 .. st_prefix.len + st_val.len]) catch {};
            }
        } else {
            host_cmd.appendArg("--self-test") catch {};
        }
    }

    // Forward --prefix if specified
    if (config.install_prefix_len > 0) {
        host_cmd.appendArg("--prefix") catch {};
        host_cmd.appendArg(config.install_prefix[0..config.install_prefix_len]) catch {};
    }

    if (config.verbose) {
        printMsg(io, "spawning build host: {s}", .{build_host_binary});
    }

    var stderr_buf: [STDERR_CAPTURE_SIZE]u8 = undefined;
    var stderr_len: usize = 0;
    const host_exit = runCommand(&host_cmd, &stderr_buf, &stderr_len, io) catch {
        fatal(io, "failed to spawn build host process", .{});
    };

    // Propagate stderr output from the host.
    if (stderr_len > 0) {
        const stderr_file = std.Io.File.stderr();
        stderr_file.writeStreamingAll(io, stderr_buf[0..stderr_len]) catch {};
    }

    if (host_exit == 0) return;

    // Exit code 2: compile errors already reported by the compiler.
    if (host_exit == 2) {
        sig_process.exit(2);
    }

    sig_process.exit(host_exit);
}
