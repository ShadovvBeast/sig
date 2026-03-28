//! Capacity-first JSON parser and serializer.
//!
//! All operations use caller-provided buffers. No allocator parameters.
//! Supports streaming tokenization with a fixed nesting depth, field
//! extraction from raw JSON bytes, and serialization into caller buffers.

const std = @import("std");
const SigError = @import("errors.zig").SigError;

// ── Token Types ──────────────────────────────────────────────────────────

pub const TokenKind = enum {
    object_begin, // {
    object_end, // }
    array_begin, // [
    array_end, // ]
    string, // "..."
    number, // 123, -45, 1.5e10
    true_literal, // true
    false_literal, // false
    null_literal, // null
};

pub const Token = struct {
    kind: TokenKind,
    /// Byte range in the source input.
    start: usize,
    len: usize,
};

// ── Streaming Tokenizer ──────────────────────────────────────────────────

/// Fixed-depth JSON tokenizer. No allocator needed.
/// `max_depth` controls the maximum nesting of objects/arrays.
pub fn Tokenizer(comptime max_depth: usize) type {
    return struct {
        depth: usize = 0,
        stack: [max_depth]u8 = undefined, // '{' or '['

        const Self = @This();

        /// Tokenize a complete JSON input into a caller-provided token buffer.
        /// Returns the slice of tokens, or `BufferTooSmall` if the token buffer
        /// is too small or nesting exceeds `max_depth`.
        pub fn tokenize(self: *Self, input: []const u8, tokens: []Token) SigError![]Token {
            var count: usize = 0;
            var i: usize = 0;

            while (i < input.len) {
                // Skip whitespace, commas, colons.
                while (i < input.len and isWhitespaceOrSep(input[i])) : (i += 1) {}
                if (i >= input.len) break;

                if (count >= tokens.len) return error.BufferTooSmall;

                const c = input[i];
                switch (c) {
                    '{' => {
                        if (self.depth >= max_depth) return error.DepthExceeded;
                        self.stack[self.depth] = '{';
                        self.depth += 1;
                        tokens[count] = .{ .kind = .object_begin, .start = i, .len = 1 };
                        count += 1;
                        i += 1;
                    },
                    '}' => {
                        if (self.depth == 0) return error.BufferTooSmall;
                        self.depth -= 1;
                        tokens[count] = .{ .kind = .object_end, .start = i, .len = 1 };
                        count += 1;
                        i += 1;
                    },
                    '[' => {
                        if (self.depth >= max_depth) return error.DepthExceeded;
                        self.stack[self.depth] = '[';
                        self.depth += 1;
                        tokens[count] = .{ .kind = .array_begin, .start = i, .len = 1 };
                        count += 1;
                        i += 1;
                    },
                    ']' => {
                        if (self.depth == 0) return error.BufferTooSmall;
                        self.depth -= 1;
                        tokens[count] = .{ .kind = .array_end, .start = i, .len = 1 };
                        count += 1;
                        i += 1;
                    },
                    '"' => {
                        const start = i;
                        i += 1;
                        while (i < input.len and input[i] != '"') {
                            if (input[i] == '\\') i += 1;
                            i += 1;
                        }
                        if (i < input.len) i += 1; // closing quote
                        tokens[count] = .{ .kind = .string, .start = start, .len = i - start };
                        count += 1;
                    },
                    '-', '0'...'9' => {
                        const start = i;
                        if (input[i] == '-') i += 1;
                        while (i < input.len and isNumChar(input[i])) : (i += 1) {}
                        tokens[count] = .{ .kind = .number, .start = start, .len = i - start };
                        count += 1;
                    },
                    't' => {
                        if (i + 4 <= input.len and std.mem.eql(u8, input[i..][0..4], "true")) {
                            tokens[count] = .{ .kind = .true_literal, .start = i, .len = 4 };
                            count += 1;
                            i += 4;
                        } else {
                            i += 1;
                        }
                    },
                    'f' => {
                        if (i + 5 <= input.len and std.mem.eql(u8, input[i..][0..5], "false")) {
                            tokens[count] = .{ .kind = .false_literal, .start = i, .len = 5 };
                            count += 1;
                            i += 5;
                        } else {
                            i += 1;
                        }
                    },
                    'n' => {
                        if (i + 4 <= input.len and std.mem.eql(u8, input[i..][0..4], "null")) {
                            tokens[count] = .{ .kind = .null_literal, .start = i, .len = 4 };
                            count += 1;
                            i += 4;
                        } else {
                            i += 1;
                        }
                    },
                    else => i += 1,
                }
            }

            return tokens[0..count];
        }
    };
}

// ── Field Extraction (zero-copy from raw JSON) ───────────────────────────

/// Extract the string value for a given key from raw JSON.
/// Returns the value without quotes. Writes into `out` buffer.
/// The key should NOT include quotes.
pub fn extractString(json: []const u8, key: []const u8, out: []u8) SigError![]u8 {
    const val = findValueAfterKey(json, key) orelse return error.BufferTooSmall;
    if (val.len < 2 or val[0] != '"') return error.BufferTooSmall;

    // Find closing quote (handle escapes).
    var i: usize = 1;
    var out_len: usize = 0;
    while (i < val.len and val[i] != '"') {
        if (out_len >= out.len) return error.BufferTooSmall;
        if (val[i] == '\\' and i + 1 < val.len) {
            i += 1;
            out[out_len] = switch (val[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                '/' => '/',
                else => val[i],
            };
        } else {
            out[out_len] = val[i];
        }
        out_len += 1;
        i += 1;
    }
    return out[0..out_len];
}

/// Extract an integer value for a given key from raw JSON.
pub fn extractInt(json: []const u8, key: []const u8) SigError!i64 {
    const val = findValueAfterKey(json, key) orelse return error.BufferTooSmall;

    var i: usize = 0;
    const negative = i < val.len and val[i] == '-';
    if (negative) i += 1;

    var result: i64 = 0;
    while (i < val.len and val[i] >= '0' and val[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i64, val[i] - '0');
    }
    return if (negative) -result else result;
}

/// Extract a string array for a given key. Writes each element into `out_bufs`.
/// Returns the number of elements found.
pub fn extractStringArray(
    json: []const u8,
    key: []const u8,
    out_bufs: [][]u8,
    out_lens: []usize,
) SigError!usize {
    const val = findValueAfterKey(json, key) orelse return error.BufferTooSmall;

    // Check for null.
    if (val.len >= 4 and std.mem.eql(u8, val[0..4], "null")) return 0;

    // Expect '['.
    if (val.len == 0 or val[0] != '[') return error.BufferTooSmall;

    var i: usize = 1;
    var count: usize = 0;

    while (i < val.len and val[i] != ']') {
        // Skip whitespace and commas.
        while (i < val.len and (val[i] == ' ' or val[i] == ',' or val[i] == '\n' or val[i] == '\r' or val[i] == '\t')) : (i += 1) {}
        if (i >= val.len or val[i] == ']') break;

        if (val[i] != '"') return error.BufferTooSmall;
        i += 1; // skip opening quote

        if (count >= out_bufs.len) return error.BufferTooSmall;

        var len: usize = 0;
        while (i < val.len and val[i] != '"') {
            if (len >= out_bufs[count].len) return error.BufferTooSmall;
            if (val[i] == '\\' and i + 1 < val.len) {
                i += 1;
                out_bufs[count][len] = val[i];
            } else {
                out_bufs[count][len] = val[i];
            }
            len += 1;
            i += 1;
        }
        if (i < val.len) i += 1; // skip closing quote
        out_lens[count] = len;
        count += 1;
    }

    return count;
}

// ── JSON Serialization (into caller buffer) ──────────────────────────────

/// A JSON writer that serializes into a caller-provided buffer.
pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,
    indent_level: usize = 0,
    needs_comma: bool = false,
    use_indent: bool = true,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn initCompact(buf: []u8) Writer {
        return .{ .buf = buf, .use_indent = false };
    }

    pub fn written(self: *const Writer) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn beginObject(self: *Writer) SigError!void {
        try self.maybeComma();
        try self.put('{');
        self.indent_level += 1;
        self.needs_comma = false;
    }

    pub fn endObject(self: *Writer) SigError!void {
        self.indent_level -= 1;
        self.needs_comma = false;
        try self.newline();
        try self.put('}');
        self.needs_comma = true;
    }

    pub fn beginArray(self: *Writer) SigError!void {
        try self.maybeComma();
        try self.put('[');
        self.indent_level += 1;
        self.needs_comma = false;
    }

    pub fn endArray(self: *Writer) SigError!void {
        self.indent_level -= 1;
        self.needs_comma = false;
        try self.newline();
        try self.put(']');
        self.needs_comma = true;
    }

    pub fn objectField(self: *Writer, key: []const u8) SigError!void {
        try self.maybeComma();
        try self.newline();
        try self.writeIndent();
        try self.put('"');
        try self.writeRaw(key);
        try self.writeRaw("\": ");
        self.needs_comma = false;
    }

    pub fn writeString(self: *Writer, val: []const u8) SigError!void {
        try self.maybeComma();
        try self.put('"');
        for (val) |c| {
            switch (c) {
                '"' => try self.writeRaw("\\\""),
                '\\' => try self.writeRaw("\\\\"),
                '\n' => try self.writeRaw("\\n"),
                '\r' => try self.writeRaw("\\r"),
                '\t' => try self.writeRaw("\\t"),
                else => try self.put(c),
            }
        }
        try self.put('"');
        self.needs_comma = true;
    }

    pub fn writeInt(self: *Writer, val: i64) SigError!void {
        try self.maybeComma();
        var num_buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch return error.BufferTooSmall;
        try self.writeRaw(s);
        self.needs_comma = true;
    }

    pub fn writeNull(self: *Writer) SigError!void {
        try self.maybeComma();
        try self.writeRaw("null");
        self.needs_comma = true;
    }

    pub fn writeBool(self: *Writer, val: bool) SigError!void {
        try self.maybeComma();
        try self.writeRaw(if (val) "true" else "false");
        self.needs_comma = true;
    }

    // Internal helpers.

    fn maybeComma(self: *Writer) SigError!void {
        if (self.needs_comma) {
            try self.put(',');
        }
    }

    fn newline(self: *Writer) SigError!void {
        if (self.use_indent) {
            try self.put('\n');
        }
    }

    fn writeIndent(self: *Writer) SigError!void {
        if (!self.use_indent) return;
        var i: usize = 0;
        while (i < self.indent_level * 2) : (i += 1) {
            try self.put(' ');
        }
    }

    fn put(self: *Writer, c: u8) SigError!void {
        if (self.pos >= self.buf.len) return error.BufferTooSmall;
        self.buf[self.pos] = c;
        self.pos += 1;
    }

    fn writeRaw(self: *Writer, data: []const u8) SigError!void {
        if (self.pos + data.len > self.buf.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }
};

// ── Internal Helpers ─────────────────────────────────────────────────────

fn findValueAfterKey(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key" : <value>
    // We look for the pattern: "key" followed by optional whitespace and colon.
    var i: usize = 0;
    while (i + key.len + 2 < json.len) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 ..][0..key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            var j = i + 1 + key.len + 1; // past closing quote
            // Skip whitespace and colon.
            while (j < json.len and (json[j] == ' ' or json[j] == ':' or
                json[j] == '\n' or json[j] == '\r' or json[j] == '\t')) : (j += 1)
            {}
            if (j < json.len) return json[j..];
        }
        i += 1;
    }
    return null;
}

fn isWhitespaceOrSep(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == ',' or c == ':';
}

fn isNumChar(c: u8) bool {
    return (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-';
}
