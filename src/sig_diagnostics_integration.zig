const std = @import("std");
const sig_diag = @import("sig_diagnostics");

pub const Classification = sig_diag.Classification;
pub const DiagnosticEntry = sig_diag.DiagnosticEntry;
pub const Mode = sig_diag.Mode;

/// Exit codes returned by the CLI entry point.
pub const ExitCode = enum(u8) {
    success = 0,
    diagnostics_found = 1,
    usage_error = 2,
};

/// Result of running diagnostics across one or more source files.
pub const DiagnosticsResult = struct {
    entries: []sig_diag.DiagnosticEntry,
    total_warnings: usize,
    total_errors: usize,
    mode: Mode,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DiagnosticsResult) void {
        sig_diag.freeEntries(self.allocator, self.entries);
    }
};

/// Reads the sig-mode from the SIG_MODE environment variable.
/// Returns `.default` if unset or unrecognised.
pub fn readModeFromEnv() Mode {
    const val = std.posix.getenv("SIG_MODE") orelse return .default;
    if (std.mem.eql(u8, val, "strict")) return .strict;
    return .default;
}

/// Parses a mode string ("default" or "strict") into a Mode enum.
/// Returns `.default` for any unrecognised value.
pub fn parseMode(value: []const u8) Mode {
    if (std.mem.eql(u8, value, "strict")) return .strict;
    return .default;
}

/// Runs diagnostics on a single source file.
/// Caller owns the returned result and must call `deinit` on it.
pub fn analyzeFile(
    gpa: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    mode: Mode,
) !DiagnosticsResult {
    const entries = try sig_diag.analyzeSource(gpa, source, file_path, mode);
    var warnings: usize = 0;
    var errors: usize = 0;
    switch (mode) {
        .default => warnings = entries.len,
        .strict => errors = entries.len,
    }
    return .{
        .entries = entries,
        .total_warnings = warnings,
        .total_errors = errors,
        .mode = mode,
        .allocator = gpa,
    };
}

/// Runs diagnostics on multiple source files read from disk.
/// Returns a combined result. Caller owns the result and must call `deinit`.
pub fn analyzeFiles(
    gpa: std.mem.Allocator,
    file_paths: []const []const u8,
    mode: Mode,
) !DiagnosticsResult {
    var all_entries: std.ArrayList(DiagnosticEntry) = .empty;
    errdefer {
        for (all_entries.items) |e| {
            if (e.call_path) |cp| gpa.free(cp);
        }
        all_entries.deinit(gpa);
    }

    for (file_paths) |path| {
        const source = std.fs.cwd().readFileAlloc(gpa, path, 10 * 1024 * 1024) catch |err| {
            std.debug.print("sig-diagnostics: cannot read '{s}': {}\n", .{ path, err });
            continue;
        };
        defer gpa.free(source);

        const entries = try sig_diag.analyzeSource(gpa, source, path, mode);
        try all_entries.appendSlice(gpa, entries);
        // Free the slice container but not the entries themselves (now owned by all_entries).
        gpa.free(entries);
    }

    const owned = try all_entries.toOwnedSlice(gpa);
    var warnings: usize = 0;
    var errors: usize = 0;
    switch (mode) {
        .default => warnings = owned.len,
        .strict => errors = owned.len,
    }
    return .{
        .entries = owned,
        .total_warnings = warnings,
        .total_errors = errors,
        .mode = mode,
        .allocator = gpa,
    };
}

/// Formats all diagnostic entries and writes them to the provided writer.
/// Returns the number of diagnostics emitted.
pub fn emitDiagnostics(
    gpa: std.mem.Allocator,
    result: DiagnosticsResult,
    writer: *std.Io.Writer,
) !usize {
    for (result.entries) |entry| {
        const msg = try sig_diag.formatDiagnostic(gpa, entry, result.mode);
        defer gpa.free(msg);
        try writer.print("{s}\n", .{msg});
    }
    return result.entries.len;
}

/// Determines the appropriate exit code based on the diagnostics result.
pub fn exitCodeForResult(result: DiagnosticsResult) ExitCode {
    if (result.mode == .strict and result.total_errors > 0) return .diagnostics_found;
    return .success;
}

// ──────────────────────────────────────────────
//  CLI entry point
// ──────────────────────────────────────────────

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        std.debug.print("Usage: sig-diagnostics [--mode default|strict] <file>...\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Parse arguments.
    var mode: Mode = readModeFromEnv();
    var file_paths: std.ArrayList([]const u8) = .empty;
    defer file_paths.deinit(gpa);

    var i: usize = 1; // skip argv[0]
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--mode")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --mode requires a value (default|strict)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            mode = parseMode(args[i]);
        } else {
            try file_paths.append(gpa, args[i]);
        }
    }

    if (file_paths.items.len == 0) {
        std.debug.print("Error: no source files specified\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    var result = try analyzeFiles(gpa, file_paths.items, mode);
    defer result.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(undefined, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    _ = try emitDiagnostics(gpa, result, stdout);
    try stdout.flush();

    const code = exitCodeForResult(result);
    if (code != .success) {
        std.process.exit(@intFromEnum(code));
    }
}

// ──────────────────────────────────────────────
//  Build integration documentation
// ──────────────────────────────────────────────

// The sig-mode build option should be added to build.zig as follows
// (actual modification deferred to task 16.1):
//
//   const sig_mode = b.option(
//       enum { default, strict },
//       "sig-mode",
//       "Sig diagnostic mode: default emits warnings, strict emits errors",
//   ) orelse .default;
//
// Then pass it to compilation options:
//
//   exe_options.addOption(@TypeOf(sig_mode), "sig_mode", sig_mode);
//
// The sig-diagnostics integration can be invoked as a post-build step:
//
//   const diag_step = b.addRunArtifact(sig_diag_exe);
//   diag_step.addArg("--mode");
//   diag_step.addArg(if (sig_mode == .strict) "strict" else "default");
//   diag_step.addArgs(source_files);
//   build_step.dependOn(&diag_step.step);
