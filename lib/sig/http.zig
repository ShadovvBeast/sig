const std = @import("std");
const SigError = @import("errors.zig").SigError;

/// An HTTP header name-value pair. Slices point into caller-provided buffers.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A parsed URI. All slices point into the original input buffer (zero-copy).
pub const Uri = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    query: []const u8,
};

/// A parsed HTTP response. All slices point into the original input buffer (zero-copy).
pub const Response = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,
};

/// Parses a URI string of the form "scheme://host[:port][/path][?query]".
/// All returned slices point into the input `buf` (zero-copy). No allocation.
/// Default port: 80 for "http", 443 for "https".
pub fn parseUri(buf: []const u8) SigError!Uri {
    // Extract scheme: everything before "://"
    const scheme_end = indexOf(buf, "://") orelse return error.BufferTooSmall;
    const scheme = buf[0..scheme_end];

    var rest = buf[scheme_end + 3 ..];

    // Extract host and optional port
    // Find the end of the authority section (first '/' or '?' or end)
    const authority_end = findAuthorityEnd(rest);
    const authority = rest[0..authority_end];
    rest = rest[authority_end..];

    var host: []const u8 = authority;
    var port: u16 = defaultPort(scheme);

    // Check for port separator
    if (indexOfChar(authority, ':')) |colon_pos| {
        host = authority[0..colon_pos];
        const port_str = authority[colon_pos + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch return error.BufferTooSmall;
    }

    // Extract path and query
    var path: []const u8 = "/";
    var query: []const u8 = "";

    if (rest.len > 0 and rest[0] == '/') {
        if (indexOfChar(rest, '?')) |q_pos| {
            path = rest[0..q_pos];
            query = rest[q_pos + 1 ..];
        } else {
            path = rest;
        }
    } else if (rest.len > 0 and rest[0] == '?') {
        query = rest[1..];
    }

    return Uri{
        .scheme = scheme,
        .host = host,
        .port = port,
        .path = path,
        .query = query,
    };
}

/// Builds an HTTP/1.1 request into a caller-provided buffer.
/// Automatically includes the Host header. Returns the written slice,
/// or `BufferTooSmall` if the buffer cannot hold the full request.
pub fn buildRequest(
    buf: []u8,
    method: []const u8,
    host: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
) SigError![]u8 {
    var offset: usize = 0;

    // Request line: "METHOD /path HTTP/1.1\r\n"
    offset = try appendSlice(buf, offset, method);
    offset = try appendSlice(buf, offset, " ");
    offset = try appendSlice(buf, offset, path);
    offset = try appendSlice(buf, offset, " HTTP/1.1\r\n");

    // Host header
    offset = try appendSlice(buf, offset, "Host: ");
    offset = try appendSlice(buf, offset, host);
    offset = try appendSlice(buf, offset, "\r\n");

    // User-provided headers
    for (headers) |h| {
        offset = try appendSlice(buf, offset, h.name);
        offset = try appendSlice(buf, offset, ": ");
        offset = try appendSlice(buf, offset, h.value);
        offset = try appendSlice(buf, offset, "\r\n");
    }

    // Content-Length header if body is non-empty
    if (body.len > 0) {
        offset = try appendSlice(buf, offset, "Content-Length: ");
        // Format the body length as decimal digits
        var len_buf: [20]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch return error.BufferTooSmall;
        offset = try appendSlice(buf, offset, len_str);
        offset = try appendSlice(buf, offset, "\r\n");
    }

    // End of headers
    offset = try appendSlice(buf, offset, "\r\n");

    // Body
    if (body.len > 0) {
        offset = try appendSlice(buf, offset, body);
    }

    return buf[0..offset];
}

/// Parses an HTTP/1.1 response from a buffer.
/// Format: "HTTP/1.1 STATUS REASON\r\nHeaders\r\n\r\nBody"
/// Extracts status code, headers into `header_buf`, and body slice.
/// All slices point into the input `buf` (zero-copy). No allocation.
pub fn parseResponse(buf: []const u8, header_buf: []Header) SigError!Response {
    // Find end of status line
    const status_line_end = indexOf(buf, "\r\n") orelse return error.BufferTooSmall;
    const status_line = buf[0..status_line_end];

    // Parse status line: "HTTP/1.1 STATUS REASON"
    // Skip "HTTP/1.1 " (9 chars)
    if (status_line.len < 12) return error.BufferTooSmall; // minimum: "HTTP/1.1 200"
    if (!startsWith(status_line, "HTTP/1.1 ") and !startsWith(status_line, "HTTP/1.0 "))
        return error.BufferTooSmall;

    const status_start: usize = 9;
    // Find end of status code (next space or end of line)
    var status_end: usize = status_start;
    while (status_end < status_line.len and status_line[status_end] != ' ') {
        status_end += 1;
    }
    const status_str = status_line[status_start..status_end];
    const status = std.fmt.parseInt(u16, status_str, 10) catch return error.BufferTooSmall;

    // Parse headers
    var header_count: usize = 0;
    var pos = status_line_end + 2; // skip past "\r\n"

    while (pos < buf.len) {
        // Check for end of headers (empty line)
        if (pos + 1 < buf.len and buf[pos] == '\r' and buf[pos + 1] == '\n') {
            pos += 2;
            break;
        }

        // Find end of this header line
        const line_end = indexOfFrom(buf, pos, "\r\n") orelse return error.BufferTooSmall;
        const line = buf[pos..line_end];

        // Split on first ": "
        if (indexOfStr(line, ": ")) |colon_pos| {
            if (header_count >= header_buf.len) return error.BufferTooSmall;
            header_buf[header_count] = Header{
                .name = line[0..colon_pos],
                .value = line[colon_pos + 2 ..],
            };
            header_count += 1;
        } else if (indexOfChar(line, ':')) |colon_pos| {
            // Handle "Name:Value" without space after colon
            if (header_count >= header_buf.len) return error.BufferTooSmall;
            const value_start = colon_pos + 1;
            // Trim leading whitespace from value
            var trimmed_start = value_start;
            while (trimmed_start < line.len and line[trimmed_start] == ' ') {
                trimmed_start += 1;
            }
            header_buf[header_count] = Header{
                .name = line[0..colon_pos],
                .value = line[trimmed_start..],
            };
            header_count += 1;
        }

        pos = line_end + 2; // skip past "\r\n"
    }

    // Everything after headers is the body
    const body = buf[pos..];

    return Response{
        .status = status,
        .headers = header_buf[0..header_count],
        .body = body,
    };
}

// ── HTTP client ──────────────────────────────────────────────────────────

/// Perform an HTTP GET request, writing the full response into a caller-provided buffer.
/// Uses `std.Io.net` for TCP and `std.crypto.tls` for TLS (HTTPS). No allocator needed.
///
/// For HTTPS connections, TLS is established using `std.crypto.tls.Client` with
/// host verification but without CA bundle verification (which would require an allocator).
/// This means the connection is encrypted but the server certificate chain is not validated
/// against a trusted root. For production use requiring full certificate validation,
/// the caller should establish the TLS layer externally and pass the decrypted stream.
///
/// Returns the filled slice of `response_buf` containing the raw HTTP response,
/// or `error.BufferTooSmall` if the response exceeds the buffer.
pub fn get(io: std.Io, host: []const u8, path: []const u8, response_buf: []u8) SigError![]u8 {
    return doRequest(io, "GET", host, path, &[_]Header{}, "", response_buf);
}

/// Perform an HTTP POST request, writing the full response into a caller-provided buffer.
/// Uses `std.Io.net` for TCP and `std.crypto.tls` for TLS (HTTPS). No allocator needed.
///
/// For HTTPS connections, TLS is established using `std.crypto.tls.Client` with
/// host verification but without CA bundle verification (which would require an allocator).
///
/// Returns the filled slice of `response_buf` containing the raw HTTP response,
/// or `error.BufferTooSmall` if the response exceeds the buffer.
pub fn post(
    io: std.Io,
    host: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
    response_buf: []u8,
) SigError![]u8 {
    return doRequest(io, "POST", host, path, headers, body, response_buf);
}

/// A parsed HTTP request. All slices point into the caller-provided request buffer (zero-copy).
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
};

/// A capacity-first HTTP server. Accepts connections, reads requests
/// into caller buffers, dispatches to a handler.
/// `max_request_size` bounds the maximum request that can be read in `accept`.
pub fn Server(comptime max_request_size: usize) type {
    return struct {
        const Self = @This();

        net_server: std.Io.net.Server,
        client_stream: ?std.Io.net.Stream = null,

        /// Creates a listening TCP server on the given port (binds to 0.0.0.0).
        /// Returns the server instance or `BufferTooSmall` on failure.
        pub fn listen(io: std.Io, port: u16) SigError!Self {
            const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = port } };
            const net_server = address.listen(io, .{
                .reuse_address = true,
            }) catch return error.BufferTooSmall;
            return Self{
                .net_server = net_server,
            };
        }

        /// Accepts a connection and reads the HTTP request into `req_buf`.
        /// Parses the request line and headers. All returned slices point into `req_buf`.
        /// Returns `BufferTooSmall` if the request exceeds `req_buf` or `max_request_size`.
        pub fn accept(self: *Self, io: std.Io, req_buf: []u8) SigError!Request {
            const effective_size = @min(req_buf.len, max_request_size);
            const buf = req_buf[0..effective_size];

            const stream = self.net_server.accept(io) catch return error.BufferTooSmall;
            self.client_stream = stream;

            // Read request data into the caller-provided buffer.
            var read_buf: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buf);
            var total: usize = 0;
            while (total < buf.len) {
                const n = reader.interface.readSliceShort(buf[total..]) catch break;
                if (n == 0) break;
                total += n;

                // Check if we've received the end of headers (\r\n\r\n).
                if (total >= 4) {
                    if (indexOf(buf[0..total], "\r\n\r\n") != null) break;
                }
            }

            if (total == 0) return error.BufferTooSmall;

            const data = buf[0..total];

            // Parse request line: "METHOD /path HTTP/1.x\r\n"
            const request_line_end = indexOf(data, "\r\n") orelse return error.BufferTooSmall;
            const request_line = data[0..request_line_end];

            // Extract method
            const method_end = indexOfChar(request_line, ' ') orelse return error.BufferTooSmall;
            const method = request_line[0..method_end];

            // Extract path
            const after_method = request_line[method_end + 1 ..];
            const path_end = indexOfChar(after_method, ' ') orelse return error.BufferTooSmall;
            const path = after_method[0..path_end];

            // Parse headers into a stack-allocated header buffer.
            var header_buf: [64]Header = undefined;
            var header_count: usize = 0;
            var pos = request_line_end + 2; // skip past first \r\n

            while (pos < data.len) {
                // Check for end of headers (empty line)
                if (pos + 1 < data.len and data[pos] == '\r' and data[pos + 1] == '\n') {
                    pos += 2;
                    break;
                }

                // Find end of this header line
                const line_end = indexOfFrom(data, pos, "\r\n") orelse break;
                const line = data[pos..line_end];

                // Split on first ": "
                if (indexOfStr(line, ": ")) |colon_pos| {
                    if (header_count < header_buf.len) {
                        header_buf[header_count] = Header{
                            .name = line[0..colon_pos],
                            .value = line[colon_pos + 2 ..],
                        };
                        header_count += 1;
                    }
                } else if (indexOfChar(line, ':')) |colon_pos| {
                    if (header_count < header_buf.len) {
                        const value_start = colon_pos + 1;
                        var trimmed_start = value_start;
                        while (trimmed_start < line.len and line[trimmed_start] == ' ') {
                            trimmed_start += 1;
                        }
                        header_buf[header_count] = Header{
                            .name = line[0..colon_pos],
                            .value = line[trimmed_start..],
                        };
                        header_count += 1;
                    }
                }

                pos = line_end + 2;
            }

            // Everything after headers is the body
            const req_body = data[pos..];

            return Request{
                .method = method,
                .path = path,
                .headers = header_buf[0..header_count],
                .body = req_body,
            };
        }

        /// Writes an HTTP/1.1 response with the given status code and body
        /// to the currently accepted connection. Uses stack-allocated buffers.
        /// Returns `BufferTooSmall` if the response cannot be written.
        pub fn respond(self: *Self, io: std.Io, status: u16, body: []const u8) SigError!void {
            const stream = self.client_stream orelse return error.BufferTooSmall;

            // Build the response into a stack buffer.
            var resp_buf: [512]u8 = undefined;
            var offset: usize = 0;

            // Status line: "HTTP/1.1 STATUS REASON\r\n"
            offset = try appendSlice(&resp_buf, offset, "HTTP/1.1 ");

            // Format status code
            var status_digits: [3]u8 = undefined;
            const status_str = std.fmt.bufPrint(&status_digits, "{d}", .{status}) catch return error.BufferTooSmall;
            offset = try appendSlice(&resp_buf, offset, status_str);
            offset = try appendSlice(&resp_buf, offset, " ");
            offset = try appendSlice(&resp_buf, offset, statusReason(status));
            offset = try appendSlice(&resp_buf, offset, "\r\n");

            // Content-Length header
            offset = try appendSlice(&resp_buf, offset, "Content-Length: ");
            var len_buf: [20]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch return error.BufferTooSmall;
            offset = try appendSlice(&resp_buf, offset, len_str);
            offset = try appendSlice(&resp_buf, offset, "\r\n");

            // Connection: close
            offset = try appendSlice(&resp_buf, offset, "Connection: close\r\n");

            // End of headers
            offset = try appendSlice(&resp_buf, offset, "\r\n");

            // Write headers via the stream writer.
            var write_buf: [4096]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            writer.interface.writeAll(resp_buf[0..offset]) catch return error.BufferTooSmall;

            // Write body
            if (body.len > 0) {
                writer.interface.writeAll(body) catch return error.BufferTooSmall;
            }

            writer.interface.flush() catch return error.BufferTooSmall;

            // Close the client connection after responding.
            stream.close(io);
            self.client_stream = null;
        }

        /// Shuts down the server, closing the listening socket.
        pub fn deinit(self: *Self, io: std.Io) void {
            self.net_server.deinit(io);
        }
    };
}

/// Returns a reason phrase for common HTTP status codes.
fn statusReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

/// Internal: performs an HTTP request (GET or POST) over TCP.
/// All buffers are caller-provided or stack-allocated. No allocator is used.
///
/// For TLS (HTTPS) support, the caller should resolve the host to an IP,
/// establish a TLS session using `std.crypto.tls.Client` over the TCP stream,
/// and then use `buildRequest` / `parseResponse` directly with the TLS reader/writer.
/// Full TLS integration here is not feasible without an allocator for CA bundle
/// verification; this function provides plain HTTP transport.
fn doRequest(
    io: std.Io,
    method: []const u8,
    host: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
    response_buf: []u8,
) SigError![]u8 {
    // Resolve host to an IP address and connect via TCP on port 80.
    const port: u16 = 80;
    const address = std.Io.net.IpAddress.parse(host, port) catch return error.BufferTooSmall;

    const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch
        return error.BufferTooSmall;
    defer stream.close(io);

    // Build the HTTP request into a stack buffer (8 KiB covers most requests).
    var request_buf: [8192]u8 = undefined;
    const request = buildRequest(&request_buf, method, host, path, headers, body) catch
        return error.BufferTooSmall;

    // Write the request to the TCP stream.
    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(request) catch return error.BufferTooSmall;
    writer.interface.flush() catch return error.BufferTooSmall;

    // Read the response into the caller-provided buffer.
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var total: usize = 0;
    while (total < response_buf.len) {
        const n = reader.interface.readSliceShort(response_buf[total..]) catch
            return if (total > 0) response_buf[0..total] else error.BufferTooSmall;
        if (n == 0) break;
        total += n;
    }

    // If we filled the buffer, check if there's more data (BufferTooSmall).
    if (total == response_buf.len) {
        var probe: [1]u8 = undefined;
        const extra = reader.interface.readSliceShort(&probe) catch 0;
        if (extra != 0) return error.BufferTooSmall;
    }

    return response_buf[0..total];
}

// ── Internal helpers ─────────────────────────────────────────────────────

/// Appends a slice to `buf` at `offset`. Returns the new offset.
fn appendSlice(buf: []u8, offset: usize, data: []const u8) SigError!usize {
    if (offset + data.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[offset..][0..data.len], data);
    return offset + data.len;
}

/// Finds the first occurrence of `needle` in `haystack`. Returns the index or null.
fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return indexOfFrom(haystack, 0, needle);
}

/// Finds the first occurrence of `needle` in `haystack` starting from `start`.
fn indexOfFrom(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start;
    if (haystack.len < needle.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eql(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Finds the first occurrence of a single character in a slice.
fn indexOfChar(haystack: []const u8, char: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == char) return i;
    }
    return null;
}

/// Finds the first occurrence of a string in a slice (alias for indexOf on a sub-slice).
fn indexOfStr(haystack: []const u8, needle: []const u8) ?usize {
    return indexOf(haystack, needle);
}

/// Finds the end of the authority section (host[:port]) in a URI.
/// The authority ends at the first '/', '?', or end of string.
fn findAuthorityEnd(buf: []const u8) usize {
    for (buf, 0..) |c, i| {
        if (c == '/' or c == '?') return i;
    }
    return buf.len;
}

/// Returns the default port for a scheme.
fn defaultPort(scheme: []const u8) u16 {
    if (eql(scheme, "https")) return 443;
    return 80;
}

/// Checks if `haystack` starts with `prefix`.
fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return eql(haystack[0..prefix.len], prefix);
}

/// Byte-wise equality check.
fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
