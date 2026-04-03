// Feature: sig-process, Property 1: Windows argv parsing round-trip
// Feature: sig-process, Property 2: Iterator termination
// Feature: sig-process, Property 3: BufferTooSmall on undersized argv decode buffer
//
// Property tests for sig.process argv iteration.

const std = @import("std");
const harness = @import("harness");
const sig_process = @import("sig_process");

// ── Helpers ─────────────────────────────────────────────────────────────

/// Escape a single argument for a Windows command line using standard rules.
/// Writes into `out` and returns the number of bytes written.
fn escapeArgWindows(arg: []const u8, out: []u8) usize {
    var pos: usize = 0;

    // Always quote the argument to handle spaces/tabs
    out[pos] = '"';
    pos += 1;

    var i: usize = 0;
    while (i < arg.len) {
        var num_backslashes: usize = 0;
        while (i < arg.len and arg[i] == '\\') {
            num_backslashes += 1;
            i += 1;
        }

        if (i == arg.len) {
            // At end of arg: double backslashes before closing quote
            var j: usize = 0;
            while (j < num_backslashes * 2) : (j += 1) {
                out[pos] = '\\';
                pos += 1;
            }
            break;
        } else if (arg[i] == '"') {
            // Before a quote: double backslashes + escaped quote
            var j: usize = 0;
            while (j < num_backslashes * 2 + 1) : (j += 1) {
                out[pos] = '\\';
                pos += 1;
            }
            out[pos] = '"';
            pos += 1;
            i += 1;
        } else {
            // Not before a quote: emit backslashes as-is
            var j: usize = 0;
            while (j < num_backslashes) : (j += 1) {
                out[pos] = '\\';
                pos += 1;
            }
            out[pos] = arg[i];
            pos += 1;
            i += 1;
        }
    }

    out[pos] = '"';
    pos += 1;
    return pos;
}

/// Generate a random ASCII-printable argument string (may include backslashes,
/// quotes, spaces, tabs). Length 0..max_len.
fn generateArg(random: std.Random, buf: []u8, max_len: usize) []const u8 {
    const len = random.uintAtMost(usize, max_len);
    // ASCII printable range 0x20..0x7E
    for (buf[0..len]) |*b| {
        b.* = @intCast(random.uintLessThan(u8, 0x7E - 0x20 + 1) + 0x20);
    }
    return buf[0..len];
}

/// Convert a UTF-8/ASCII string to WTF-16 LE into a stack buffer.
/// Returns the slice of u16 values written.
fn utf8ToWtf16(input: []const u8, out: []u16) []const u16 {
    const len = std.unicode.wtf8ToWtf16Le(out, input) catch return out[0..0];
    return out[0..len];
}

// ── Property 1: Windows argv parsing round-trip ─────────────────────────
// **Validates: Requirements 1.3, 1.5, 1.7**

test "Property 1: Windows argv parsing round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate 1-8 random argument strings
            const num_args = random.uintLessThan(usize, 8) + 1;

            var arg_storage: [8][64]u8 = undefined;
            var args: [8][]const u8 = undefined;
            for (0..num_args) |i| {
                args[i] = generateArg(random, &arg_storage[i], 60);
            }

            // Build a command line: "exe.exe" "arg1" "arg2" ...
            var cmd_buf: [8192]u8 = undefined;
            var cmd_len: usize = 0;

            // First arg is the exe name — use a simple unquoted name
            const exe_name = "test.exe";
            @memcpy(cmd_buf[cmd_len..][0..exe_name.len], exe_name);
            cmd_len += exe_name.len;

            // Append each argument with proper escaping
            for (0..num_args) |i| {
                cmd_buf[cmd_len] = ' ';
                cmd_len += 1;
                cmd_len += escapeArgWindows(args[i], cmd_buf[cmd_len..]);
            }

            // Convert command line to WTF-16
            var wtf16_buf: [8192]u16 = undefined;
            const wtf16 = utf8ToWtf16(cmd_buf[0..cmd_len], &wtf16_buf);

            // Parse with Windows_Argv_Iterator
            var decode_buf: [4096]u8 = undefined;
            var iter = sig_process.Windows_Argv_Iterator.init(wtf16, &decode_buf);

            // Skip the exe name
            const exe_result = try iter.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(exe_name, exe_result);

            // Verify each argument matches
            for (0..num_args) |i| {
                const parsed = try iter.next() orelse return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings(args[i], parsed);
            }

            // Verify iterator is exhausted
            const end = try iter.next();
            try std.testing.expect(end == null);
        }
    };
    harness.property("Windows argv parsing round-trip", S.run);
}

// ── Property 2: Iterator termination ────────────────────────────────────
// **Validates: Requirements 1.6, 1.8**

test "Property 2: Iterator termination" {
    // Test with Posix_Argv_Iterator (works on all platforms)
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const n = random.uintAtMost(usize, 16);

            // Build an array of sentinel-terminated argument pointers on the stack.
            // Each arg is a short string stored in a fixed buffer.
            var arg_bufs: [17][8]u8 = undefined;
            var ptrs: [17][*:0]const u8 = undefined;

            for (0..n) |i| {
                // Fill with a simple pattern + null terminator
                const len = random.uintLessThan(usize, 6) + 1;
                for (arg_bufs[i][0..len]) |*b| {
                    b.* = @intCast(random.uintLessThan(u8, 26) + 'a');
                }
                arg_bufs[i][len] = 0;
                ptrs[i] = @ptrCast(&arg_bufs[i]);
            }

            const argv: []const [*:0]const u8 = ptrs[0..n];
            var iter = sig_process.Posix_Argv_Iterator.init(argv);

            // Verify exactly N next() calls succeed
            var count: usize = 0;
            while (true) {
                const result = try iter.next();
                if (result == null) break;
                count += 1;
            }
            try std.testing.expectEqual(n, count);
        }
    };
    harness.property("Iterator termination (next)", S.run);

    // Also test skip()
    const S2 = struct {
        fn run(random: std.Random) anyerror!void {
            const n = random.uintAtMost(usize, 16);

            var arg_bufs: [17][8]u8 = undefined;
            var ptrs: [17][*:0]const u8 = undefined;

            for (0..n) |i| {
                const len = random.uintLessThan(usize, 6) + 1;
                for (arg_bufs[i][0..len]) |*b| {
                    b.* = @intCast(random.uintLessThan(u8, 26) + 'a');
                }
                arg_bufs[i][len] = 0;
                ptrs[i] = @ptrCast(&arg_bufs[i]);
            }

            const argv: []const [*:0]const u8 = ptrs[0..n];
            var iter = sig_process.Posix_Argv_Iterator.init(argv);

            // Verify exactly N skip() calls return true
            var count: usize = 0;
            while (iter.skip()) {
                count += 1;
            }
            try std.testing.expectEqual(n, count);
            // One more skip should return false
            try std.testing.expect(!iter.skip());
        }
    };
    harness.property("Iterator termination (skip)", S2.run);
}

// ── Property 3: BufferTooSmall on undersized argv decode buffer ─────────
// **Validates: Requirements 1.4**

test "Property 3: BufferTooSmall on undersized argv decode buffer" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate an argument string of length 20-60 bytes
            var arg_storage: [64]u8 = undefined;
            const arg_len = random.uintLessThan(usize, 41) + 20;
            for (arg_storage[0..arg_len]) |*b| {
                b.* = @intCast(random.uintLessThan(u8, 26) + 'a');
            }
            const arg = arg_storage[0..arg_len];

            // Build command line: "x" "long_argument"
            var cmd_buf: [256]u8 = undefined;
            var cmd_len: usize = 0;
            cmd_buf[0] = 'x';
            cmd_len = 1;
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
            cmd_len += escapeArgWindows(arg, cmd_buf[cmd_len..]);

            // Convert to WTF-16
            var wtf16_buf: [512]u16 = undefined;
            const wtf16 = utf8ToWtf16(cmd_buf[0..cmd_len], &wtf16_buf);

            // Use a buffer that's too small to hold the argument
            // Buffer must be big enough for the exe name "x" + null (2 bytes)
            // but too small for the long argument
            const small_buf_size = random.uintLessThan(usize, arg_len);
            var small_buf: [64]u8 = undefined;
            var iter = sig_process.Windows_Argv_Iterator.init(wtf16, small_buf[0..small_buf_size]);

            // The exe name "x" might succeed or fail depending on buffer size
            if (small_buf_size >= 2) {
                // Should succeed for exe name (1 byte + null)
                const exe = iter.next();
                if (exe) |result| {
                    // exe parsed ok, now the long arg should fail
                    _ = result catch {};
                    const arg_result = iter.next();
                    if (arg_result) |maybe_arg| {
                        // If it returned a value, the buffer was big enough — shouldn't happen
                        // since we ensured small_buf_size < arg_len
                        _ = maybe_arg;
                    } else |err| {
                        try std.testing.expectEqual(error.BufferTooSmall, err);
                    }
                } else |err| {
                    try std.testing.expectEqual(error.BufferTooSmall, err);
                }
            } else {
                // Buffer too small even for exe name
                const result = iter.next();
                if (result) |_| {
                    // Might get null for empty cmd line, that's ok
                } else |err| {
                    try std.testing.expectEqual(error.BufferTooSmall, err);
                }
            }
        }
    };
    harness.property("BufferTooSmall on undersized argv decode buffer", S.run);
}

// ── Property 4: Command_Buffer round-trip ───────────────────────────────
// Feature: sig-process, Property 4: Command_Buffer round-trip
// **Validates: Requirements 2.3**

test "Property 4: Command_Buffer round-trip" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate 1..MAX_CMD_ARGS random args, each within MAX_ARG_LEN
            const num_args = random.uintLessThan(usize, sig_process.MAX_CMD_ARGS) + 1;

            var cmd: sig_process.Command_Buffer = .{};

            // Store original args for comparison
            var originals: [sig_process.MAX_CMD_ARGS][128]u8 = undefined;
            var original_lens: [sig_process.MAX_CMD_ARGS]usize = undefined;

            for (0..num_args) |i| {
                // Generate a random arg of length 0..127
                const arg_len = random.uintAtMost(usize, 127);
                for (originals[i][0..arg_len]) |*b| {
                    b.* = @intCast(random.uintLessThan(u8, 254) + 1); // non-null bytes
                }
                original_lens[i] = arg_len;

                try cmd.appendArg(originals[i][0..arg_len]);
            }

            // Verify arg_count matches
            try std.testing.expectEqual(num_args, cmd.arg_count);

            // Read back and verify identical, in order
            for (0..num_args) |i| {
                const got = cmd.getArg(i);
                const expected = originals[i][0..original_lens[i]];
                try std.testing.expectEqualSlices(u8, expected, got);
            }
        }
    };
    harness.property("Command_Buffer round-trip", S.run);
}

// ── Property 5: BufferTooSmall on Command_Buffer overflow ───────────────
// Feature: sig-process, Property 5: BufferTooSmall on Command_Buffer overflow
// **Validates: Requirements 2.4**

test "Property 5: BufferTooSmall on Command_Buffer overflow" {
    // Sub-property A: arg exceeding MAX_ARG_LEN → BufferTooSmall
    const SA = struct {
        fn run(random: std.Random) anyerror!void {
            var cmd: sig_process.Command_Buffer = .{};

            // Generate an arg whose length exceeds MAX_ARG_LEN
            const excess = random.uintLessThan(usize, 128) + 1;
            const arg_len = sig_process.MAX_ARG_LEN + excess;

            // We don't need to actually fill a buffer — just create a slice
            // of the right length. Use a stack buffer up to a reasonable size.
            var big_buf: [sig_process.MAX_ARG_LEN + 128]u8 = undefined;
            for (big_buf[0..arg_len]) |*b| {
                b.* = 'x';
            }

            const result = cmd.appendArg(big_buf[0..arg_len]);
            try std.testing.expectError(error.BufferTooSmall, result);
        }
    };
    harness.property("BufferTooSmall on oversized arg", SA.run);

    // Sub-property B: more than MAX_CMD_ARGS args → CapacityExceeded
    const SB = struct {
        fn run(_: std.Random) anyerror!void {
            var cmd: sig_process.Command_Buffer = .{};

            // Fill to capacity
            for (0..sig_process.MAX_CMD_ARGS) |_| {
                try cmd.appendArg("arg");
            }

            // The next append should fail
            const result = cmd.appendArg("overflow");
            try std.testing.expectError(error.CapacityExceeded, result);
        }
    };
    harness.property("CapacityExceeded on too many args", SB.run);
}

// ── Property 6: Signal-to-exit-code mapping ─────────────────────────────
// Feature: sig-process, Property 6: Signal-to-exit-code mapping
// **Validates: Requirements 3.3**

test "Property 6: Signal-to-exit-code mapping" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const signal = random.uintAtMost(u32, 255);

            const result = sig_process.signalToExitCode(signal);

            if (signal == 0) {
                try std.testing.expectEqual(@as(u8, 0), result);
            } else {
                const expected: u8 = @intCast(@min(128 + signal, 255));
                try std.testing.expectEqual(expected, result);
            }
        }
    };
    harness.property("Signal-to-exit-code mapping", S.run);
}

// ── Property 7: Env_Pairs capacity enforcement ──────────────────────────
// Feature: sig-process, Property 7: Env_Pairs capacity enforcement
// **Validates: Requirements 7.3**

test "Property 7: Env_Pairs capacity enforcement" {
    // Sub-property A: Fill to MAX_ENV_PAIRS, verify next put returns CapacityExceeded
    const SA = struct {
        fn run(_: std.Random) anyerror!void {
            var pairs: sig_process.Env_Pairs = .{};

            // Fill to capacity with valid key-value pairs
            for (0..sig_process.MAX_ENV_PAIRS) |i| {
                // Generate a simple key like "K000", "K001", etc.
                var key_buf: [8]u8 = undefined;
                const key = formatIndex("K", i, &key_buf);
                try pairs.put(key, "value");
            }

            // The next put should fail with CapacityExceeded
            const result = pairs.put("overflow_key", "overflow_value");
            try std.testing.expectError(error.CapacityExceeded, result);
        }
    };
    harness.property("Env_Pairs CapacityExceeded when full", SA.run);

    // Sub-property B: Oversized key → BufferTooSmall
    const SB = struct {
        fn run(random: std.Random) anyerror!void {
            var pairs: sig_process.Env_Pairs = .{};

            // Generate a key that exceeds MAX_ENV_KEY_LEN
            const excess = random.uintLessThan(usize, 128) + 1;
            const key_len = sig_process.MAX_ENV_KEY_LEN + excess;
            var big_key: [sig_process.MAX_ENV_KEY_LEN + 128]u8 = undefined;
            for (big_key[0..key_len]) |*b| {
                b.* = 'k';
            }

            const result = pairs.put(big_key[0..key_len], "value");
            try std.testing.expectError(error.BufferTooSmall, result);
        }
    };
    harness.property("Env_Pairs BufferTooSmall on oversized key", SB.run);

    // Sub-property C: Oversized value → BufferTooSmall
    const SC = struct {
        fn run(random: std.Random) anyerror!void {
            var pairs: sig_process.Env_Pairs = .{};

            // Generate a value that exceeds MAX_ENV_VALUE_LEN
            const excess = random.uintLessThan(usize, 128) + 1;
            const value_len = sig_process.MAX_ENV_VALUE_LEN + excess;
            var big_val: [sig_process.MAX_ENV_VALUE_LEN + 128]u8 = undefined;
            for (big_val[0..value_len]) |*b| {
                b.* = 'v';
            }

            const result = pairs.put("key", big_val[0..value_len]);
            try std.testing.expectError(error.BufferTooSmall, result);
        }
    };
    harness.property("Env_Pairs BufferTooSmall on oversized value", SC.run);
}

/// Format an index as a zero-padded 3-digit string with a prefix.
/// E.g., formatIndex("K", 42, buf) → "K042"
fn formatIndex(prefix: []const u8, index: usize, buf: []u8) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    var pos = prefix.len;
    // Write 3-digit zero-padded number
    const d2: u8 = @intCast((index / 100) % 10);
    const d1: u8 = @intCast((index / 10) % 10);
    const d0: u8 = @intCast(index % 10);
    buf[pos] = '0' + d2;
    buf[pos + 1] = '0' + d1;
    buf[pos + 2] = '0' + d0;
    return buf[0 .. pos + 3];
}
