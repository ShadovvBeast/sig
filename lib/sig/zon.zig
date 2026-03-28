//! Capacity-first ZON (Zig Object Notation) parser.
//!
//! Parses ZON text into a flat token stream stored in caller-provided buffers.
//! No allocator.

const std = @import("std");
const SigError = @import("errors.zig").SigError;

/// A ZON token.
pub const Token = struct {
    kind: Kind,
    /// Byte offset in the source where this token starts.
    start: usize,
    /// Byte length of the token text.
    len: usize,

    pub const Kind = enum {
        struct_begin, // .{
        struct_end, // }
        array_begin, // .{
        array_end, // }
        field_name, // .name =
        string, // "..."
        number, // 123, 0xFF, etc.
        bool_true, // true
        bool_false, // false
        null_literal, // null
    };
};

/// Parse ZON text into a caller-provided token buffer.
/// Returns the slice of tokens parsed.
/// Returns `BufferTooSmall` if the token buffer is too small.
pub fn parseZon(input: []const u8, tokens: []Token) SigError![]Token {
    var count: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        // Skip whitespace and commas.
        while (i < input.len and (input[i] == ' ' or input[i] == '\n' or
            input[i] == '\r' or input[i] == '\t' or input[i] == ','))
        {
            i += 1;
        }
        if (i >= input.len) break;

        if (count >= tokens.len) return error.BufferTooSmall;

        const c = input[i];

        if (c == '.' and i + 1 < input.len and input[i + 1] == '{') {
            // Struct/array begin.
            tokens[count] = .{ .kind = .struct_begin, .start = i, .len = 2 };
            count += 1;
            i += 2;
        } else if (c == '}') {
            tokens[count] = .{ .kind = .struct_end, .start = i, .len = 1 };
            count += 1;
            i += 1;
        } else if (c == '.' and i + 1 < input.len and isIdentStart(input[i + 1])) {
            // Field name: .name =
            const start = i;
            i += 1; // skip '.'
            while (i < input.len and isIdentChar(input[i])) : (i += 1) {}
            tokens[count] = .{ .kind = .field_name, .start = start, .len = i - start };
            count += 1;
            // Skip optional whitespace and '='.
            while (i < input.len and (input[i] == ' ' or input[i] == '=')) : (i += 1) {}
        } else if (c == '"') {
            // String literal.
            const start = i;
            i += 1;
            while (i < input.len and input[i] != '"') {
                if (input[i] == '\\') i += 1; // skip escaped char
                i += 1;
            }
            if (i < input.len) i += 1; // skip closing quote
            tokens[count] = .{ .kind = .string, .start = start, .len = i - start };
            count += 1;
        } else if (isDigit(c) or (c == '-' and i + 1 < input.len and isDigit(input[i + 1]))) {
            // Number.
            const start = i;
            if (c == '-') i += 1;
            while (i < input.len and (isDigit(input[i]) or input[i] == '.' or
                input[i] == 'x' or input[i] == 'X' or
                (input[i] >= 'a' and input[i] <= 'f') or
                (input[i] >= 'A' and input[i] <= 'F')))
            {
                i += 1;
            }
            tokens[count] = .{ .kind = .number, .start = start, .len = i - start };
            count += 1;
        } else if (matchKeyword(input[i..], "true")) {
            tokens[count] = .{ .kind = .bool_true, .start = i, .len = 4 };
            count += 1;
            i += 4;
        } else if (matchKeyword(input[i..], "false")) {
            tokens[count] = .{ .kind = .bool_false, .start = i, .len = 5 };
            count += 1;
            i += 5;
        } else if (matchKeyword(input[i..], "null")) {
            tokens[count] = .{ .kind = .null_literal, .start = i, .len = 4 };
            count += 1;
            i += 4;
        } else {
            // Skip unknown character.
            i += 1;
        }
    }

    return tokens[0..count];
}

/// Extract the text of a token from the source input.
pub fn tokenText(input: []const u8, token: Token) []const u8 {
    return input[token.start..][0..token.len];
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn matchKeyword(input: []const u8, keyword: []const u8) bool {
    if (input.len < keyword.len) return false;
    return std.mem.eql(u8, input[0..keyword.len], keyword);
}
