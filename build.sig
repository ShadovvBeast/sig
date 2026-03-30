/// Sig Build Configuration
///
/// This file is evaluated by the Sig Build Runner (`tools/sig_build/main.sig`).
/// It registers all Sig-specific build steps using the Build_Runner API —
/// no `std.Build`, no allocators. All string formatting uses stack buffers
/// and `sig.fmt.formatInto`. All path operations use `sig.fs.joinPath`.
///
/// Steps registered:
///   - test-sig:    Run Sig property-based and unit tests
///   - bench-sig:   Run Sig benchmark suite
///   - run-sig-*:   Run individual Sig tools (sig_sync, sig_readme, etc.)
///   - sig:         Compile the Sig compiler binary
///   - install-lib: Install lib/ files to output directory
const std = @import("std");
const sig = @import("sig");
const sig_build = @import("sig_build");

// ── Build Runner type aliases ───────────────────────────────────────────
const Build_Context = sig_build.Build_Context;
const SigError = sig_build.SigError;
const StepFn = sig_build.StepFn;
const Step_Handle = sig_build.Step_Handle;
const Module_Handle = sig_build.Module_Handle;
const Step_Context = sig_build.Step_Context;
const Import_Entry = sig_build.Import_Entry;
const Compile_Options = sig_build.Compile_Options;
const Test_Options = sig_build.Test_Options;
const Install_Options = sig_build.Install_Options;

// ── Sig module aliases ──────────────────────────────────────────────────
const sig_fmt = sig.fmt;
const sig_fs = sig.fs;
const sig_string = sig.string;

// ── Capacity constants ──────────────────────────────────────────────────
const PATH_BUF_SIZE = 4096;
const NAME_BUF_SIZE = 64;
const MAX_DIR_ENTRIES = 128;
const MAX_DISCOVERED_FILES = 64;
const MAX_DISCOVERED_MODULES = 64;
const MAX_TOOLS = 16;
const MAX_TOOL_EXTRAS = 8;
const MAX_IMPORTS = 64;

// ── Discovered file/module types ────────────────────────────────────────
const DiscoveredFile = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    path: [PATH_BUF_SIZE]u8 = undefined,
    path_len: usize = 0,
};

const DiscoveredModule = struct {
    name: [NAME_BUF_SIZE]u8 = undefined,
    name_len: usize = 0,
    path: [PATH_BUF_SIZE]u8 = undefined,
    path_len: usize = 0,
};

const DiscoveredTool = struct {
    dir_name: [NAME_BUF_SIZE]u8 = undefined,
    dir_name_len: usize = 0,
    step_name: [NAME_BUF_SIZE]u8 = undefined,
    step_name_len: usize = 0,
    main_path: [PATH_BUF_SIZE]u8 = undefined,
    main_path_len: usize = 0,
    extra_sources: [MAX_TOOL_EXTRAS]DiscoveredModule = undefined,
    extra_count: usize = 0,
};

// ── Placeholder step function ───────────────────────────────────────────
/// All steps use this no-op make function. Actual execution is handled
/// by the Build_Runner scheduler which reconstructs commands from the
/// step/module registry metadata.
fn noopStepFn(_: *Step_Context) SigError!void {}

// ── Entry point ─────────────────────────────────────────────────────────

pub fn build(ctx: *Build_Context) SigError!void {
    // ── Options ──────────────────────────────────────────────────────
    const optimize = ctx.option(sig_build.Optimize_Mode, "optimize", "Optimization mode") orelse .Debug;
    _ = optimize;

    // ── Discover Sig modules, test files, bench files, tools ─────────
    var sig_modules: [MAX_DISCOVERED_MODULES]DiscoveredModule = undefined;
    var sig_module_count: usize = 0;
    discoverSigModules(ctx.io_ctx, &sig_modules, &sig_module_count);

    var sig_pbt_files: [MAX_DISCOVERED_FILES]DiscoveredFile = undefined;
    var sig_pbt_count: usize = 0;
    discoverFiles(ctx.io_ctx, "test/sig_pbt", "_properties", ".sig", &sig_pbt_files, &sig_pbt_count);

    var sig_unit_files: [MAX_DISCOVERED_FILES]DiscoveredFile = undefined;
    var sig_unit_count: usize = 0;
    discoverFiles(ctx.io_ctx, "test/sig_unit", "_test", ".sig", &sig_unit_files, &sig_unit_count);

    var sig_bench_files: [MAX_DISCOVERED_FILES]DiscoveredFile = undefined;
    var sig_bench_count: usize = 0;
    discoverFiles(ctx.io_ctx, "test/sig_bench", "_bench", ".sig", &sig_bench_files, &sig_bench_count);

    var sig_tools: [MAX_TOOLS]DiscoveredTool = undefined;
    var sig_tool_count: usize = 0;
    discoverSigTools(ctx.io_ctx, &sig_tools, &sig_tool_count);

    // ── Register the "sig" module in the module registry ─────────────
    // Find the main "sig" module path from discovered modules
    var sig_mod_handle: ?Module_Handle = null;
    for (sig_modules[0..sig_module_count]) |m| {
        const mname = m.name[0..m.name_len];
        if (std.mem.eql(u8, mname, "sig")) {
            sig_mod_handle = try ctx.addModule("sig", m.path[0..m.path_len]);
            break;
        }
    }

    // Register all other discovered modules
    for (sig_modules[0..sig_module_count]) |m| {
        const mname = m.name[0..m.name_len];
        if (std.mem.eql(u8, mname, "sig")) continue; // already registered
        _ = ctx.addModule(mname, m.path[0..m.path_len]) catch |err| switch (err) {
            error.CapacityExceeded => {
                // Duplicate name — skip silently
                if (ctx.modules.findByName(mname) == null) return err;
            },
            else => return err,
        };
    }

    // ── test-sig step ────────────────────────────────────────────────
    const test_sig_handle = try ctx.addStep("test-sig", "Run Sig property and unit tests", &noopStepFn);

    // Build import entries for test modules (sig + harness + all modules)
    var test_imports: [MAX_IMPORTS]Import_Entry = undefined;
    var test_import_count: usize = 0;
    buildTestImports(&sig_modules, sig_module_count, &sig_tools, sig_tool_count, true, &test_imports, &test_import_count);

    // Register PBT tests
    for (sig_pbt_files[0..sig_pbt_count]) |file| {
        const pbt_handle = try ctx.addTestStep(.{
            .source_path = file.path[0..file.path_len],
            .name = file.name[0..file.name_len],
            .imports = test_imports[0..test_import_count],
        });
        try ctx.addDependency(test_sig_handle, pbt_handle);
    }

    // Register unit tests
    for (sig_unit_files[0..sig_unit_count]) |file| {
        const unit_handle = try ctx.addTestStep(.{
            .source_path = file.path[0..file.path_len],
            .name = file.name[0..file.name_len],
            .imports = test_imports[0..test_import_count],
        });
        try ctx.addDependency(test_sig_handle, unit_handle);
    }

    // ── bench-sig step ───────────────────────────────────────────────
    const bench_sig_handle = try ctx.addStep("bench-sig", "Run Sig benchmark suite", &noopStepFn);

    // Bench imports: only the "sig" module
    var bench_imports: [1]Import_Entry = undefined;
    var bench_import_count: usize = 0;
    for (sig_modules[0..sig_module_count]) |m| {
        const mname = m.name[0..m.name_len];
        if (std.mem.eql(u8, mname, "sig")) {
            var entry: Import_Entry = .{};
            @memcpy(entry.name[0..mname.len], mname);
            entry.name_len = mname.len;
            const mpath = m.path[0..m.path_len];
            @memcpy(entry.path[0..mpath.len], mpath);
            entry.path_len = mpath.len;
            bench_imports[0] = entry;
            bench_import_count = 1;
            break;
        }
    }

    for (sig_bench_files[0..sig_bench_count]) |file| {
        const bench_handle = try ctx.addCompileStep(.{
            .source_path = file.path[0..file.path_len],
            .output_name = file.name[0..file.name_len],
            .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
            .optimize = .ReleaseFast,
            .target = null,
            .imports = bench_imports[0..bench_import_count],
            .compiler_path = "",
        });
        try ctx.addDependency(bench_sig_handle, bench_handle);
    }

    // ── run-sig-* tool steps ─────────────────────────────────────────
    for (sig_tools[0..sig_tool_count]) |tool| {
        const tool_dir_name = tool.dir_name[0..tool.dir_name_len];
        const tool_step_name = tool.step_name[0..tool.step_name_len];
        const tool_main_path = tool.main_path[0..tool.main_path_len];

        // Build description: "Run {dir_name} tool"
        var desc_buf: [256]u8 = undefined;
        const desc_slice = sig_fmt.formatInto(&desc_buf, "Run {s} tool", .{tool_dir_name}) catch blk: {
            const fallback = "Run sig tool";
            @memcpy(desc_buf[0..fallback.len], fallback);
            break :blk desc_buf[0..fallback.len];
        };

        // Build imports for this tool: sig + tool extras
        var tool_imports: [MAX_TOOL_EXTRAS + 1]Import_Entry = undefined;
        var tool_import_count: usize = 0;

        // Add sig import
        for (sig_modules[0..sig_module_count]) |m| {
            const mname = m.name[0..m.name_len];
            if (std.mem.eql(u8, mname, "sig")) {
                var entry: Import_Entry = .{};
                @memcpy(entry.name[0..mname.len], mname);
                entry.name_len = mname.len;
                const mpath = m.path[0..m.path_len];
                @memcpy(entry.path[0..mpath.len], mpath);
                entry.path_len = mpath.len;
                tool_imports[tool_import_count] = entry;
                tool_import_count += 1;
                break;
            }
        }

        // Add tool-specific extras
        for (tool.extra_sources[0..tool.extra_count]) |extra| {
            if (tool_import_count >= tool_imports.len) break;
            var entry: Import_Entry = .{};
            const ename = extra.name[0..extra.name_len];
            @memcpy(entry.name[0..ename.len], ename);
            entry.name_len = ename.len;
            const epath = extra.path[0..extra.path_len];
            @memcpy(entry.path[0..epath.len], epath);
            entry.path_len = epath.len;
            tool_imports[tool_import_count] = entry;
            tool_import_count += 1;
        }

        // Register as a compile step (executable)
        const tool_compile = try ctx.addCompileStep(.{
            .source_path = tool_main_path,
            .output_name = tool_dir_name,
            .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
            .optimize = .Debug,
            .target = null,
            .imports = tool_imports[0..tool_import_count],
            .compiler_path = "",
        });

        // Register the run step that depends on the compile step
        const run_handle = try ctx.addStep(tool_step_name, desc_slice, &noopStepFn);
        try ctx.addDependency(run_handle, tool_compile);
    }

    // ── Compile step: main sig compiler ──────────────────────────────
    // Build imports for the compiler (sig module + aro)
    var compiler_imports: [2]Import_Entry = undefined;
    var compiler_import_count: usize = 0;

    // Add aro import
    {
        var entry: Import_Entry = .{};
        const aro_name = "aro";
        @memcpy(entry.name[0..aro_name.len], aro_name);
        entry.name_len = aro_name.len;
        const aro_path = "lib/compiler/aro/aro.zig";
        @memcpy(entry.path[0..aro_path.len], aro_path);
        entry.path_len = aro_path.len;
        compiler_imports[compiler_import_count] = entry;
        compiler_import_count += 1;
    }

    _ = try ctx.addCompileStep(.{
        .source_path = "src/main.zig",
        .output_name = "sig",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = .Debug,
        .target = null,
        .imports = compiler_imports[0..compiler_import_count],
        .compiler_path = "",
    });

    // ── Install step: lib files ──────────────────────────────────────
    _ = try ctx.addInstallStep(.{
        .source_dir = "lib",
        .dest_dir = "lib",
    });

    // ── rebuild-self step: rebuild the build runner ──────────────────
    // Registers a compile step for tools/sig_build/main.sig with the sig
    // module import, allowing `sig build rebuild-self` to rebuild the
    // build runner itself (self-hosting).
    {
        var rebuild_imports: [1]Import_Entry = undefined;
        var rebuild_import_count: usize = 0;

        // Add the sig module import.
        for (sig_modules[0..sig_module_count]) |m| {
            const mname = m.name[0..m.name_len];
            if (std.mem.eql(u8, mname, "sig")) {
                var entry: Import_Entry = .{};
                @memcpy(entry.name[0..mname.len], mname);
                entry.name_len = mname.len;
                const mpath = m.path[0..m.path_len];
                @memcpy(entry.path[0..mpath.len], mpath);
                entry.path_len = mpath.len;
                rebuild_imports[0] = entry;
                rebuild_import_count = 1;
                break;
            }
        }

        const rebuild_compile = try ctx.addCompileStep(.{
            .source_path = "tools/sig_build/main.sig",
            .output_name = "sig-build",
            .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
            .optimize = .Debug,
            .target = null,
            .imports = rebuild_imports[0..rebuild_import_count],
            .compiler_path = "",
        });

        const rebuild_self_handle = try ctx.addStep("rebuild-self", "Rebuild the sig build runner (self-hosting)", &noopStepFn);
        try ctx.addDependency(rebuild_self_handle, rebuild_compile);
    }
}


// ── Discovery helpers ───────────────────────────────────────────────────
// These replace the std.Build-based discovery functions from the old build.sig.
// They use sig.fs.listDir for directory scanning and stack buffers for all
// string operations.

/// Scan lib/sig/ for *.zig files and add src/sig_diagnostics*.zig modules.
/// Populates the caller-provided array with discovered modules.
fn discoverSigModules(io: std.Io, out: []DiscoveredModule, out_count: *usize) void {
    var entries: [MAX_DIR_ENTRIES]sig_fs.DirEntry = undefined;
    const dir_entries = sig_fs.listDir(io, "lib/sig", &entries) catch {
        // Directory doesn't exist — graceful degradation
        return;
    };

    // Names that don't get a "sig_" prefix
    const no_prefix = [_][]const u8{ "sig", "fmt", "containers", "errors" };

    for (dir_entries) |entry| {
        if (entry.kind != .file) continue;
        const ename = entry.name();
        if (!std.mem.endsWith(u8, ename, ".zig")) continue;

        // Extract stem (filename without .zig extension)
        const stem = ename[0 .. ename.len - 4]; // strip ".zig"

        if (out_count.* >= out.len) return; // capacity reached

        var mod = &out[out_count.*];
        mod.* = .{};

        // Determine import name: no prefix for sig/fmt/containers/errors
        var needs_prefix = true;
        for (no_prefix) |np| {
            if (std.mem.eql(u8, stem, np)) {
                needs_prefix = false;
                break;
            }
        }

        if (needs_prefix) {
            // "sig_" + stem
            const prefix = "sig_";
            const total_name = prefix.len + stem.len;
            if (total_name <= NAME_BUF_SIZE) {
                @memcpy(mod.name[0..prefix.len], prefix);
                @memcpy(mod.name[prefix.len..][0..stem.len], stem);
                mod.name_len = total_name;
            }
        } else {
            if (stem.len <= NAME_BUF_SIZE) {
                @memcpy(mod.name[0..stem.len], stem);
                mod.name_len = stem.len;
            }
        }

        // Build path: "lib/sig/{entry.name}"
        var path_buf: [PATH_BUF_SIZE]u8 = undefined;
        const segments = [_][]const u8{ "lib/sig", ename };
        const joined = sig_fs.joinPath(&path_buf, &segments) catch continue;
        if (joined.len <= PATH_BUF_SIZE) {
            @memcpy(mod.path[0..joined.len], joined);
            mod.path_len = joined.len;
        }

        out_count.* += 1;
    }

    // Add src/sig_diagnostics.zig
    if (out_count.* < out.len) {
        var mod = &out[out_count.*];
        mod.* = .{};
        const dname = "sig_diagnostics";
        @memcpy(mod.name[0..dname.len], dname);
        mod.name_len = dname.len;
        const dpath = "src/sig_diagnostics.zig";
        @memcpy(mod.path[0..dpath.len], dpath);
        mod.path_len = dpath.len;
        out_count.* += 1;
    }

    // Add src/sig_diagnostics_integration.zig
    if (out_count.* < out.len) {
        var mod = &out[out_count.*];
        mod.* = .{};
        const iname = "sig_diagnostics_integration";
        @memcpy(mod.name[0..iname.len], iname);
        mod.name_len = iname.len;
        const ipath = "src/sig_diagnostics_integration.zig";
        @memcpy(mod.path[0..ipath.len], ipath);
        mod.path_len = ipath.len;
        out_count.* += 1;
    }
}

/// Generic file scanner for test/bench directories.
/// Scans `dir_path` for files ending with `suffix` + `ext`.
/// Derives name by stripping the extension.
fn discoverFiles(
    io: std.Io,
    dir_path: []const u8,
    suffix: []const u8,
    ext: []const u8,
    out: []DiscoveredFile,
    out_count: *usize,
) void {
    var entries: [MAX_DIR_ENTRIES]sig_fs.DirEntry = undefined;
    const dir_entries = sig_fs.listDir(io, dir_path, &entries) catch {
        return; // Directory doesn't exist — graceful degradation
    };

    for (dir_entries) |entry| {
        if (entry.kind != .file) continue;
        const ename = entry.name();
        if (!std.mem.endsWith(u8, ename, ext)) continue;

        // Check that the name (without ext) ends with the suffix
        const name_without_ext = ename[0 .. ename.len - ext.len];
        if (!std.mem.endsWith(u8, name_without_ext, suffix)) continue;

        if (out_count.* >= out.len) return; // capacity reached

        var file = &out[out_count.*];
        file.* = .{};

        // Derive name by stripping the extension
        if (name_without_ext.len <= NAME_BUF_SIZE) {
            @memcpy(file.name[0..name_without_ext.len], name_without_ext);
            file.name_len = name_without_ext.len;
        }

        // Build full path: "{dir_path}/{entry.name}"
        var path_buf: [PATH_BUF_SIZE]u8 = undefined;
        const segments = [_][]const u8{ dir_path, ename };
        const joined = sig_fs.joinPath(&path_buf, &segments) catch continue;
        if (joined.len <= PATH_BUF_SIZE) {
            @memcpy(file.path[0..joined.len], joined);
            file.path_len = joined.len;
        }

        out_count.* += 1;
    }
}

/// Scan tools/ for subdirectories matching sig_* that contain a main.sig.
/// Derives step name by replacing '_' with '-' and prepending "run-".
/// Also discovers extra .sig files per tool as tool-specific imports.
fn discoverSigTools(io: std.Io, out: []DiscoveredTool, out_count: *usize) void {
    var entries: [MAX_DIR_ENTRIES]sig_fs.DirEntry = undefined;
    const dir_entries = sig_fs.listDir(io, "tools", &entries) catch {
        return; // Directory doesn't exist
    };

    for (dir_entries) |entry| {
        if (entry.kind != .directory) continue;
        const ename = entry.name();
        if (!std.mem.startsWith(u8, ename, "sig_")) continue;

        // Check if main.sig exists inside by building the path and probing
        var main_path_buf: [PATH_BUF_SIZE]u8 = undefined;
        const main_segments = [_][]const u8{ "tools", ename, "main.sig" };
        const main_path = sig_fs.joinPath(&main_path_buf, &main_segments) catch continue;

        // Probe: try to open the file to verify it exists
        const cwd: std.Io.Dir = .cwd();
        var probe_file = cwd.openFile(io, main_path, .{}) catch continue;
        probe_file.close(io);

        if (out_count.* >= out.len) return; // capacity reached

        var tool = &out[out_count.*];
        tool.* = .{};

        // Store dir_name
        if (ename.len <= NAME_BUF_SIZE) {
            @memcpy(tool.dir_name[0..ename.len], ename);
            tool.dir_name_len = ename.len;
        }

        // Store main_path
        if (main_path.len <= PATH_BUF_SIZE) {
            @memcpy(tool.main_path[0..main_path.len], main_path);
            tool.main_path_len = main_path.len;
        }

        // Derive step name: "run-" + dir_name with '_' replaced by '-'
        const prefix = "run-";
        const step_len = prefix.len + ename.len;
        if (step_len <= NAME_BUF_SIZE) {
            @memcpy(tool.step_name[0..prefix.len], prefix);
            @memcpy(tool.step_name[prefix.len..][0..ename.len], ename);
            // Replace '_' with '-' in the full step name
            for (tool.step_name[0..step_len]) |*c| {
                if (c.* == '_') c.* = '-';
            }
            tool.step_name_len = step_len;
        }

        // Discover extra .sig files in the tool directory
        var tool_dir_path_buf: [PATH_BUF_SIZE]u8 = undefined;
        const tool_dir_segments = [_][]const u8{ "tools", ename };
        const tool_dir_path = sig_fs.joinPath(&tool_dir_path_buf, &tool_dir_segments) catch {
            out_count.* += 1;
            continue;
        };

        var sub_entries: [MAX_DIR_ENTRIES]sig_fs.DirEntry = undefined;
        const sub_dir_entries = sig_fs.listDir(io, tool_dir_path, &sub_entries) catch {
            out_count.* += 1;
            continue;
        };

        tool.extra_count = 0;
        for (sub_dir_entries) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            const sub_name = sub_entry.name();
            if (!std.mem.endsWith(u8, sub_name, ".sig")) continue;
            if (std.mem.eql(u8, sub_name, "main.sig")) continue;

            if (tool.extra_count >= MAX_TOOL_EXTRAS) break;

            var extra = &tool.extra_sources[tool.extra_count];
            extra.* = .{};

            // Import name = "sig_" + stem
            const stem = sub_name[0 .. sub_name.len - 4]; // strip ".sig"
            const imp_prefix = "sig_";
            const imp_name_len = imp_prefix.len + stem.len;
            if (imp_name_len <= NAME_BUF_SIZE) {
                @memcpy(extra.name[0..imp_prefix.len], imp_prefix);
                @memcpy(extra.name[imp_prefix.len..][0..stem.len], stem);
                extra.name_len = imp_name_len;
            }

            // Build path: "tools/{dir_name}/{sub_name}"
            var extra_path_buf: [PATH_BUF_SIZE]u8 = undefined;
            const extra_segments = [_][]const u8{ "tools", ename, sub_name };
            const extra_path = sig_fs.joinPath(&extra_path_buf, &extra_segments) catch continue;
            if (extra_path.len <= PATH_BUF_SIZE) {
                @memcpy(extra.path[0..extra_path.len], extra_path);
                extra.path_len = extra_path.len;
            }

            tool.extra_count += 1;
        }

        out_count.* += 1;
    }
}

/// Build the import entries array for test steps.
/// Includes: all sig modules, harness (if requested), tool mains, tool extras.
fn buildTestImports(
    modules: []const DiscoveredModule,
    module_count: usize,
    tools: []const DiscoveredTool,
    tool_count: usize,
    include_harness: bool,
    out: []Import_Entry,
    out_count: *usize,
) void {
    // Add all discovered modules as imports
    for (modules[0..module_count]) |m| {
        if (out_count.* >= out.len) return;
        var entry = &out[out_count.*];
        entry.* = .{};
        const mname = m.name[0..m.name_len];
        @memcpy(entry.name[0..mname.len], mname);
        entry.name_len = mname.len;
        const mpath = m.path[0..m.path_len];
        @memcpy(entry.path[0..mpath.len], mpath);
        entry.path_len = mpath.len;
        out_count.* += 1;
    }

    // Add harness import
    if (include_harness) {
        if (out_count.* < out.len) {
            var entry = &out[out_count.*];
            entry.* = .{};
            const hname = "harness";
            @memcpy(entry.name[0..hname.len], hname);
            entry.name_len = hname.len;
            const hpath = "test/sig_pbt/harness.sig";
            @memcpy(entry.path[0..hpath.len], hpath);
            entry.path_len = hpath.len;
            out_count.* += 1;
        }
    }

    // Add tool main files as imports (e.g., sig_sync, sig_readme)
    for (tools[0..tool_count]) |tool| {
        if (out_count.* >= out.len) return;
        var entry = &out[out_count.*];
        entry.* = .{};
        const tname = tool.dir_name[0..tool.dir_name_len];
        @memcpy(entry.name[0..tname.len], tname);
        entry.name_len = tname.len;
        const tpath = tool.main_path[0..tool.main_path_len];
        @memcpy(entry.path[0..tpath.len], tpath);
        entry.path_len = tpath.len;
        out_count.* += 1;
    }

    // Add tool extras as imports
    for (tools[0..tool_count]) |tool| {
        for (tool.extra_sources[0..tool.extra_count]) |extra| {
            if (out_count.* >= out.len) return;
            var entry = &out[out_count.*];
            entry.* = .{};
            const ename = extra.name[0..extra.name_len];
            @memcpy(entry.name[0..ename.len], ename);
            entry.name_len = ename.len;
            const epath = extra.path[0..extra.path_len];
            @memcpy(entry.path[0..epath.len], epath);
            entry.path_len = epath.len;
            out_count.* += 1;
        }
    }
}
