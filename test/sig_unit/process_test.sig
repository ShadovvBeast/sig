const std = @import("std");
const testing = std.testing;
const sig_process = @import("sig_process");

// ── Unit Tests for sig.process ───────────────────────────────────────────
// Requirements: 1.1–1.8, 2.1–2.4, 3.2, 3.3, 4.1–4.4, 5.1–5.3, 7.3

// ── Helpers ──────────────────────────────────────────────────────────────

/// Convert a UTF-8/ASCII string to WTF-16 LE into a stack buffer.
fn utf8ToWtf16(input: []const u8, out: []u16) []const u16 {
    const len = std.unicode.wtf8ToWtf16Le(out, input) catch return out[0..0];
    return out[0..len];
}

// ── Windows_Argv_Iterator ────────────────────────────────────────────────

test "Windows_Argv_Iterator: empty command line returns null" {
    var buf: [64]u8 = undefined;
    var iter = sig_process.Windows_Argv_Iterator.init(&.{}, &buf);
    const result = try iter.next();
    try testing.expect(result == null);
}

test "Windows_Argv_Iterator: single unquoted argument" {
    var wtf16_buf: [256]u16 = undefined;
    const wtf16 = utf8ToWtf16("test.exe", &wtf16_buf);
    var buf: [256]u8 = undefined;
    var iter = sig_process.Windows_Argv_Iterator.init(wtf16, &buf);

    const exe = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("test.exe", exe);

    const end = try iter.next();
    try testing.expect(end == null);
}

test "Windows_Argv_Iterator: arguments with embedded quotes" {
    var wtf16_buf: [512]u16 = undefined;
    // . "aa bb"
    const wtf16 = utf8ToWtf16(". \"aa bb\"", &wtf16_buf);
    var buf: [256]u8 = undefined;
    var iter = sig_process.Windows_Argv_Iterator.init(wtf16, &buf);

    const exe = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(".", exe);

    const arg1 = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("aa bb", arg1);

    try testing.expect((try iter.next()) == null);
}

test "Windows_Argv_Iterator: backslash sequences before quotes" {
    var wtf16_buf: [512]u16 = undefined;
    // foo.exe a\\\"b c d  → "a\"b", "c", "d"
    const wtf16 = utf8ToWtf16("foo.exe a\\\\\\\"b c d", &wtf16_buf);
    var buf: [256]u8 = undefined;
    var iter = sig_process.Windows_Argv_Iterator.init(wtf16, &buf);

    const exe = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("foo.exe", exe);

    const arg1 = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a\\\"b", arg1);

    const arg2 = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("c", arg2);

    const arg3 = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("d", arg3);

    try testing.expect((try iter.next()) == null);
}

test "Windows_Argv_Iterator: backslash-quote from MS docs" {
    var wtf16_buf: [512]u16 = undefined;
    // foo.exe "abc" d e  → "abc", "d", "e"
    const wtf16 = utf8ToWtf16("foo.exe \"abc\" d e", &wtf16_buf);
    var buf: [256]u8 = undefined;
    var iter = sig_process.Windows_Argv_Iterator.init(wtf16, &buf);

    _ = try iter.next(); // skip exe
    const a1 = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("abc", a1);
    const a2 = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("d", a2);
    const a3 = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("e", a3);
    try testing.expect((try iter.next()) == null);
}

test "Windows_Argv_Iterator: double-backslash before closing quote" {
    var wtf16_buf: [512]u16 = undefined;
    // foo.exe "Call Me Ishmael\\"  → "Call Me Ishmael\"
    const wtf16 = utf8ToWtf16("foo.exe \"Call Me Ishmael\\\\\"", &wtf16_buf);
    var buf: [256]u8 = undefined;
    var iter = sig_process.Windows_Argv_Iterator.init(wtf16, &buf);

    _ = try iter.next(); // skip exe
    const a1 = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Call Me Ishmael\\", a1);
    try testing.expect((try iter.next()) == null);
}

test "Windows_Argv_Iterator: skip advances without decoding" {
    var wtf16_buf: [512]u16 = undefined;
    const wtf16 = utf8ToWtf16("exe.exe first second third", &wtf16_buf);
    var buf: [256]u8 = undefined;
    var iter = sig_process.Windows_Argv_Iterator.init(wtf16, &buf);

    // Skip exe and first arg
    try testing.expect(iter.skip());
    try testing.expect(iter.skip());

    const arg = try iter.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("second", arg);
}

// ── Command_Buffer ───────────────────────────────────────────────────────

test "Command_Buffer: empty buffer has zero args" {
    const cmd: sig_process.Command_Buffer = .{};
    try testing.expectEqual(@as(usize, 0), cmd.arg_count);
}

test "Command_Buffer: single arg round-trip" {
    var cmd: sig_process.Command_Buffer = .{};
    try cmd.appendArg("hello");
    try testing.expectEqual(@as(usize, 1), cmd.arg_count);
    try testing.expectEqualStrings("hello", cmd.getArg(0));
}

test "Command_Buffer: fill to MAX_CMD_ARGS" {
    var cmd: sig_process.Command_Buffer = .{};
    for (0..sig_process.MAX_CMD_ARGS) |_| {
        try cmd.appendArg("x");
    }
    try testing.expectEqual(sig_process.MAX_CMD_ARGS, cmd.arg_count);
    // Next append should fail
    try testing.expectError(error.CapacityExceeded, cmd.appendArg("overflow"));
}

test "Command_Buffer: arg at exact MAX_ARG_LEN boundary" {
    var cmd: sig_process.Command_Buffer = .{};
    var big_arg: [sig_process.MAX_ARG_LEN]u8 = undefined;
    for (&big_arg) |*b| b.* = 'A';

    // Exactly MAX_ARG_LEN should succeed
    try cmd.appendArg(&big_arg);
    try testing.expectEqual(@as(usize, 1), cmd.arg_count);
    try testing.expectEqual(sig_process.MAX_ARG_LEN, cmd.getArg(0).len);

    // One byte over should fail
    var cmd2: sig_process.Command_Buffer = .{};
    var too_big: [sig_process.MAX_ARG_LEN + 1]u8 = undefined;
    for (&too_big) |*b| b.* = 'B';
    try testing.expectError(error.BufferTooSmall, cmd2.appendArg(&too_big));
}

test "Command_Buffer: setCwd round-trip" {
    var cmd: sig_process.Command_Buffer = .{};
    try cmd.setCwd("/some/path");
    try testing.expectEqualStrings("/some/path", cmd.cwd[0..cmd.cwd_len]);
}

// ── Env_Pairs ────────────────────────────────────────────────────────────

test "Env_Pairs: empty pairs has zero count" {
    const pairs: sig_process.Env_Pairs = .{};
    try testing.expectEqual(@as(usize, 0), pairs.count);
}

test "Env_Pairs: single pair round-trip" {
    var pairs: sig_process.Env_Pairs = .{};
    try pairs.put("HOME", "/usr/home");
    try testing.expectEqual(@as(usize, 1), pairs.count);
    try testing.expectEqualStrings("HOME", pairs.getKey(0));
    try testing.expectEqualStrings("/usr/home", pairs.getValue(0));
}

test "Env_Pairs: key at exact MAX_ENV_KEY_LEN boundary" {
    var pairs: sig_process.Env_Pairs = .{};
    var max_key: [sig_process.MAX_ENV_KEY_LEN]u8 = undefined;
    for (&max_key) |*b| b.* = 'K';

    // Exactly at limit should succeed
    try pairs.put(&max_key, "val");
    try testing.expectEqual(@as(usize, 1), pairs.count);
    try testing.expectEqual(sig_process.MAX_ENV_KEY_LEN, pairs.getKey(0).len);

    // One byte over should fail
    var pairs2: sig_process.Env_Pairs = .{};
    var too_big_key: [sig_process.MAX_ENV_KEY_LEN + 1]u8 = undefined;
    for (&too_big_key) |*b| b.* = 'K';
    try testing.expectError(error.BufferTooSmall, pairs2.put(&too_big_key, "val"));
}

test "Env_Pairs: value at exact MAX_ENV_VALUE_LEN boundary" {
    var pairs: sig_process.Env_Pairs = .{};
    var max_val: [sig_process.MAX_ENV_VALUE_LEN]u8 = undefined;
    for (&max_val) |*b| b.* = 'V';

    // Exactly at limit should succeed
    try pairs.put("key", &max_val);
    try testing.expectEqual(@as(usize, 1), pairs.count);
    try testing.expectEqual(sig_process.MAX_ENV_VALUE_LEN, pairs.getValue(0).len);

    // One byte over should fail
    var pairs2: sig_process.Env_Pairs = .{};
    var too_big_val: [sig_process.MAX_ENV_VALUE_LEN + 1]u8 = undefined;
    for (&too_big_val) |*b| b.* = 'V';
    try testing.expectError(error.BufferTooSmall, pairs2.put("key", &too_big_val));
}

// ── getenv ───────────────────────────────────────────────────────────────

test "getenv: PATH exists and returns non-empty value" {
    var buf: [sig_process.MAX_ENV_VALUE_LEN]u8 = undefined;
    const result = try sig_process.getenv("PATH", &buf);
    try testing.expect(result != null);
    try testing.expect(result.?.len > 0);
}

test "getenv: nonexistent variable returns null" {
    var buf: [256]u8 = undefined;
    const result = try sig_process.getenv("SIG_PROCESS_TEST_NONEXISTENT_VAR_12345", &buf);
    try testing.expect(result == null);
}

// ── getCwd ───────────────────────────────────────────────────────────────

test "getCwd: returns non-empty path" {
    var buf: [sig_process.MAX_CWD_LEN]u8 = undefined;
    const cwd = try sig_process.getCwd(&buf);
    try testing.expect(cwd.len > 0);
}

// ── signalToExitCode ─────────────────────────────────────────────────────

test "signalToExitCode: signal 0 returns 0" {
    try testing.expectEqual(@as(u8, 0), sig_process.signalToExitCode(0));
}

test "signalToExitCode: signal 1 returns 129" {
    try testing.expectEqual(@as(u8, 129), sig_process.signalToExitCode(1));
}

test "signalToExitCode: signal 127 returns 255" {
    try testing.expectEqual(@as(u8, 255), sig_process.signalToExitCode(127));
}

test "signalToExitCode: signal 128 caps at 255" {
    try testing.expectEqual(@as(u8, 255), sig_process.signalToExitCode(128));
}
