// Feature: sig-memory-model, Property 22: HTTP request build-then-parse round trip
// Feature: sig-memory-model, Property 23: HTTP response parse extracts correct status and body
// Feature: sig-memory-model, Property 24: URI parse-then-reconstruct round trip
//
// **Validates: Requirements 14.1, 14.2, 14.3, 14.4, 14.7, 14.9**

const std = @import("std");
const harness = @import("harness");
const sig_http = @import("sig_http");

// ---------------------------------------------------------------------------
// Helpers — generate simple alphanumeric strings to avoid special-char issues
// ---------------------------------------------------------------------------

const alpha_chars = "abcdefghijklmnopqrstuvwxyz0123456789";

/// Fills `out[0..len]` with random alphanumeric characters and returns the slice.
fn randomAlphaSlice(random: std.Random, out: []u8, min_len: usize, max_len: usize) []u8 {
    const len = min_len + random.uintAtMost(usize, max_len - min_len);
    for (out[0..len]) |*c| {
        c.* = alpha_chars[random.uintAtMost(usize, alpha_chars.len - 1)];
    }
    return out[0..len];
}

// ---------------------------------------------------------------------------
// Property 22 – HTTP request build-then-parse round trip
// ---------------------------------------------------------------------------

test "Property 22: buildRequest produces valid HTTP/1.1 request containing method, path, host, and body" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Generate random method (GET or POST)
            const methods = [_][]const u8{ "GET", "POST" };
            const method = methods[random.uintAtMost(usize, 1)];

            // Generate random host (3-20 alphanumeric chars)
            var host_buf: [20]u8 = undefined;
            const host = randomAlphaSlice(random, &host_buf, 3, 20);

            // Generate random path (1-30 chars, prefixed with /)
            var path_raw_buf: [30]u8 = undefined;
            const path_raw = randomAlphaSlice(random, &path_raw_buf, 1, 30);
            var path_buf: [31]u8 = undefined;
            path_buf[0] = '/';
            @memcpy(path_buf[1..][0..path_raw.len], path_raw);
            const path = path_buf[0 .. path_raw.len + 1];

            // Generate 0-2 random headers
            var hdr_name_buf: [16]u8 = undefined;
            var hdr_val_buf: [16]u8 = undefined;
            const hdr_name = randomAlphaSlice(random, &hdr_name_buf, 3, 16);
            const hdr_val = randomAlphaSlice(random, &hdr_val_buf, 3, 16);
            const num_headers = random.uintAtMost(usize, 1);
            var headers_arr = [_]sig_http.Header{
                .{ .name = hdr_name, .value = hdr_val },
            };
            const headers: []const sig_http.Header = headers_arr[0..num_headers];

            // Generate random body (0-50 alphanumeric chars)
            var body_buf: [50]u8 = undefined;
            const body = randomAlphaSlice(random, &body_buf, 0, 50);

            // Build the request
            var req_buf: [2048]u8 = undefined;
            const request = try sig_http.buildRequest(&req_buf, method, host, path, headers, body);

            // Verify the request contains the method at the start
            try std.testing.expect(std.mem.startsWith(u8, request, method));

            // Verify the request contains "HTTP/1.1"
            try std.testing.expect(std.mem.indexOf(u8, request, "HTTP/1.1") != null);

            // Verify the request contains the path
            try std.testing.expect(std.mem.indexOf(u8, request, path) != null);

            // Verify the request contains "Host: <host>"
            var host_header_buf: [64]u8 = undefined;
            const host_header = std.fmt.bufPrint(&host_header_buf, "Host: {s}", .{host}) catch unreachable;
            try std.testing.expect(std.mem.indexOf(u8, request, host_header) != null);

            // Verify the body appears at the end of the request
            if (body.len > 0) {
                try std.testing.expect(std.mem.endsWith(u8, request, body));
            }
        }
    };
    harness.property("buildRequest produces valid HTTP/1.1 request", S.run);
}

// ---------------------------------------------------------------------------
// Property 23 – HTTP response parse extracts correct status and body
// ---------------------------------------------------------------------------

test "Property 23: parseResponse extracts correct status code and body" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Pick a random status code from common values
            const status_codes = [_]u16{ 200, 201, 204, 301, 302, 400, 401, 403, 404, 500, 502, 503 };
            const status = status_codes[random.uintAtMost(usize, status_codes.len - 1)];

            // Generate random body content (0-80 alphanumeric chars)
            var body_buf: [80]u8 = undefined;
            const body = randomAlphaSlice(random, &body_buf, 0, 80);

            // Construct a valid HTTP response string manually
            var resp_buf: [1024]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, body.len, body }) catch unreachable;

            // Parse the response
            var header_storage: [16]sig_http.Header = undefined;
            const response = try sig_http.parseResponse(resp, &header_storage);

            // Verify status code matches
            try std.testing.expectEqual(status, response.status);

            // Verify body matches
            try std.testing.expectEqualStrings(body, response.body);
        }
    };
    harness.property("parseResponse extracts correct status code and body", S.run);
}

test "Property 23: parseResponse with multiple headers extracts status and body" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            const status_codes = [_]u16{ 200, 404, 500 };
            const status = status_codes[random.uintAtMost(usize, status_codes.len - 1)];

            // Generate random body
            var body_buf: [60]u8 = undefined;
            const body = randomAlphaSlice(random, &body_buf, 1, 60);

            // Generate a random header name/value
            var hname_buf: [12]u8 = undefined;
            var hval_buf: [12]u8 = undefined;
            const hname = randomAlphaSlice(random, &hname_buf, 3, 12);
            const hval = randomAlphaSlice(random, &hval_buf, 3, 12);

            // Build response with extra header
            var resp_buf: [1024]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\n{s}: {s}\r\n\r\n{s}", .{ status, body.len, hname, hval, body }) catch unreachable;

            var header_storage: [16]sig_http.Header = undefined;
            const response = try sig_http.parseResponse(resp, &header_storage);

            try std.testing.expectEqual(status, response.status);
            try std.testing.expectEqualStrings(body, response.body);

            // Verify at least 2 headers were parsed (Content-Length + custom)
            try std.testing.expect(response.headers.len >= 2);
        }
    };
    harness.property("parseResponse with multiple headers extracts status and body", S.run);
}

// ---------------------------------------------------------------------------
// Property 24 – URI parse-then-reconstruct round trip
// ---------------------------------------------------------------------------

test "Property 24: parseUri extracts correct scheme, host, port, path, and query" {
    const S = struct {
        fn run(random: std.Random) anyerror!void {
            // Pick scheme
            const schemes = [_][]const u8{ "http", "https" };
            const scheme_idx = random.uintAtMost(usize, 1);
            const scheme = schemes[scheme_idx];
            const default_port: u16 = if (scheme_idx == 0) 80 else 443;

            // Generate random host (3-16 alphanumeric)
            var host_buf: [16]u8 = undefined;
            const host = randomAlphaSlice(random, &host_buf, 3, 16);

            // Optionally include a port
            const use_port = random.boolean();
            // Pick a port in a safe range (1024-9999) to avoid leading zeros
            const port: u16 = if (use_port) @as(u16, 1024) + random.uintAtMost(u16, 8975) else default_port;

            // Generate random path (1-20 alphanumeric)
            var path_raw_buf: [20]u8 = undefined;
            const path_raw = randomAlphaSlice(random, &path_raw_buf, 1, 20);

            // Optionally include a query
            const use_query = random.boolean();
            var query_buf: [20]u8 = undefined;
            const query = if (use_query) randomAlphaSlice(random, &query_buf, 1, 20) else @as([]u8, &[_]u8{});

            // Construct the URI string
            var uri_buf: [256]u8 = undefined;
            var offset: usize = 0;

            // scheme://
            @memcpy(uri_buf[offset..][0..scheme.len], scheme);
            offset += scheme.len;
            @memcpy(uri_buf[offset..][0..3], "://");
            offset += 3;

            // host
            @memcpy(uri_buf[offset..][0..host.len], host);
            offset += host.len;

            // :port (optional)
            if (use_port) {
                var port_str_buf: [6]u8 = undefined;
                const port_str = std.fmt.bufPrint(&port_str_buf, ":{d}", .{port}) catch unreachable;
                @memcpy(uri_buf[offset..][0..port_str.len], port_str);
                offset += port_str.len;
            }

            // /path
            uri_buf[offset] = '/';
            offset += 1;
            @memcpy(uri_buf[offset..][0..path_raw.len], path_raw);
            offset += path_raw.len;

            // ?query (optional)
            if (use_query and query.len > 0) {
                uri_buf[offset] = '?';
                offset += 1;
                @memcpy(uri_buf[offset..][0..query.len], query);
                offset += query.len;
            }

            const uri_str = uri_buf[0..offset];

            // Parse the URI
            const uri = try sig_http.parseUri(uri_str);

            // Verify all fields match
            try std.testing.expectEqualStrings(scheme, uri.scheme);
            try std.testing.expectEqualStrings(host, uri.host);
            try std.testing.expectEqual(port, uri.port);

            // Build expected path: "/" + path_raw
            var expected_path_buf: [21]u8 = undefined;
            expected_path_buf[0] = '/';
            @memcpy(expected_path_buf[1..][0..path_raw.len], path_raw);
            const expected_path = expected_path_buf[0 .. path_raw.len + 1];

            // Path may include query part if query is present, so check prefix
            if (use_query and query.len > 0) {
                try std.testing.expectEqualStrings(expected_path, uri.path);
                try std.testing.expectEqualStrings(query, uri.query);
            } else {
                try std.testing.expectEqualStrings(expected_path, uri.path);
                try std.testing.expectEqualStrings("", uri.query);
            }
        }
    };
    harness.property("parseUri extracts correct scheme, host, port, path, and query", S.run);
}
