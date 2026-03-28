// Unit tests for tar, zip, zon, uri format parsers
// Requirements: 18.1, 18.2, 18.3, 18.4, 18.5

const std = @import("std");
const testing = std.testing;
const sig_tar = @import("sig_tar");
const sig_zon = @import("sig_zon");
const sig_uri = @import("sig_uri");

// ── Tar tests ────────────────────────────────────────────────────────────

fn makeTarHeader(name: []const u8, size: u64) [512]u8 {
    var header: [512]u8 = [_]u8{0} ** 512;
    @memcpy(header[0..name.len], name);
    header[156] = '0'; // regular file
    var size_buf: [12]u8 = [_]u8{'0'} ** 12;
    var s = size;
    var pos: usize = 10;
    while (s > 0) : (pos -= 1) {
        size_buf[pos] = '0' + @as(u8, @intCast(s % 8));
        s /= 8;
    }
    @memcpy(header[124..136], &size_buf);
    return header;
}

test "TarReader parses single entry" {
    var archive: [2048]u8 = [_]u8{0} ** 2048;
    const header = makeTarHeader("test.txt", 0);
    @memcpy(archive[0..512], &header);

    var reader = sig_tar.TarReader(4){};
    const entries = try reader.parse(&archive);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("test.txt", entries[0].name());
    try testing.expectEqual(sig_tar.TarEntry.Kind.regular, entries[0].kind);
}

test "TarReader returns BufferTooSmall when too many entries" {
    var archive: [2048]u8 = [_]u8{0} ** 2048;
    const h1 = makeTarHeader("a.txt", 0);
    const h2 = makeTarHeader("b.txt", 0);
    @memcpy(archive[0..512], &h1);
    @memcpy(archive[512..1024], &h2);

    var reader = sig_tar.TarReader(1){};
    try testing.expectError(error.BufferTooSmall, reader.parse(&archive));
}

// ── ZON tests ────────────────────────────────────────────────────────────

test "ZON parseZon parses struct literal" {
    const input = ".{ .x = 10, .y = 20 }";
    var tokens: [16]sig_zon.Token = undefined;
    const result = try sig_zon.parseZon(input, &tokens);
    try testing.expect(result.len >= 3); // at least struct_begin, fields, struct_end
    try testing.expectEqual(sig_zon.Token.Kind.struct_begin, result[0].kind);
}

test "ZON parseZon parses string values" {
    const input = ".{ .name = \"hello\" }";
    var tokens: [16]sig_zon.Token = undefined;
    const result = try sig_zon.parseZon(input, &tokens);
    // Should have struct_begin, field_name, string, struct_end.
    var found_string = false;
    for (result) |tok| {
        if (tok.kind == .string) {
            try testing.expectEqualStrings("\"hello\"", sig_zon.tokenText(input, tok));
            found_string = true;
        }
    }
    try testing.expect(found_string);
}

test "ZON parseZon returns BufferTooSmall for tiny token buffer" {
    const input = ".{ .a = 1, .b = 2, .c = 3 }";
    var tokens: [1]sig_zon.Token = undefined;
    try testing.expectError(error.BufferTooSmall, sig_zon.parseZon(input, &tokens));
}

// ── URI tests ────────────────────────────────────────────────────────────

test "URI parseUri parses http URL" {
    const uri = try sig_uri.parseUri("http://example.com/path");
    try testing.expectEqualStrings("http", uri.scheme);
    try testing.expectEqualStrings("example.com", uri.host);
    try testing.expectEqualStrings("/path", uri.path);
    try testing.expectEqual(@as(u16, 80), uri.port);
}

test "URI parseUri parses https URL with port" {
    const uri = try sig_uri.parseUri("https://example.com:8443/api");
    try testing.expectEqualStrings("https", uri.scheme);
    try testing.expectEqualStrings("example.com", uri.host);
    try testing.expectEqual(@as(u16, 8443), uri.port);
    try testing.expectEqualStrings("/api", uri.path);
}
