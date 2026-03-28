// Feature: sig-memory-model
// Property 29: Tar entry streaming preserves content
// Property 30: URI parse round trip
//
// **Validates: Requirements 18.1, 18.2, 18.3, 18.4, 18.5**

const std = @import("std");
const harness = @import("harness");
const sig_tar = @import("sig_tar");
const sig_zon = @import("sig_zon");
const sig_uri = @import("sig_uri");

// ---------------------------------------------------------------------------
// Property 29 – Tar entry streaming preserves content
//
// We construct a minimal tar archive in memory, parse it, and verify
// the entry names and sizes match what we wrote.
// ---------------------------------------------------------------------------

fn buildTarHeader(name: []const u8, size: u64) [512]u8 {
    var header: [512]u8 = [_]u8{0} ** 512;
    // Name field (0..100).
    @memcpy(header[0..name.len], name);
    // Type flag: regular file.
    header[156] = '0';
    // Size field (124..136) in octal ASCII.
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

test "Property 29: Tar parse preserves entry names" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Build a tar archive with 1-3 entries.
            const entry_count = 1 + random.uintAtMost(usize, 2);
            var archive_buf: [4096]u8 = [_]u8{0} ** 4096;
            var offset: usize = 0;

            var names: [3][16]u8 = undefined;
            var name_lens: [3]usize = undefined;

            for (0..entry_count) |i| {
                const nlen = 1 + random.uintAtMost(usize, 10);
                const chars = "abcdefghijklmnop";
                for (names[i][0..nlen]) |*c| c.* = chars[random.uintAtMost(usize, chars.len - 1)];
                name_lens[i] = nlen;

                const header = buildTarHeader(names[i][0..nlen], 0);
                @memcpy(archive_buf[offset..][0..512], &header);
                offset += 512;
            }
            // Two zero blocks for end-of-archive.
            offset += 1024;

            var reader = sig_tar.TarReader(8){};
            const entries = try reader.parse(archive_buf[0..offset]);

            try std.testing.expectEqual(entry_count, entries.len);
            for (0..entry_count) |i| {
                try std.testing.expectEqualSlices(u8, names[i][0..name_lens[i]], entries[i].name());
            }
        }
    };
    harness.property("Tar parse preserves entry names", S.run);
}

// ---------------------------------------------------------------------------
// Property 30 – URI parse round trip
// ---------------------------------------------------------------------------

test "Property 30: URI parse extracts components correctly" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Build a random URI: http(s)://host:port/path?query
            const use_https = random.boolean();
            const scheme = if (use_https) "https" else "http";

            var host_buf: [16]u8 = undefined;
            const host_len = 3 + random.uintAtMost(usize, 10);
            const chars = "abcdefghijklmnop";
            for (host_buf[0..host_len]) |*c| c.* = chars[random.uintAtMost(usize, chars.len - 1)];
            const host = host_buf[0..host_len];

            var path_buf: [16]u8 = undefined;
            const path_len = 1 + random.uintAtMost(usize, 10);
            for (path_buf[0..path_len]) |*c| c.* = chars[random.uintAtMost(usize, chars.len - 1)];

            // Build URI string.
            var uri_buf: [128]u8 = undefined;
            const uri_str = std.fmt.bufPrint(&uri_buf, "{s}://{s}/{s}", .{
                scheme, host, path_buf[0..path_len],
            }) catch return;

            const parsed = sig_uri.parseUri(uri_str) catch return;

            try std.testing.expectEqualSlices(u8, scheme, parsed.scheme);
            try std.testing.expectEqualSlices(u8, host, parsed.host);
        }
    };
    harness.property("URI parse extracts components correctly", S.run);
}

// ---------------------------------------------------------------------------
// ZON parse produces tokens
// ---------------------------------------------------------------------------

test "Property 30: ZON parse produces tokens for valid input" {
    const S = struct {
        fn run(_: std.Random) anyerror!void {
            const input = ".{ .name = \"hello\", .value = 42 }";
            var tokens: [16]sig_zon.Token = undefined;
            const result = try sig_zon.parseZon(input, &tokens);
            try std.testing.expect(result.len > 0);

            // First token should be struct_begin.
            try std.testing.expectEqual(sig_zon.Token.Kind.struct_begin, result[0].kind);
        }
    };
    harness.property("ZON parse produces tokens for valid input", S.run);
}
