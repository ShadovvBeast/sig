const std = @import("std");
const testing = std.testing;
const sig_http = @import("sig_http");

// ── Unit Tests for HTTP module: parseUri, buildRequest, parseResponse ────
// Requirements: 14.1, 14.2, 14.3, 14.4, 14.5, 14.6, 14.9

// ── URI parsing tests ────────────────────────────────────────────────────

test "parseUri with http://example.com/path returns scheme=http, host=example.com, port=80, path=/path" {
    const uri = try sig_http.parseUri("http://example.com/path");
    try testing.expectEqualStrings("http", uri.scheme);
    try testing.expectEqualStrings("example.com", uri.host);
    try testing.expectEqual(@as(u16, 80), uri.port);
    try testing.expectEqualStrings("/path", uri.path);
}

test "parseUri with https://example.com returns scheme=https, port=443, path=/" {
    const uri = try sig_http.parseUri("https://example.com");
    try testing.expectEqualStrings("https", uri.scheme);
    try testing.expectEqualStrings("example.com", uri.host);
    try testing.expectEqual(@as(u16, 443), uri.port);
    try testing.expectEqualStrings("/", uri.path);
}

test "parseUri with http://example.com:8080/api returns port=8080" {
    const uri = try sig_http.parseUri("http://example.com:8080/api");
    try testing.expectEqualStrings("example.com", uri.host);
    try testing.expectEqual(@as(u16, 8080), uri.port);
    try testing.expectEqualStrings("/api", uri.path);
}

test "parseUri with http://example.com/search?q=hello returns path=/search, query=q=hello" {
    const uri = try sig_http.parseUri("http://example.com/search?q=hello");
    try testing.expectEqualStrings("/search", uri.path);
    try testing.expectEqualStrings("q=hello", uri.query);
}

test "parseUri with http://host returns path=/, query empty" {
    const uri = try sig_http.parseUri("http://host");
    try testing.expectEqualStrings("host", uri.host);
    try testing.expectEqualStrings("/", uri.path);
    try testing.expectEqualStrings("", uri.query);
}

test "parseUri with invalid URI (no ://) returns error" {
    try testing.expectError(error.BufferTooSmall, sig_http.parseUri("not-a-uri"));
}

// ── Request building tests ───────────────────────────────────────────────

test "buildRequest GET produces request starting with GET /path HTTP/1.1" {
    var buf: [1024]u8 = undefined;
    const req = try sig_http.buildRequest(&buf, "GET", "example.com", "/path", &[_]sig_http.Header{}, "");
    try testing.expect(std.mem.startsWith(u8, req, "GET /path HTTP/1.1\r\n"));
}

test "buildRequest POST with body includes Content-Length header" {
    var buf: [1024]u8 = undefined;
    const body = "hello=world";
    const req = try sig_http.buildRequest(&buf, "POST", "example.com", "/submit", &[_]sig_http.Header{}, body);
    try testing.expect(std.mem.indexOf(u8, req, "Content-Length: 11\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, req, body));
}

test "buildRequest with custom headers includes them in output" {
    var buf: [1024]u8 = undefined;
    const headers = [_]sig_http.Header{
        .{ .name = "Accept", .value = "text/html" },
        .{ .name = "X-Custom", .value = "test" },
    };
    const req = try sig_http.buildRequest(&buf, "GET", "example.com", "/", &headers, "");
    try testing.expect(std.mem.indexOf(u8, req, "Accept: text/html\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "X-Custom: test\r\n") != null);
}

test "buildRequest with empty body does not include Content-Length" {
    var buf: [1024]u8 = undefined;
    const req = try sig_http.buildRequest(&buf, "GET", "example.com", "/", &[_]sig_http.Header{}, "");
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, req, "Content-Length"));
}

test "buildRequest with buffer too small returns error" {
    var buf: [5]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, sig_http.buildRequest(&buf, "GET", "example.com", "/path", &[_]sig_http.Header{}, ""));
}

// ── Response parsing tests ───────────────────────────────────────────────

test "parseResponse with 200 OK and body returns status=200, body=Hello" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nHello";
    var header_buf: [16]sig_http.Header = undefined;
    const resp = try sig_http.parseResponse(raw, &header_buf);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("Hello", resp.body);
}

test "parseResponse with 404 Not Found and empty body returns status=404, body empty" {
    const raw = "HTTP/1.1 404 Not Found\r\n\r\n";
    var header_buf: [16]sig_http.Header = undefined;
    const resp = try sig_http.parseResponse(raw, &header_buf);
    try testing.expectEqual(@as(u16, 404), resp.status);
    try testing.expectEqualStrings("", resp.body);
}

test "parseResponse with multiple headers parses all of them" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nX-Request-Id: abc123\r\nCache-Control: no-cache\r\n\r\nbody";
    var header_buf: [16]sig_http.Header = undefined;
    const resp = try sig_http.parseResponse(raw, &header_buf);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqual(@as(usize, 3), resp.headers.len);
    try testing.expectEqualStrings("body", resp.body);
}

test "parseResponse with HTTP/1.0 works correctly" {
    const raw = "HTTP/1.0 200 OK\r\n\r\nbody";
    var header_buf: [16]sig_http.Header = undefined;
    const resp = try sig_http.parseResponse(raw, &header_buf);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("body", resp.body);
}

test "parseResponse with invalid response (no HTTP prefix) returns error" {
    const raw = "INVALID 200 OK\r\n\r\n";
    var header_buf: [16]sig_http.Header = undefined;
    try testing.expectError(error.BufferTooSmall, sig_http.parseResponse(raw, &header_buf));
}

test "parseResponse with header buffer too small returns error" {
    const raw = "HTTP/1.1 200 OK\r\nH1: v1\r\nH2: v2\r\nH3: v3\r\n\r\nbody";
    var header_buf: [2]sig_http.Header = undefined;
    try testing.expectError(error.BufferTooSmall, sig_http.parseResponse(raw, &header_buf));
}
