const SigError = @import("errors.zig").SigError;

pub const ParseErrorInfo = struct {
    byte_offset: usize,
    message: []const u8,
};

pub const KvPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const ParsedKv = struct {
    data: []const u8,
    count: usize,

    pub fn pairs(self: ParsedKv, pair_buf: []KvPair) SigError![]const KvPair {
        var pc: usize = 0;
        var ls: usize = 0;
        for (self.data, 0..) |c, idx| {
            if (c == '\n') {
                const line = self.data[ls..idx];
                if (line.len > 0) {
                    if (pc >= pair_buf.len) return error.BufferTooSmall;
                    pair_buf[pc] = parseKvLine(line) orelse return error.BufferTooSmall;
                    pc += 1;
                }
                ls = idx + 1;
            }
        }
        if (ls < self.data.len) {
            if (pc >= pair_buf.len) return error.BufferTooSmall;
            pair_buf[pc] = parseKvLine(self.data[ls..]) orelse return error.BufferTooSmall;
            pc += 1;
        }
        return pair_buf[0..pc];
    }
};

pub fn ParseResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: ParseErrorInfo,
        err_sig: SigError,
        pub fn unwrap(self: @This()) SigError!T {
            return switch (self) { .ok => |v| v, .err_sig => |e| e, .err => error.BufferTooSmall };
        }
    };
}
pub fn StreamingParser(comptime Token: type) type {
    return struct {
        state: State = .{},
        const Self = @This();
        const buf_cap = 4096;
        const State = struct {
            byte_offset: usize = 0,
            partial: [buf_cap]u8 = undefined,
            partial_len: usize = 0,
        };

        pub fn init() Self {
            return .{};
        }

        pub fn feed(self: *Self, input: []const u8, token_buf: []Token) ParseResult([]Token) {
            var tc: usize = 0;
            var ls: usize = 0;
            for (input, 0..) |c, i| {
                if (c == '\n') {
                    const seg = input[ls..i];
                    if (self.state.partial_len > 0) {
                        if (self.state.partial_len + seg.len > buf_cap) {
                            return .{ .err = .{ .byte_offset = self.state.byte_offset, .message = "line exceeds internal buffer" } };
                        }
                        @memcpy(self.state.partial[self.state.partial_len..][0..seg.len], seg);
                        const fl = self.state.partial_len + seg.len;
                        const line = self.state.partial[0..fl];
                        const lo = self.state.byte_offset - self.state.partial_len;
                        if (line.len > 0) {
                            if (tc >= token_buf.len) return .{ .err_sig = error.BufferTooSmall };
                            token_buf[tc] = parseLine(Token, line, lo) orelse return .{ .err = .{ .byte_offset = lo, .message = "invalid syntax: expected 'key=value'" } };
                            tc += 1;
                        }
                        self.state.partial_len = 0;
                    } else {
                        const lo = self.state.byte_offset;
                        if (seg.len > 0) {
                            if (tc >= token_buf.len) return .{ .err_sig = error.BufferTooSmall };
                            token_buf[tc] = parseLine(Token, seg, lo) orelse return .{ .err = .{ .byte_offset = lo, .message = "invalid syntax: expected 'key=value'" } };
                            tc += 1;
                        }
                    }
                    self.state.byte_offset += seg.len + 1;
                    ls = i + 1;
                }
            }
            const rem = input[ls..];
            if (rem.len > 0) {
                if (self.state.partial_len + rem.len > buf_cap) {
                    return .{ .err = .{ .byte_offset = self.state.byte_offset, .message = "line exceeds internal buffer" } };
                }
                @memcpy(self.state.partial[self.state.partial_len..][0..rem.len], rem);
                self.state.partial_len += rem.len;
                self.state.byte_offset += rem.len;
            }
            return .{ .ok = token_buf[0..tc] };
        }

        pub fn finish(self: *Self, token_buf: []Token) ParseResult([]Token) {
            if (self.state.partial_len == 0) return .{ .ok = token_buf[0..0] };
            if (token_buf.len == 0) return .{ .err_sig = error.BufferTooSmall };
            const line = self.state.partial[0..self.state.partial_len];
            const lo = self.state.byte_offset - self.state.partial_len;
            token_buf[0] = parseLine(Token, line, lo) orelse return .{ .err = .{ .byte_offset = lo, .message = "invalid syntax: expected 'key=value'" } };
            self.state.partial_len = 0;
            return .{ .ok = token_buf[0..1] };
        }
    };
}
pub fn measureParse(input: []const u8) usize {
    return input.len;
}

pub fn parseInto(input: []const u8, buf: []u8) SigError!ParsedKv {
    const needed = measureParse(input);
    if (buf.len < needed) return error.BufferTooSmall;
    @memcpy(buf[0..input.len], input);
    const data = buf[0..input.len];
    var count: usize = 0;
    var start: usize = 0;
    for (data, 0..) |c, idx| {
        if (c == '\n') {
            if (idx > start) count += 1;
            start = idx + 1;
        }
    }
    if (start < data.len) count += 1;
    return .{ .data = data, .count = count };
}

pub fn prettyPrint(kv_pairs: []const KvPair, buf: []u8) SigError![]u8 {
    var offset: usize = 0;
    for (kv_pairs) |pair| {
        const ll = pair.key.len + 1 + pair.value.len + 1;
        if (offset + ll > buf.len) return error.BufferTooSmall;
        @memcpy(buf[offset..][0..pair.key.len], pair.key);
        offset += pair.key.len;
        buf[offset] = '=';
        offset += 1;
        @memcpy(buf[offset..][0..pair.value.len], pair.value);
        offset += pair.value.len;
        buf[offset] = '\n';
        offset += 1;
    }
    return buf[0..offset];
}

fn parseKvLine(line: []const u8) ?KvPair {
    for (line, 0..) |c, i| {
        if (c == '=') return .{ .key = line[0..i], .value = line[i + 1 ..] };
    }
    return null;
}

fn parseLine(comptime Token: type, line: []const u8, _: usize) ?Token {
    if (Token == KvPair) return parseKvLine(line);
    return null;
}