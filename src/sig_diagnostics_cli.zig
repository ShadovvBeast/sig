const std = @import("std");
const sig_diag = @import("sig_diagnostics");
const Writer = std.Io.Writer;

pub const Mode = sig_diag.Mode;
pub const DiagnosticEntry = sig_diag.DiagnosticEntry;

/// Exit codes returned by the CLI.
pub const ExitCode = enum(u8) {
    success = 0,
    diagnostics_found = 1,
    usage_error = 2,
};

/// Parses a mode string into a Mode enum.
pub fn parseMode(value: []const u8) Mode {
    if (std.mem.eql(u8, value, "strict")) return .strict;
    return .default;
}

/// Runs diagnostics on a single source string and writes formatted output.
/// Returns the number of diagnostics emitted.
pub fn runDiagnostics(
    gpa: std.mem.Allocator,
    w: *Writer,
    source: []const u8,
    file_path: []const u8,
    mode: Mode,
) !usize {
    const entries = try sig_diag.analyzeSource(gpa, source, file_path, mode);
    defer sig_diag.freeEntries(gpa, entries);

    for (entries) |entry| {
        const msg = try sig_diag.formatDiagnostic(gpa, entry, mode);
        defer gpa.free(msg);
        try w.writeAll(msg);
        try w.writeAll("\n");
    }
    return entries.len;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        printUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Parse arguments: [--mode default|strict] <file>...
    var mode: Mode = .default;
    var file_paths = std.array_list.Managed([]const u8).init(arena);

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
            try file_paths.append(args[i]);
        }
    }

    if (file_paths.items.len == 0) {
        std.debug.print("Error: no source files specified\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var total_diagnostics: usize = 0;

    for (file_paths.items) |path| {
        const source = readFileToString(arena, io, path) catch |err| {
            std.debug.print("sig-diagnostics: cannot read '{s}': {}\n", .{ path, err });
            continue;
        };
        total_diagnostics += try runDiagnostics(arena, stdout, source, path, mode);
    }

    try stdout.flush();

    // In strict mode, return non-zero if any diagnostics found
    if (mode == .strict and total_diagnostics > 0) {
        std.process.exit(@intFromEnum(ExitCode.diagnostics_found));
    }
}

fn readFileToString(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024));
}

fn printUsage() void {
    std.debug.print("Usage: sig-diagnostics [--mode default|strict] <file>...\n", .{});
}
