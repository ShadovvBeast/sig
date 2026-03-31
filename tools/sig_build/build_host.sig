/// Build Host — compiled with build.sig wired as @import("build").
///
/// This is the entry point for executing a user's build.sig. The build runner
/// (main.sig) compiles this file with:
///   --mod build:<path/to/build.sig>
///   --mod sig_build:<path/to/main.sig>
///   --mod sig:<path/to/sig.zig>
///   --mod std:<path/to/std.zig>
///
/// The host creates a Build_Context, calls build.sig's build function,
/// validates requested steps, and runs the scheduler.
const std = @import("std");
const sig = @import("sig");
const sig_build = @import("sig_build");
const build_mod = @import("build");
const builtin = @import("builtin");

const containers = sig.containers;
const sig_fs = sig.fs;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // ── 1. Parse argv: fixed positional args [0..6) + user args [6..] ───
    var runner_args: sig_build.Runner_Args = .{};
    var config: sig_build.Cli_Config = .{};

    var args_it = try init.minimal.args.iterateAllocator(init.gpa);
    defer args_it.deinit();

    var arg_count: usize = 0;

    // argv[0]: host binary path
    if (args_it.next()) |arg| {
        if (arg.len > sig_build.PATH_BUF_SIZE) sig_build.fatal(io, "argv[0] path too long", .{});
        @memcpy(runner_args.runner_binary[0..arg.len], arg);
        runner_args.runner_binary_len = arg.len;
        arg_count += 1;
    }

    // argv[1]: sig compiler path
    if (args_it.next()) |arg| {
        if (arg.len > sig_build.PATH_BUF_SIZE) sig_build.fatal(io, "argv[1] path too long", .{});
        @memcpy(runner_args.compiler_path[0..arg.len], arg);
        runner_args.compiler_path_len = arg.len;
        arg_count += 1;
    }

    // argv[2]: zig lib directory
    if (args_it.next()) |arg| {
        if (arg.len > sig_build.PATH_BUF_SIZE) sig_build.fatal(io, "argv[2] path too long", .{});
        @memcpy(runner_args.zig_lib_dir[0..arg.len], arg);
        runner_args.zig_lib_dir_len = arg.len;
        arg_count += 1;
    }

    // argv[3]: build root directory
    if (args_it.next()) |arg| {
        if (arg.len > sig_build.PATH_BUF_SIZE) sig_build.fatal(io, "argv[3] path too long", .{});
        @memcpy(runner_args.build_root[0..arg.len], arg);
        runner_args.build_root_len = arg.len;
        arg_count += 1;
    }

    // argv[4]: local cache directory
    if (args_it.next()) |arg| {
        if (arg.len > sig_build.PATH_BUF_SIZE) sig_build.fatal(io, "argv[4] path too long", .{});
        @memcpy(runner_args.local_cache_dir[0..arg.len], arg);
        runner_args.local_cache_dir_len = arg.len;
        arg_count += 1;
    }

    // argv[5]: global cache directory
    if (args_it.next()) |arg| {
        if (arg.len > sig_build.PATH_BUF_SIZE) sig_build.fatal(io, "argv[5] path too long", .{});
        @memcpy(runner_args.global_cache_dir[0..arg.len], arg);
        runner_args.global_cache_dir_len = arg.len;
        arg_count += 1;
    }

    if (arg_count < 6) {
        sig_build.fatal(io, "build host requires at least 6 arguments (got {d})", .{arg_count});
    }

    // argv[6..]: user arguments (step names, -D flags, -j, --verbose, etc.)
    while (args_it.next()) |arg| {
        if (arg.len >= 2 and arg[0] == '-' and arg[1] == 'D') {
            sig_build.parseOption(&config.options, arg) catch {
                sig_build.fatal(io, "too many -D options", .{});
            };
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == 'j') {
            if (sig_build.parseThreadCount(arg)) |count| {
                config.thread_count = count;
            } else if (args_it.next()) |next_arg| {
                config.thread_count = std.fmt.parseInt(usize, next_arg, 10) catch {
                    sig_build.fatal(io, "invalid thread count: '{s}'", .{next_arg});
                };
            } else {
                sig_build.fatal(io, "-j requires a thread count argument", .{});
            }
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--benchmark")) {
            config.benchmark = true;
        } else if (std.mem.eql(u8, arg, "--verify-identical")) {
            config.verify_identical = true;
        } else if (std.mem.eql(u8, arg, "--self-test") or std.mem.startsWith(u8, arg, "--self-test=")) {
            config.self_test = true;
            if (sig_build.parseLongOptionValue(arg)) |value| {
                if (value.len > sig_build.PATH_BUF_SIZE) sig_build.fatal(io, "--self-test compiler path too long", .{});
                @memcpy(config.self_test_compiler[0..value.len], value);
                config.self_test_compiler_len = value.len;
            }
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            sig_build.fatal(io, "unknown option: '{s}'", .{arg});
        } else {
            config.requested_steps.push(arg) catch {
                sig_build.fatal(io, "too many step names (max 32)", .{});
            };
        }
    }

    // ── 2. Set up Build_Context ─────────────────────────────────────────
    const build_root = runner_args.build_root[0..runner_args.build_root_len];
    const cache_dir = runner_args.local_cache_dir[0..runner_args.local_cache_dir_len];

    var ctx: sig_build.Build_Context = .{};
    @memcpy(ctx.build_root[0..build_root.len], build_root);
    ctx.build_root_len = build_root.len;
    @memcpy(ctx.cache_dir[0..cache_dir.len], cache_dir);
    ctx.cache_dir_len = cache_dir.len;

    // Install prefix: build_root/zig-out
    {
        var prefix_buf: [sig_build.PATH_BUF_SIZE]u8 = undefined;
        const prefix_segs = [_][]const u8{ build_root, "zig-out" };
        const prefix = sig_fs.joinPath(&prefix_buf, &prefix_segs) catch {
            sig_build.fatal(io, "failed to construct install prefix path", .{});
        };
        @memcpy(ctx.install_prefix[0..prefix.len], prefix);
        ctx.install_prefix_len = prefix.len;
    }

    ctx.options = config.options;
    ctx.io_ctx = io;

    if (sig_build.getOption(sig_build.Optimize_Mode, &ctx.options, "optimize")) |mode| {
        ctx.optimize = mode;
    }
    if (sig_build.getOption([]const u8, &ctx.options, "target")) |triple_str| {
        ctx.target = sig_build.Target_Triple.parse(triple_str) catch {
            sig_build.fatal(io, "invalid target triple: '{s}'", .{triple_str});
        };
    }

    if (config.verbose) {
        sig_build.printMsg(io, "compiler:   {s}", .{runner_args.compiler_path[0..runner_args.compiler_path_len]});
        sig_build.printMsg(io, "zig lib:    {s}", .{runner_args.zig_lib_dir[0..runner_args.zig_lib_dir_len]});
        sig_build.printMsg(io, "build root: {s}", .{build_root});
        sig_build.printMsg(io, "cache dir:  {s}", .{cache_dir});
    }

    // ── 3. Call build.sig's build function ──────────────────────────────
    build_mod.build(&ctx) catch |err| {
        sig_build.fatal(io, "build.sig build() failed: {t}", .{err});
    };

    if (config.verbose) {
        sig_build.printMsg(io, "build.sig registered {d} steps", .{ctx.steps.count});
    }

    // ── 4. Validate requested step names ────────────────────────────────
    const requested = config.requested_steps.slice();
    for (requested) |step_name| {
        if (ctx.steps.findByName(step_name) == null) {
            var avail_buf: [4096]u8 = undefined;
            var avail_offset: usize = 0;
            for (ctx.steps.entries[0..ctx.steps.count], 0..) |entry, i| {
                if (i > 0 and avail_offset + 2 <= avail_buf.len) {
                    avail_buf[avail_offset] = ',';
                    avail_buf[avail_offset + 1] = ' ';
                    avail_offset += 2;
                }
                const name = entry.name[0..entry.name_len];
                if (avail_offset + name.len <= avail_buf.len) {
                    @memcpy(avail_buf[avail_offset..][0..name.len], name);
                    avail_offset += name.len;
                }
            }
            if (ctx.steps.count == 0) {
                sig_build.fatal(io, "unknown step '{s}' (no steps registered)", .{step_name});
            } else {
                sig_build.fatal(io, "unknown step '{s}'. Available: {s}", .{ step_name, avail_buf[0..avail_offset] });
            }
        }
    }

    // ── 5. Build dependency graph ───────────────────────────────────────
    var graph: sig_build.Dependency_Graph = .{};
    graph.node_count = ctx.steps.count;
    for (ctx.steps.entries[0..ctx.steps.count], 0..) |entry, i| {
        for (entry.deps[0..entry.dep_count]) |dep| {
            graph.addEdge(@intCast(i), dep) catch {
                sig_build.fatal(io, "dependency graph capacity exceeded", .{});
            };
        }
    }

    // ── 6. Topological sort ─────────────────────────────────────────────
    var topo_buf: [sig_build.MAX_STEPS]sig_build.Step_Handle = undefined;
    _ = graph.topologicalSort(&topo_buf) catch {
        var cycle_buf: [sig_build.PATH_BUF_SIZE]u8 = undefined;
        const cycle_path = graph.findCyclePath(&ctx.steps, &cycle_buf);
        sig_build.fatal(io, "dependency cycle detected: {s}", .{cycle_path});
    };

    // ── 7. Load cache ───────────────────────────────────────────────────
    var cache_file_buf: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const cache_file_segs = [_][]const u8{ cache_dir, "cache.bin" };
    const cache_file_path = sig_fs.joinPath(&cache_file_buf, &cache_file_segs) catch {
        sig_build.fatal(io, "failed to construct cache file path", .{});
    };

    var cache: sig_build.Cache_Map = .{};
    cache.load(io, cache_file_path);

    if (config.verbose) {
        sig_build.printMsg(io, "cache loaded: {d} entries", .{cache.count});
    }

    // ── 8. Thread pool ──────────────────────────────────────────────────
    const thread_count: usize = if (config.thread_count > 0)
        @min(config.thread_count, sig_build.MAX_THREADS)
    else
        4;

    var pool: sig_build.Thread_Pool = .{};
    pool.init(thread_count, io);
    defer pool.deinit();

    if (config.verbose) {
        sig_build.printMsg(io, "scheduling {d} steps with {d} threads...", .{ ctx.steps.count, thread_count });
    }

    // ── 9. Run scheduler ────────────────────────────────────────────────
    const sig_start_ns = std.Io.Clock.awake.now(io).nanoseconds;
    const summary = sig_build.runScheduler(&ctx.steps, &graph, &cache, &pool, io, config.verbose);
    const sig_end_ns = std.Io.Clock.awake.now(io).nanoseconds;
    const sig_elapsed_ns: u64 = @intCast(sig_end_ns - sig_start_ns);

    // ── 10. Save cache ──────────────────────────────────────────────────
    cache.save(io, cache_file_path) catch {
        const stderr = std.Io.File.stderr();
        stderr.writeStreamingAll(io, "warning: failed to save cache\n") catch {};
    };

    // ── 11. Print summary and exit ──────────────────────────────────────
    sig_build.printSummary(io, &summary);

    if (config.benchmark) {
        sig_build.runBenchmark(io, build_root, &config, sig_elapsed_ns, &summary);
    }

    if (config.verify_identical) {
        if (!sig_build.verifyIdentical(io, build_root, &config)) {
            std.process.exit(1);
        }
    }

    if (config.self_test) {
        const self_path = runner_args.runner_binary[0..runner_args.runner_binary_len];
        const compiler = if (config.self_test_compiler_len > 0)
            config.self_test_compiler[0..config.self_test_compiler_len]
        else
            runner_args.compiler_path[0..runner_args.compiler_path_len];

        if (!sig_build.verifySelfHosting(io, self_path, compiler)) {
            std.process.exit(1);
        }
    }

    if (summary.failed > 0) {
        std.process.exit(1);
    }
}
