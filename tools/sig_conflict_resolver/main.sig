const std = @import("std");
const sig = @import("sig");
const sig_http = sig.http;
const sig_json = sig.json;
const sig_fmt = sig.fmt;
const validator = @import("validator.sig");
const prompt_mod = @import("prompt.sig");

/// Sig Conflict Resolver — Cloud Run service (pure Sig, zero allocators)
///
/// Listens on $PORT via sig.http.Server. Accepts POST /resolve requests
/// containing batched conflicted files from a single commit. Calls Gemini
/// via Vertex AI to resolve all conflicts in one API call. Returns per-file
/// results with status, confidence, explanation, and resolved content.
///
/// Environment variables:
///   PORT          — HTTP listen port (set by Cloud Run, default 8080)
///   GEMINI_MODEL  — Gemini model name (default "gemini-2.0-flash")
///   GCP_PROJECT   — GCP project ID (default "sbzero")
///   GCP_REGION    — GCP region (default "us-central1")
///
/// Requirements: 19.1, 19.2, 19.3, 19.4, 19.5, 19.6, 19.7,
///               20.1, 20.2, 20.3, 20.4, 20.5, 20.6, 23.2, 23.3

// ── Constants ────────────────────────────────────────────────────────────

const MAX_FILES = 32;
const MAX_FILE_PATH = 512;
const MAX_CONTENT_SIZE = 65536;
const MAX_EXPLANATION_SIZE = 1024;
const METADATA_HOST = "metadata.google.internal";
const METADATA_PATH = "/computeMetadata/v1/instance/service-accounts/default/token";

// ── Parsed Request Types ─────────────────────────────────────────────────

const FileEntry = struct {
    file_path_buf: [MAX_FILE_PATH]u8 = undefined,
    file_path_len: usize = 0,
    content_buf: [MAX_CONTENT_SIZE]u8 = undefined,
    content_len: usize = 0,

    fn filePath(self: *const FileEntry) []const u8 {
        return self.file_path_buf[0..self.file_path_len];
    }

    fn content(self: *const FileEntry) []const u8 {
        return self.content_buf[0..self.content_len];
    }
};

const ResolveRequest = struct {
    files: [MAX_FILES]FileEntry = undefined,
    file_count: usize = 0,
    upstream_commit_buf: [64]u8 = undefined,
    upstream_commit_len: usize = 0,
    sig_commit_buf: [64]u8 = undefined,
    sig_commit_len: usize = 0,
    confidence_threshold: u8 = 80,

    fn upstreamCommit(self: *const ResolveRequest) []const u8 {
        return self.upstream_commit_buf[0..self.upstream_commit_len];
    }

    fn sigCommit(self: *const ResolveRequest) []const u8 {
        return self.sig_commit_buf[0..self.sig_commit_len];
    }
};

// ── Per-File Result ──────────────────────────────────────────────────────

const FileResult = struct {
    file_path_buf: [MAX_FILE_PATH]u8 = undefined,
    file_path_len: usize = 0,
    resolved_content_buf: [MAX_CONTENT_SIZE]u8 = undefined,
    resolved_content_len: usize = 0,
    confidence: u8 = 0,
    explanation_buf: [MAX_EXPLANATION_SIZE]u8 = undefined,
    explanation_len: usize = 0,
    status_buf: [16]u8 = undefined,
    status_len: usize = 0,

    fn filePath(self: *const FileResult) []const u8 {
        return self.file_path_buf[0..self.file_path_len];
    }

    fn resolvedContent(self: *const FileResult) []const u8 {
        return self.resolved_content_buf[0..self.resolved_content_len];
    }

    fn explanation(self: *const FileResult) []const u8 {
        return self.explanation_buf[0..self.explanation_len];
    }

    fn status(self: *const FileResult) []const u8 {
        return self.status_buf[0..self.status_len];
    }
};

// ── Main ─────────────────────────────────────────────────────────────────

pub fn main() !void {
    const port_str = std.posix.getenv("PORT") orelse "8080";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8080;

    const io = std.process.Init.io();
    var server = sig_http.Server(131072).listen(io, port) catch {
        log("Failed to listen on port {d}", .{port});
        return;
    };
    defer server.deinit(io);

    log("sig-conflict-resolver listening on port {d}", .{port});

    while (true) {
        var req_buf: [131072]u8 = undefined;
        const request = server.accept(io, &req_buf) catch continue;

        handleRequest(io, &server, request);
    }
}

// ── Request Handler ──────────────────────────────────────────────────────

fn handleRequest(io: std.Io, server: anytype, request: sig_http.Request) void {
    // Only accept POST /resolve
    if (!eql(request.method, "POST") or !eql(request.path, "/resolve")) {
        server.respond(io, 404, "{\"error\":\"Not found\"}") catch {};
        return;
    }

    // Parse the JSON request body
    var req = ResolveRequest{};
    parseResolveRequest(request.body, &req) catch {
        server.respond(io, 400, "{\"error\":\"Invalid request JSON\"}") catch {};
        return;
    };

    if (req.file_count == 0) {
        server.respond(io, 400, "{\"error\":\"No files provided\"}") catch {};
        return;
    }

    log("Resolving {d} files for upstream={s}", .{ req.file_count, req.upstreamCommit() });

    // Obtain GCP access token from metadata server
    var token_buf: [2048]u8 = undefined;
    const access_token = getAccessToken(&token_buf) catch {
        // On auth failure, return error for all files
        var err_resp_buf: [65536]u8 = undefined;
        const err_resp = buildErrorResponse(&req, "Failed to obtain GCP access token", &err_resp_buf) catch {
            server.respond(io, 500, "{\"error\":\"Internal error\"}") catch {};
            return;
        };
        server.respond(io, 500, err_resp) catch {};
        return;
    };

    // Build Gemini API request and call Vertex AI
    var results: [MAX_FILES]FileResult = undefined;
    var result_count: usize = 0;

    callGemini(&req, access_token, &results, &result_count) catch {
        // On Gemini API error, return error status for all files with original content
        var err_resp_buf: [65536]u8 = undefined;
        const err_resp = buildErrorResponse(&req, "Gemini API call failed", &err_resp_buf) catch {
            server.respond(io, 500, "{\"error\":\"Internal error\"}") catch {};
            return;
        };
        server.respond(io, 200, err_resp) catch {};
        return;
    };

    // Validate each result and build response
    var resp_buf: [262144]u8 = undefined;
    const response = buildSuccessResponse(&req, &results, result_count, &resp_buf) catch {
        server.respond(io, 500, "{\"error\":\"Response too large\"}") catch {};
        return;
    };

    server.respond(io, 200, response) catch {};
}

// ── JSON Request Parsing ─────────────────────────────────────────────────

fn parseResolveRequest(body: []const u8, req: *ResolveRequest) !void {
    // Extract top-level fields
    var commit_buf: [64]u8 = undefined;

    const upstream = sig_json.extractString(body, "upstream_commit", &commit_buf) catch
        return error.BufferTooSmall;
    if (upstream.len > req.upstream_commit_buf.len) return error.BufferTooSmall;
    @memcpy(req.upstream_commit_buf[0..upstream.len], upstream);
    req.upstream_commit_len = upstream.len;

    var sig_commit_tmp: [64]u8 = undefined;
    const sig_c = sig_json.extractString(body, "sig_commit", &sig_commit_tmp) catch
        return error.BufferTooSmall;
    if (sig_c.len > req.sig_commit_buf.len) return error.BufferTooSmall;
    @memcpy(req.sig_commit_buf[0..sig_c.len], sig_c);
    req.sig_commit_len = sig_c.len;

    const threshold = sig_json.extractInt(body, "confidence_threshold") catch 80;
    req.confidence_threshold = @intCast(std.math.clamp(threshold, 0, 100));

    // Parse "files" array manually — walk the JSON to find each object
    const files_start = findArrayStart(body, "files") orelse return error.BufferTooSmall;
    var pos = files_start;
    var count: usize = 0;

    while (pos < body.len and count < MAX_FILES) {
        // Find next object start
        const obj_start = indexOfCharFrom(body, pos, '{') orelse break;
        const obj_end = findMatchingBrace(body, obj_start) orelse break;
        const obj_slice = body[obj_start .. obj_end + 1];

        // Extract file_path and conflicted_content from this object
        const fp = sig_json.extractString(obj_slice, "file_path", &req.files[count].file_path_buf) catch
            return error.BufferTooSmall;
        req.files[count].file_path_len = fp.len;

        const cc = sig_json.extractString(obj_slice, "conflicted_content", &req.files[count].content_buf) catch
            return error.BufferTooSmall;
        req.files[count].content_len = cc.len;

        count += 1;
        pos = obj_end + 1;
    }

    req.file_count = count;
}


// ── GCP Access Token ─────────────────────────────────────────────────────

fn getAccessToken(out: []u8) ![]const u8 {
    // Build request to metadata server (HTTP, not HTTPS)
    var req_buf: [1024]u8 = undefined;
    const request = sig_http.buildRequest(
        &req_buf,
        "GET",
        METADATA_HOST,
        METADATA_PATH,
        &[_]sig_http.Header{
            .{ .name = "Metadata-Flavor", .value = "Google" },
            .{ .name = "Connection", .value = "close" },
        },
        "",
    ) catch return error.BufferTooSmall;

    // Metadata server is plain HTTP on port 80
    var resp_buf: [4096]u8 = undefined;
    const resp_data = tcpHttpRaw(METADATA_HOST, 80, request, &resp_buf) catch
        return error.BufferTooSmall;

    // Parse HTTP response to get body
    var headers: [16]sig_http.Header = undefined;
    const parsed = sig_http.parseResponse(resp_data, &headers) catch return error.BufferTooSmall;

    if (parsed.status != 200) return error.BufferTooSmall;

    // Extract access_token from JSON body: {"access_token":"...","expires_in":...,"token_type":"Bearer"}
    const token = sig_json.extractString(parsed.body, "access_token", out) catch
        return error.BufferTooSmall;
    return token;
}

// ── Gemini API Call ──────────────────────────────────────────────────────

fn callGemini(
    req: *const ResolveRequest,
    access_token: []const u8,
    results: []FileResult,
    result_count: *usize,
) !void {
    const model = std.posix.getenv("GEMINI_MODEL") orelse "gemini-2.0-flash";
    const project = std.posix.getenv("GCP_PROJECT") orelse "sbzero";
    const region = std.posix.getenv("GCP_REGION") orelse "us-central1";

    // Build Vertex AI endpoint path
    // Format: /v1/projects/{PROJECT}/locations/{REGION}/publishers/google/models/{MODEL}:generateContent
    var path_buf: [512]u8 = undefined;
    const api_path = sig_fmt.formatInto(
        &path_buf,
        "/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:generateContent",
        .{ project, region, model },
    ) catch return error.BufferTooSmall;

    // Build API host: {REGION}-aiplatform.googleapis.com
    var host_buf: [128]u8 = undefined;
    const api_host = sig_fmt.formatInto(
        &host_buf,
        "{s}-aiplatform.googleapis.com",
        .{region},
    ) catch return error.BufferTooSmall;

    // Build the Gemini request body JSON
    var body_buf: [262144]u8 = undefined;
    const gemini_body = buildGeminiRequestBody(req, &body_buf) catch return error.BufferTooSmall;

    // Build auth header
    var auth_buf: [2048]u8 = undefined;
    const auth_value = sig_fmt.formatInto(&auth_buf, "Bearer {s}", .{access_token}) catch
        return error.BufferTooSmall;

    // Build HTTP request
    var http_req_buf: [262144]u8 = undefined;
    const http_request = sig_http.buildRequest(
        &http_req_buf,
        "POST",
        api_host,
        api_path,
        &[_]sig_http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "sig-conflict-resolver/1.0" },
        },
        gemini_body,
    ) catch return error.BufferTooSmall;

    // Connect via TLS to Vertex AI
    var gemini_resp_buf: [262144]u8 = undefined;
    const resp_data = tcpHttpsRaw(api_host, http_request, &gemini_resp_buf) catch
        return error.BufferTooSmall;

    // Parse HTTP response
    var resp_headers: [32]sig_http.Header = undefined;
    const parsed = sig_http.parseResponse(resp_data, &resp_headers) catch return error.BufferTooSmall;

    if (parsed.status != 200) {
        log("Gemini API returned status {d}", .{parsed.status});
        return error.BufferTooSmall;
    }

    // Parse the Gemini structured JSON response
    parseGeminiResponse(parsed.body, req, results, result_count) catch return error.BufferTooSmall;
}


// ── Gemini Request Body Builder ──────────────────────────────────────────

fn buildGeminiRequestBody(req: *const ResolveRequest, buf: []u8) ![]const u8 {
    var w = sig_json.Writer.initCompact(buf);

    try w.beginObject();

    // contents array with single user message
    try w.objectField("contents");
    try w.beginArray();
    try w.beginObject();
    try w.objectField("role");
    try w.writeString("user");
    try w.objectField("parts");
    try w.beginArray();
    try w.beginObject();
    try w.objectField("text");

    // Build the prompt text: system prompt + all files
    var prompt_buf: [131072]u8 = undefined;
    const prompt_text = buildBatchedPrompt(req, &prompt_buf) catch return error.BufferTooSmall;
    try w.writeString(prompt_text);

    try w.endObject(); // parts[0]
    try w.endArray(); // parts
    try w.endObject(); // contents[0]
    try w.endArray(); // contents

    // systemInstruction
    try w.objectField("systemInstruction");
    try w.beginObject();
    try w.objectField("parts");
    try w.beginArray();
    try w.beginObject();
    try w.objectField("text");
    try w.writeString(prompt_mod.SYSTEM_PROMPT);
    try w.endObject();
    try w.endArray();
    try w.endObject();

    // generationConfig with structured output
    try w.objectField("generationConfig");
    try w.beginObject();

    try w.objectField("temperature");
    // Write raw float value — Writer only has writeInt, so write directly
    if (w.needs_comma) {
        if (w.pos >= w.buf.len) return error.BufferTooSmall;
        w.buf[w.pos] = ',';
        w.pos += 1;
    }
    const temp_str = "0.1";
    if (w.pos + temp_str.len > w.buf.len) return error.BufferTooSmall;
    @memcpy(w.buf[w.pos..][0..temp_str.len], temp_str);
    w.pos += temp_str.len;
    w.needs_comma = true;

    try w.objectField("responseMimeType");
    try w.writeString("application/json");

    // responseSchema — enforce exact output shape
    try w.objectField("responseSchema");
    try w.beginObject();
    try w.objectField("type");
    try w.writeString("ARRAY");
    try w.objectField("items");
    try w.beginObject();
    try w.objectField("type");
    try w.writeString("OBJECT");
    try w.objectField("properties");
    try w.beginObject();

    // file_path
    try w.objectField("file_path");
    try w.beginObject();
    try w.objectField("type");
    try w.writeString("STRING");
    try w.endObject();

    // resolved_content
    try w.objectField("resolved_content");
    try w.beginObject();
    try w.objectField("type");
    try w.writeString("STRING");
    try w.endObject();

    // confidence
    try w.objectField("confidence");
    try w.beginObject();
    try w.objectField("type");
    try w.writeString("INTEGER");
    try w.endObject();

    // explanation
    try w.objectField("explanation");
    try w.beginObject();
    try w.objectField("type");
    try w.writeString("STRING");
    try w.endObject();

    // status
    try w.objectField("status");
    try w.beginObject();
    try w.objectField("type");
    try w.writeString("STRING");
    try w.objectField("enum");
    try w.beginArray();
    try w.writeString("resolved");
    try w.writeString("unresolved");
    try w.writeString("error");
    try w.endArray();
    try w.endObject();

    try w.endObject(); // properties
    try w.objectField("required");
    try w.beginArray();
    try w.writeString("file_path");
    try w.writeString("resolved_content");
    try w.writeString("confidence");
    try w.writeString("explanation");
    try w.writeString("status");
    try w.endArray();
    try w.endObject(); // items
    try w.endObject(); // responseSchema

    try w.endObject(); // generationConfig

    try w.endObject(); // root

    return w.written();
}

/// Build a single prompt containing all files for batched resolution.
fn buildBatchedPrompt(req: *const ResolveRequest, buf: []u8) ![]const u8 {
    var offset: usize = 0;

    const header = "Resolve the merge conflicts in the following files. " ++
        "Return a JSON array with one entry per file.\n\n";
    offset = try appendBuf(buf, offset, header);

    var commit_info_buf: [256]u8 = undefined;
    const commit_info = sig_fmt.formatInto(
        &commit_info_buf,
        "Upstream commit: {s}\nSig commit: {s}\n\n",
        .{ req.upstreamCommit(), req.sigCommit() },
    ) catch return error.BufferTooSmall;
    offset = try appendBuf(buf, offset, commit_info);

    var i: usize = 0;
    while (i < req.file_count) : (i += 1) {
        const file = &req.files[i];

        var file_header_buf: [1024]u8 = undefined;
        const file_header = sig_fmt.formatInto(
            &file_header_buf,
            "--- File {d}/{d}: {s} ---\n```\n",
            .{ i + 1, req.file_count, file.filePath() },
        ) catch return error.BufferTooSmall;
        offset = try appendBuf(buf, offset, file_header);

        offset = try appendBuf(buf, offset, file.content());
        offset = try appendBuf(buf, offset, "\n```\n\n");
    }

    return buf[0..offset];
}


// ── Gemini Response Parsing ──────────────────────────────────────────────

fn parseGeminiResponse(
    body: []const u8,
    req: *const ResolveRequest,
    results: []FileResult,
    result_count: *usize,
) !void {
    // Gemini structured output returns JSON in candidates[0].content.parts[0].text
    // The text field contains our structured JSON array
    var text_buf: [131072]u8 = undefined;
    const json_text = sig_json.extractString(body, "text", &text_buf) catch
        return error.BufferTooSmall;

    // Now parse the structured array from the text field
    // Walk through the JSON array finding each object
    var pos: usize = 0;
    var count: usize = 0;

    // Skip to first '['
    while (pos < json_text.len and json_text[pos] != '[') : (pos += 1) {}
    if (pos >= json_text.len) return error.BufferTooSmall;
    pos += 1; // skip '['

    while (pos < json_text.len and count < req.file_count and count < results.len) {
        // Find next object
        const obj_start = indexOfCharFrom(json_text, pos, '{') orelse break;
        const obj_end = findMatchingBrace(json_text, obj_start) orelse break;
        const obj = json_text[obj_start .. obj_end + 1];

        var result = &results[count];

        // Extract file_path
        const fp = sig_json.extractString(obj, "file_path", &result.file_path_buf) catch {
            // If we can't parse, skip
            pos = obj_end + 1;
            continue;
        };
        result.file_path_len = fp.len;

        // Extract resolved_content
        const rc = sig_json.extractString(obj, "resolved_content", &result.resolved_content_buf) catch {
            pos = obj_end + 1;
            continue;
        };
        result.resolved_content_len = rc.len;

        // Extract confidence (0-100)
        const conf = sig_json.extractInt(obj, "confidence") catch 0;
        result.confidence = @intCast(std.math.clamp(conf, 0, 100));

        // Extract explanation
        const expl = sig_json.extractString(obj, "explanation", &result.explanation_buf) catch {
            // Explanation is optional for parsing purposes
            result.explanation_len = 0;
            pos = obj_end + 1;
            count += 1;
            continue;
        };
        result.explanation_len = expl.len;

        // Extract status
        const st = sig_json.extractString(obj, "status", &result.status_buf) catch {
            @memcpy(result.status_buf[0..5], "error");
            result.status_len = 5;
            pos = obj_end + 1;
            count += 1;
            continue;
        };
        result.status_len = st.len;

        count += 1;
        pos = obj_end + 1;
    }

    result_count.* = count;
}

// ── Response Builders ────────────────────────────────────────────────────

fn buildSuccessResponse(
    req: *const ResolveRequest,
    results: []FileResult,
    result_count: usize,
    buf: []u8,
) ![]const u8 {
    var w = sig_json.Writer.initCompact(buf);

    try w.beginObject();
    try w.objectField("results");
    try w.beginArray();

    var i: usize = 0;
    while (i < result_count) : (i += 1) {
        var result = &results[i];

        // Validate resolved content
        const validation = validator.validateResolvedContent(result.resolvedContent());

        try w.beginObject();
        try w.objectField("file_path");
        try w.writeString(result.filePath());

        if (!validation.valid) {
            // Validation failed — reject and return original content
            const orig = findOriginalContent(req, result.filePath());
            try w.objectField("resolved_content");
            try w.writeString(orig);
            try w.objectField("confidence");
            try w.writeInt(0);
            try w.objectField("explanation");
            if (validation.has_conflict_markers) {
                try w.writeString("Rejected: resolved content still contains conflict markers");
            } else {
                try w.writeString("Rejected: resolved content contains invalid UTF-8");
            }
            try w.objectField("status");
            try w.writeString("error");
        } else {
            // Valid resolution
            try w.objectField("resolved_content");
            try w.writeString(result.resolvedContent());
            try w.objectField("confidence");
            try w.writeInt(@as(i64, result.confidence));
            try w.objectField("explanation");
            try w.writeString(result.explanation());
            try w.objectField("status");
            try w.writeString(result.status());
        }

        try w.endObject();
    }

    try w.endArray();
    try w.endObject();

    return w.written();
}

fn buildErrorResponse(req: *const ResolveRequest, reason: []const u8, buf: []u8) ![]const u8 {
    var w = sig_json.Writer.initCompact(buf);

    try w.beginObject();
    try w.objectField("results");
    try w.beginArray();

    var i: usize = 0;
    while (i < req.file_count) : (i += 1) {
        const file = &req.files[i];

        try w.beginObject();
        try w.objectField("file_path");
        try w.writeString(file.filePath());
        try w.objectField("resolved_content");
        try w.writeString(file.content());
        try w.objectField("confidence");
        try w.writeInt(0);
        try w.objectField("explanation");
        try w.writeString(reason);
        try w.objectField("status");
        try w.writeString("error");
        try w.endObject();
    }

    try w.endArray();
    try w.endObject();

    return w.written();
}

/// Find the original conflicted content for a file path from the request.
fn findOriginalContent(req: *const ResolveRequest, file_path: []const u8) []const u8 {
    var i: usize = 0;
    while (i < req.file_count) : (i += 1) {
        if (eql(req.files[i].filePath(), file_path)) {
            return req.files[i].content();
        }
    }
    return "";
}


// ── Raw TCP/TLS Transport ─────────────────────────────────────────────────

/// Perform a raw HTTPS request via TCP + TLS. Same pattern as sig_sync_watcher.
fn tcpHttpsRaw(host: []const u8, request: []const u8, buf: []u8) ![]const u8 {
    const addr = try std.net.Address.resolveIp(host, 443);
    const sock = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());

    var tls_client = try std.crypto.tls.Client(@TypeOf(sock)).init(sock, .{
        .host = host,
    });
    defer tls_client.close() catch {};

    try tls_client.writeAll(request);

    var total: usize = 0;
    while (total < buf.len) {
        const n = tls_client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    return buf[0..total];
}

/// Perform a raw HTTP request via TCP (no TLS). Used for GCP metadata server.
fn tcpHttpRaw(host: []const u8, port: u16, request: []const u8, buf: []u8) ![]const u8 {
    const addr = try std.net.Address.resolveIp(host, port);
    const sock = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());

    // Write request
    var sent: usize = 0;
    while (sent < request.len) {
        const n = std.posix.write(sock, request[sent..]) catch break;
        if (n == 0) break;
        sent += n;
    }

    // Read response
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(sock, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    return buf[0..total];
}

// ── Helper Functions ─────────────────────────────────────────────────────

/// Find the start of a JSON array value for a given key.
/// Returns the index of the '[' character.
fn findArrayStart(json: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    while (i + key.len + 2 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 ..][0..key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            var j = i + 1 + key.len + 1;
            // Skip whitespace and colon
            while (j < json.len and (json[j] == ' ' or json[j] == ':' or
                json[j] == '\n' or json[j] == '\r' or json[j] == '\t')) : (j += 1)
            {}
            if (j < json.len and json[j] == '[') return j;
        }
    }
    return null;
}

/// Find the matching closing brace for an opening '{' at the given position.
fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '{') return null;
    var depth: usize = 0;
    var i = start;
    var in_string = false;
    while (i < json.len) : (i += 1) {
        if (in_string) {
            if (json[i] == '\\' and i + 1 < json.len) {
                i += 1; // skip escaped char
                continue;
            }
            if (json[i] == '"') in_string = false;
            continue;
        }
        switch (json[i]) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Find first occurrence of a character starting from a position.
fn indexOfCharFrom(data: []const u8, start: usize, char: u8) ?usize {
    var i = start;
    while (i < data.len) : (i += 1) {
        if (data[i] == char) return i;
    }
    return null;
}

/// Append a slice to a buffer at offset. Returns new offset.
fn appendBuf(buf: []u8, offset: usize, data: []const u8) !usize {
    if (offset + data.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[offset..][0..data.len], data);
    return offset + data.len;
}

/// Byte-wise equality check.
fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// ── Logging ──────────────────────────────────────────────────────────────

fn log(comptime fmt_str: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr();
    stderr.writer().print("[sig-conflict-resolver] " ++ fmt_str ++ "\n", args) catch {};
}
