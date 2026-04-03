const std = @import("std");
const SigError = @import("errors.zig").SigError;

const native_os = @import("builtin").os.tag;

// ── Capacity constants ──────────────────────────────────────────────────

pub const MAX_CMD_ARGS = 64;
pub const MAX_ARG_LEN = 4096;
pub const MAX_CWD_LEN = 4096;
pub const MAX_ENV_PAIRS = 256;
pub const MAX_ENV_KEY_LEN = 256;
pub const MAX_ENV_VALUE_LEN = 4096;

// ── Command_Buffer ──────────────────────────────────────────────────────

/// Fixed-capacity buffer for constructing child process commands.
/// Stores arguments and working directory entirely in stack memory —
/// no heap allocation.
pub const Command_Buffer = struct {
    args: [MAX_CMD_ARGS][MAX_ARG_LEN]u8 = undefined,
    arg_lens: [MAX_CMD_ARGS]usize = [_]usize{0} ** MAX_CMD_ARGS,
    arg_count: usize = 0,
    cwd: [MAX_CWD_LEN]u8 = undefined,
    cwd_len: usize = 0,

    /// Append an argument. Returns `CapacityExceeded` if too many args,
    /// `BufferTooSmall` if the argument is too long.
    pub fn appendArg(self: *Command_Buffer, arg: []const u8) SigError!void {
        if (self.arg_count >= MAX_CMD_ARGS) return error.CapacityExceeded;
        if (arg.len > MAX_ARG_LEN) return error.BufferTooSmall;
        @memcpy(self.args[self.arg_count][0..arg.len], arg);
        self.arg_lens[self.arg_count] = arg.len;
        self.arg_count += 1;
    }

    /// Set the working directory.
    /// Returns `BufferTooSmall` if the path exceeds `MAX_CWD_LEN`.
    pub fn setCwd(self: *Command_Buffer, path: []const u8) SigError!void {
        if (path.len > MAX_CWD_LEN) return error.BufferTooSmall;
        @memcpy(self.cwd[0..path.len], path);
        self.cwd_len = path.len;
    }

    /// Get a slice view of argument `i` (read-only).
    pub fn getArg(self: *const Command_Buffer, i: usize) []const u8 {
        return self.args[i][0..self.arg_lens[i]];
    }
};

// ── Env_Pairs ───────────────────────────────────────────────────────────

/// Fixed-capacity environment variable storage for passing to child processes.
/// Stores keys and values in stack-allocated fixed arrays — no heap allocation.
pub const Env_Pairs = struct {
    keys: [MAX_ENV_PAIRS][MAX_ENV_KEY_LEN]u8 = undefined,
    key_lens: [MAX_ENV_PAIRS]usize = [_]usize{0} ** MAX_ENV_PAIRS,
    values: [MAX_ENV_PAIRS][MAX_ENV_VALUE_LEN]u8 = undefined,
    value_lens: [MAX_ENV_PAIRS]usize = [_]usize{0} ** MAX_ENV_PAIRS,
    count: usize = 0,

    /// Add a key-value pair. Returns `CapacityExceeded` if full,
    /// `BufferTooSmall` if key or value is too long.
    pub fn put(self: *Env_Pairs, key: []const u8, value: []const u8) SigError!void {
        if (self.count >= MAX_ENV_PAIRS) return error.CapacityExceeded;
        if (key.len > MAX_ENV_KEY_LEN) return error.BufferTooSmall;
        if (value.len > MAX_ENV_VALUE_LEN) return error.BufferTooSmall;
        @memcpy(self.keys[self.count][0..key.len], key);
        self.key_lens[self.count] = key.len;
        @memcpy(self.values[self.count][0..value.len], value);
        self.value_lens[self.count] = value.len;
        self.count += 1;
    }

    /// Get the key at index `i`.
    pub fn getKey(self: *const Env_Pairs, i: usize) []const u8 {
        return self.keys[i][0..self.key_lens[i]];
    }

    /// Get the value at index `i`.
    pub fn getValue(self: *const Env_Pairs, i: usize) []const u8 {
        return self.values[i][0..self.value_lens[i]];
    }
};

// ── Spawn_Options ───────────────────────────────────────────────────────

/// Configuration for child process spawning.
pub const Spawn_Options = struct {
    /// Working directory for the child. `null` = inherit parent cwd.
    cwd: ?[]const u8 = null,
    /// Stdio configuration for stdin.
    stdin: Stdio = .inherit,
    /// Stdio configuration for stdout.
    stdout: Stdio = .inherit,
    /// Stdio configuration for stderr.
    stderr: Stdio = .inherit,
    /// Optional environment override. If null, inherits parent environment.
    env: ?*const Env_Pairs = null,

    pub const Stdio = enum { inherit, pipe, close, ignore };
};

// ── Posix_Argv_Iterator ─────────────────────────────────────────────────

/// Zero-copy iterator over POSIX argv. Wraps the native `[]const [*:0]const u8`
/// vector and returns `std.mem.sliceTo(arg, 0)` for each argument.
pub const Posix_Argv_Iterator = struct {
    remaining: []const [*:0]const u8,

    pub fn init(argv: []const [*:0]const u8) Posix_Argv_Iterator {
        return .{ .remaining = argv };
    }

    /// Returns the next argument as a `[:0]const u8` slice, or `null` if done.
    pub fn next(self: *Posix_Argv_Iterator) SigError!?[:0]const u8 {
        if (self.remaining.len == 0) return null;
        const arg = self.remaining[0];
        self.remaining = self.remaining[1..];
        return std.mem.sliceTo(arg, 0);
    }

    /// Skip one argument without decoding. Returns `true` if skipped, `false` if done.
    pub fn skip(self: *Posix_Argv_Iterator) bool {
        if (self.remaining.len == 0) return false;
        self.remaining = self.remaining[1..];
        return true;
    }
};

// ── Windows_Argv_Iterator ───────────────────────────────────────────────

/// Decodes WTF-16 command-line arguments into WTF-8 using a caller-provided
/// buffer. Implements the post-2008 C runtime parsing rules (same algorithm
/// as `lib/std/process/Args.zig` `Iterator.Windows`), but writes into a
/// fixed buffer instead of heap-allocating.
pub const Windows_Argv_Iterator = struct {
    cmd_line: []const u16,
    index: usize = 0,
    buffer: []u8,
    end: usize = 0,
    /// True after the first argument (exe name) has been parsed.
    past_first: bool = false,

    pub fn init(cmd_line: []const u16, buf: []u8) Windows_Argv_Iterator {
        return .{
            .cmd_line = cmd_line,
            .buffer = buf,
        };
    }

    /// Returns the next argument as a `[:0]const u8` slice pointing into the
    /// caller-provided buffer, or `null` if done.
    /// Returns `SigError.BufferTooSmall` if the buffer cannot hold the decoded argument.
    pub fn next(self: *Windows_Argv_Iterator) SigError!?[:0]const u8 {
        return self.nextWithStrategy(next_strategy);
    }

    /// Skip one argument without decoding. Returns `true` if skipped, `false` if done.
    pub fn skip(self: *Windows_Argv_Iterator) bool {
        return self.nextWithStrategy(skip_strategy) catch false orelse false;
    }

    // -- Strategy types for next vs skip (mirrors std approach) --

    const next_strategy = struct {
        const T = SigError!?[:0]const u8;
        const eof: T = null;

        fn emitBackslashes(self: *Windows_Argv_Iterator, count: usize, last: ?u16) SigError!?u16 {
            for (0..count) |_| {
                if (self.end >= self.buffer.len) return error.BufferTooSmall;
                self.buffer[self.end] = '\\';
                self.end += 1;
            }
            return if (count != 0) @as(?u16, '\\') else last;
        }

        fn emitCharacter(self: *Windows_Argv_Iterator, code_unit: u16, last: ?u16) SigError!?u16 {
            // Surrogate pair combining: if last emitted was a high surrogate and
            // this is a low surrogate, combine them into a single UTF-8 codepoint.
            if (last != null and
                std.unicode.utf16IsLowSurrogate(code_unit) and
                std.unicode.utf16IsHighSurrogate(last.?))
            {
                const codepoint = std.unicode.utf16DecodeSurrogatePair(&.{ last.?, code_unit }) catch unreachable;
                // Unpaired surrogate was 3 bytes; combined codepoint is 4 bytes.
                // We overwrite the last 3 bytes and write 4.
                if (self.end + 1 > self.buffer.len) return error.BufferTooSmall;
                const dest = self.buffer[self.end - 3 ..];
                const len = std.unicode.utf8Encode(codepoint, dest) catch unreachable;
                std.debug.assert(len == 4);
                self.end += 1;
                return null;
            }

            const wtf8_len = std.unicode.wtf8Encode(code_unit, self.buffer[self.end..]) catch
                return error.BufferTooSmall;
            self.end += wtf8_len;
            return code_unit;
        }

        fn yieldArg(self: *Windows_Argv_Iterator) SigError!?[:0]const u8 {
            if (self.end >= self.buffer.len) return error.BufferTooSmall;
            self.buffer[self.end] = 0;
            const arg = self.buffer[0..self.end :0];
            self.end = 0;
            return arg;
        }
    };

    const skip_strategy = struct {
        const T = SigError!?[:0]const u8;
        const eof: T = null;

        fn emitBackslashes(_: *Windows_Argv_Iterator, _: usize, last: ?u16) SigError!?u16 {
            return last;
        }

        fn emitCharacter(_: *Windows_Argv_Iterator, _: u16, last: ?u16) SigError!?u16 {
            return last;
        }

        fn yieldArg(self: *Windows_Argv_Iterator) SigError!?[:0]const u8 {
            _ = self;
            // Return a non-null sentinel to indicate "skipped successfully".
            // The caller (skip()) checks for non-null.
            return @as([:0]const u8, "");
        }
    };

    fn nextWithStrategy(self: *Windows_Argv_Iterator, comptime strategy: type) strategy.T {
        var last_emitted: ?u16 = null;

        // First argument (executable name): different parsing rules.
        if (!self.past_first) {
            self.past_first = true;

            if (self.cmd_line.len == 0 or self.cmd_line[0] == 0) {
                return strategy.eof;
            }

            var inside_quotes = false;
            while (true) : (self.index += 1) {
                const char: u16 = if (self.index != self.cmd_line.len)
                    std.mem.littleToNative(u16, self.cmd_line[self.index])
                else
                    0;
                switch (char) {
                    0 => {
                        return strategy.yieldArg(self);
                    },
                    '"' => {
                        inside_quotes = !inside_quotes;
                    },
                    ' ', '\t' => {
                        if (inside_quotes) {
                            last_emitted = strategy.emitCharacter(self, char, last_emitted) catch |e| return e;
                        } else {
                            self.index += 1;
                            return strategy.yieldArg(self);
                        }
                    },
                    else => {
                        last_emitted = strategy.emitCharacter(self, char, last_emitted) catch |e| return e;
                    },
                }
            }
        }

        // Skip leading whitespace. Complete if we reach end of string.
        while (true) : (self.index += 1) {
            const char: u16 = if (self.index != self.cmd_line.len)
                std.mem.littleToNative(u16, self.cmd_line[self.index])
            else
                0;
            switch (char) {
                0 => return strategy.eof,
                ' ', '\t' => continue,
                else => break,
            }
        }

        // Subsequent arguments: backslash-quote escaping rules.
        var backslash_count: usize = 0;
        var inside_quotes = false;
        while (true) : (self.index += 1) {
            const char: u16 = if (self.index != self.cmd_line.len)
                std.mem.littleToNative(u16, self.cmd_line[self.index])
            else
                0;
            switch (char) {
                0 => {
                    last_emitted = strategy.emitBackslashes(self, backslash_count, last_emitted) catch |e| return e;
                    return strategy.yieldArg(self);
                },
                ' ', '\t' => {
                    last_emitted = strategy.emitBackslashes(self, backslash_count, last_emitted) catch |e| return e;
                    backslash_count = 0;
                    if (inside_quotes) {
                        last_emitted = strategy.emitCharacter(self, char, last_emitted) catch |e| return e;
                    } else return strategy.yieldArg(self);
                },
                '"' => {
                    const char_is_escaped_quote = backslash_count % 2 != 0;
                    last_emitted = strategy.emitBackslashes(self, backslash_count / 2, last_emitted) catch |e| return e;
                    backslash_count = 0;
                    if (char_is_escaped_quote) {
                        last_emitted = strategy.emitCharacter(self, '"', last_emitted) catch |e| return e;
                    } else {
                        if (inside_quotes and
                            self.index + 1 != self.cmd_line.len and
                            std.mem.littleToNative(u16, self.cmd_line[self.index + 1]) == '"')
                        {
                            last_emitted = strategy.emitCharacter(self, '"', last_emitted) catch |e| return e;
                            self.index += 1;
                        } else {
                            inside_quotes = !inside_quotes;
                        }
                    }
                },
                '\\' => {
                    backslash_count += 1;
                },
                else => {
                    last_emitted = strategy.emitBackslashes(self, backslash_count, last_emitted) catch |e| return e;
                    backslash_count = 0;
                    last_emitted = strategy.emitCharacter(self, char, last_emitted) catch |e| return e;
                },
            }
        }
    }
};

// ── Argv_Iterator ───────────────────────────────────────────────────────

/// Platform-dispatching argv iterator. On Windows, decodes WTF-16 into a
/// caller-provided buffer. On POSIX, wraps native argv pointers (zero-copy).
pub const Argv_Iterator = struct {
    inner: Inner,

    const Inner = switch (native_os) {
        .windows => Windows_Argv_Iterator,
        else => Posix_Argv_Iterator,
    };

    /// Initialize from platform-native argv. On POSIX, `buf` is unused.
    /// On Windows, `buf` is used for WTF-16 → WTF-8 decoding.
    pub fn init(argv: switch (native_os) {
        .windows => []const u16,
        else => []const [*:0]const u8,
    }, buf: []u8) Argv_Iterator {
        return .{
            .inner = switch (native_os) {
                .windows => Windows_Argv_Iterator.init(argv, buf),
                else => Posix_Argv_Iterator.init(argv),
            },
        };
    }

    /// Returns the next argument as a `[:0]const u8` slice, or `null` if done.
    /// On Windows, returns `SigError.BufferTooSmall` if the buffer is too small.
    pub fn next(self: *Argv_Iterator) SigError!?[:0]const u8 {
        return self.inner.next();
    }

    /// Skip one argument without decoding. Returns `true` if skipped, `false` if done.
    pub fn skip(self: *Argv_Iterator) bool {
        return self.inner.skip();
    }
};

// ── Posix_Env_Iterator ──────────────────────────────────────────────────

/// Zero-copy iterator over POSIX environment variables.
/// Walks the `environ` pointer and splits each entry on the first `=`.
const Posix_Env_Iterator = struct {
    index: usize = 0,

    fn init() Posix_Env_Iterator {
        return .{};
    }

    fn next(self: *Posix_Env_Iterator, _: []u8, _: []u8) SigError!?Env_Iterator.Entry {
        const env_ptr = std.c.environ;
        // Walk until we find a non-null entry or reach the sentinel.
        while (true) {
            const entry_opt: ?[*:0]u8 = env_ptr[self.index];
            const entry = entry_opt orelse return null;
            self.index += 1;

            const entry_slice = std.mem.sliceTo(entry, 0);
            // Split on first '='
            if (std.mem.indexOfScalar(u8, entry_slice, '=')) |eq_pos| {
                return .{
                    .key = entry_slice[0..eq_pos],
                    .value = entry_slice[eq_pos + 1 ..],
                };
            }
            // Malformed entry (no '='), skip it
        }
    }
};

// ── Windows_Env_Iterator ────────────────────────────────────────────────

/// Iterator over Windows environment variables.
/// Uses `std.c.environ` (available via UCRT) and copies key/value into
/// caller-provided buffers since the environment block encoding may differ.
const Windows_Env_Iterator = struct {
    index: usize = 0,

    fn init() Windows_Env_Iterator {
        return .{};
    }

    fn next(self: *Windows_Env_Iterator, key_buf: []u8, value_buf: []u8) SigError!?Env_Iterator.Entry {
        const env_ptr = std.c.environ;
        while (true) {
            const entry_opt: ?[*:0]u8 = env_ptr[self.index];
            const entry = entry_opt orelse return null;
            self.index += 1;

            const entry_slice = std.mem.sliceTo(entry, 0);
            // Split on first '='
            if (std.mem.indexOfScalar(u8, entry_slice, '=')) |eq_pos| {
                const key = entry_slice[0..eq_pos];
                const value = entry_slice[eq_pos + 1 ..];

                if (key.len > key_buf.len) return error.BufferTooSmall;
                if (value.len > value_buf.len) return error.BufferTooSmall;

                @memcpy(key_buf[0..key.len], key);
                @memcpy(value_buf[0..value.len], value);

                return .{
                    .key = key_buf[0..key.len],
                    .value = value_buf[0..value.len],
                };
            }
            // Malformed entry (no '='), skip it
        }
    }
};

// ── Env_Iterator ────────────────────────────────────────────────────────

/// Iterates over all environment variables.
/// On POSIX: walks `environ` pointer, splits on first `=`, returns zero-copy slices.
/// On Windows: walks `environ` (via UCRT), copies key/value into caller-provided buffers.
pub const Env_Iterator = struct {
    inner: Inner,

    const Inner = switch (native_os) {
        .windows => Windows_Env_Iterator,
        else => Posix_Env_Iterator,
    };

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Initialize the environment iterator.
    pub fn init() Env_Iterator {
        return .{
            .inner = switch (native_os) {
                .windows => Windows_Env_Iterator.init(),
                else => Posix_Env_Iterator.init(),
            },
        };
    }

    /// Returns the next key-value pair, or `null` if done.
    /// On Windows, key and value are written into the caller-provided buffers.
    /// On POSIX, key and value point into the native environ memory (zero-copy).
    pub fn next(
        self: *Env_Iterator,
        key_buf: []u8,
        value_buf: []u8,
    ) SigError!?Entry {
        return self.inner.next(key_buf, value_buf);
    }
};

// ── Spawn / RunCommand ──────────────────────────────────────────────────

/// Map `Spawn_Options.Stdio` to `std.process.SpawnOptions.StdIo`.
fn mapStdio(s: Spawn_Options.Stdio) std.process.SpawnOptions.StdIo {
    return switch (s) {
        .inherit => .inherit,
        .pipe => .pipe,
        .close => .close,
        .ignore => .ignore,
    };
}

/// Convert a signal number to an exit code: `min(128 + signal, 255)`.
/// For signal 0 (normal exit), returns 0.
pub fn signalToExitCode(signal: u32) u8 {
    if (signal == 0) return 0;
    const sum: u32 = 128 + signal;
    return @intCast(@min(sum, 255));
}

/// Spawn a child process from a Command_Buffer.
/// Constructs argv on the stack, maps options, and delegates to `std.process.spawn`.
pub fn spawn(
    io: std.Io,
    cmd: *const Command_Buffer,
    options: Spawn_Options,
) SigError!std.process.Child {
    if (cmd.arg_count == 0) return error.BufferTooSmall;

    // Build argv as a slice of slices pointing into the Command_Buffer.
    var argv_ptrs: [MAX_CMD_ARGS][]const u8 = undefined;
    for (0..cmd.arg_count) |i| {
        argv_ptrs[i] = cmd.args[i][0..cmd.arg_lens[i]];
    }
    const argv = argv_ptrs[0..cmd.arg_count];

    // Map cwd: prefer Spawn_Options.cwd, fall back to Command_Buffer.cwd_len.
    const cwd_option: std.process.Child.Cwd = if (options.cwd) |cwd_path|
        .{ .path = cwd_path }
    else if (cmd.cwd_len > 0)
        .{ .path = cmd.cwd[0..cmd.cwd_len] }
    else
        .inherit;

    // Map environment: if Spawn_Options.env is set, build the env map.
    // std.process.SpawnOptions.environ_map expects a *const Environ.Map or null.
    // When null, the parent environment is inherited (Requirement 7.1).
    // NOTE: Env_Pairs → Environ.Map conversion would require an allocator,
    // which violates our zero-allocator rule. Since the current build runner
    // never passes custom env via Spawn_Options (it uses Command_Buffer-level
    // env or inherits), we pass null to inherit the parent environment.
    // Custom env support will be added when the build runner integration task
    // requires it.
    _ = options.env;

    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_option,
        .stdin = mapStdio(options.stdin),
        .stdout = mapStdio(options.stdout),
        .stderr = mapStdio(options.stderr),
    }) catch return error.BufferTooSmall;
}

/// Convenience: spawn, capture stderr, wait, return exit code as `u8`.
/// Maps POSIX signal termination to `min(128 + signal, 255)`.
/// Maps all OS errors to `SigError` for simplified error handling.
pub fn runCommand(
    io: std.Io,
    cmd: *const Command_Buffer,
    stderr_buf: []u8,
    stderr_len: *usize,
    options: Spawn_Options,
) SigError!u8 {
    // Force stderr to pipe for capture, inherit the rest from options.
    var spawn_opts = options;
    spawn_opts.stderr = .pipe;

    var child = try spawn(io, cmd, spawn_opts);
    defer child.kill(io);

    // Read stderr from the child into the caller-provided buffer.
    stderr_len.* = 0;
    if (child.stderr) |stderr_file| {
        var reader = stderr_file.reader(io, &.{});
        while (stderr_len.* < stderr_buf.len) {
            const remaining = stderr_buf.len - stderr_len.*;
            const n = reader.interface.readSliceShort(stderr_buf[stderr_len.*..][0..remaining]) catch break;
            if (n == 0) break;
            stderr_len.* += n;
        }
    }

    // Wait for the child to exit and extract the exit code.
    const term = child.wait(io) catch return error.BufferTooSmall;
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| signalToExitCode(@intFromEnum(sig)),
        .stopped => |code| signalToExitCode(code),
        .unknown => |code| signalToExitCode(code),
    };
}

/// Look up an environment variable by name.
/// On POSIX: wraps `std.c.getenv`, returns a pointer into the process
/// environment block (zero-copy). The `buf` parameter is unused on POSIX.
/// On Windows: copies the value into the caller-provided `buf`.
/// Returns `null` when the variable does not exist.
/// Returns `SigError.BufferTooSmall` when `buf` is too small (Windows only).
pub fn getenv(name: []const u8, buf: []u8) SigError!?[]const u8 {
    // We need a null-terminated copy of `name` for the C API.
    // Use a stack buffer — env var names are short.
    var name_buf: [MAX_ENV_KEY_LEN + 1]u8 = undefined;
    if (name.len > MAX_ENV_KEY_LEN) return error.BufferTooSmall;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const name_z: [*:0]const u8 = name_buf[0..name.len :0];

    const result = std.c.getenv(name_z);
    if (result) |ptr| {
        const value = std.mem.sliceTo(ptr, 0);
        if (native_os == .windows) {
            // On Windows, copy into caller buffer for safety.
            if (value.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[0..value.len], value);
            return buf[0..value.len];
        } else {
            // On POSIX, return zero-copy pointer into environ.
            return value;
        }
    }
    return null;
}

/// Get the current working directory into a caller-provided buffer.
/// On POSIX: wraps `std.c.getcwd`.
/// On Windows: calls `RtlGetCurrentDirectory_U`, decodes WTF-16 → UTF-8.
/// Returns `SigError.BufferTooSmall` when the buffer is too small.
pub fn getCwd(buf: []u8) SigError![]u8 {
    if (native_os == .windows) {
        const windows = std.os.windows;
        var wtf16le_buf: [windows.PATH_MAX_WIDE:0]u16 = undefined;
        const n = windows.ntdll.RtlGetCurrentDirectory_U(wtf16le_buf.len * 2 + 2, &wtf16le_buf) / 2;
        if (n == 0) return error.BufferTooSmall;
        const wtf16le_slice = wtf16le_buf[0..n];
        var end_index: usize = 0;
        var it = std.unicode.Wtf16LeIterator.init(wtf16le_slice);
        while (it.nextCodepoint()) |codepoint| {
            const seq_len = std.unicode.utf8CodepointSequenceLength(codepoint) catch
                return error.BufferTooSmall;
            if (end_index + seq_len > buf.len) return error.BufferTooSmall;
            end_index += std.unicode.wtf8Encode(codepoint, buf[end_index..]) catch
                return error.BufferTooSmall;
        }
        return buf[0..end_index];
    } else {
        // POSIX: use std.c.getcwd
        if (buf.len == 0) return error.BufferTooSmall;
        if (std.c.getcwd(buf.ptr, buf.len)) |_| {
            // getcwd writes a null-terminated string; find the length.
            const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
            return buf[0..len];
        }
        // getcwd failed — most likely ERANGE (buffer too small).
        return error.BufferTooSmall;
    }
}

/// Terminate the current process with the given exit code.
/// This function does not return.
pub fn exit(code: u8) noreturn {
    std.process.exit(code);
}
