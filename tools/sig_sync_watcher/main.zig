const std = @import("std");
const sig = @import("sig");
const sig_http = sig.http;
const sig_fmt = sig.fmt;

/// Sig Sync Watcher — Cloud Run service (pure Sig, zero allocators)
///
/// Listens on $PORT via sig.http.Server. On each request (Cloud Scheduler ~30s):
///   1. Fetches the Codeberg RSS feed for ziglang/zig master branch
///   2. Extracts the latest commit hash from the first <link> element
///   3. Compares to the last known hash (in-memory, survives warm invocations)
///   4. If new commit detected → fires repository_dispatch to GitHub
///   5. Returns 200 with status text
///
/// Environment variables:
///   PORT              — HTTP listen port (set by Cloud Run, default 8080)
///   GITHUB_TOKEN      — Personal access token with repo scope
///   GITHUB_REPO       — e.g. "ShadovvBeast/sig"

// ── Configuration ────────────────────────────────────────────────────────

const rss_host = "codeberg.org";
const rss_path = "/ziglang/zig/rss/branch/master";
const github_api_host = "api.github.com";

// ── State (persists across warm invocations) ─────────────────────────────

var last_known_commit: [40]u8 = .{0} ** 40;
var last_known_len: usize = 0;

// ── Main ─────────────────────────────────────────────────────────────────

pub fn main() !void {
    const port_str = std.posix.getenv("PORT") orelse "8080";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8080;

    if (std.posix.getenv("LAST_KNOWN_COMMIT")) |seed| {
        if (seed.len == 40) {
            @memcpy(&last_known_commit, seed[0..40]);
            last_known_len = 40;
        }
    }

    const io = std.process.Init.io();
    var server = sig_http.Server(8192).listen(io, port) catch {
        log("Failed to listen on port {d}", .{port});
        return;
    };
    defer server.deinit(io);

    log("sig-sync-watcher listening on port {d}", .{port});

    while (true) {
        var req_buf: [4096]u8 = undefined;
        const request = server.accept(io, &req_buf) catch continue;
        _ = request; // We don't inspect the request, just handle it.

        handleRequest(io, &server);
    }
}

// ── Request Handler ──────────────────────────────────────────────────────

fn handleRequest(io: std.Io, server: anytype) void {
    const github_token = std.posix.getenv("GITHUB_TOKEN") orelse "";
    const github_repo = std.posix.getenv("GITHUB_REPO") orelse "ShadovvBeast/sig";

    // 1. Fetch RSS feed
    var rss_buf: [32768]u8 = undefined;
    const rss_data = fetchRss(&rss_buf) catch {
        server.respond(io, 502, "Failed to fetch RSS feed") catch {};
        return;
    };

    // 2. Extract latest commit hash
    var hash_buf: [40]u8 = undefined;
    const latest_hash = extractLatestCommitHash(rss_data, &hash_buf) orelse {
        server.respond(io, 502, "Failed to parse commit hash from RSS") catch {};
        return;
    };

    // 3. Compare to last known
    if (last_known_len == 40 and std.mem.eql(u8, latest_hash, &last_known_commit)) {
        server.respond(io, 200, "No new commits") catch {};
        return;
    }

    // 4. New commit — update state
    log("New commit: {s}", .{latest_hash});
    @memcpy(&last_known_commit, latest_hash);
    last_known_len = 40;

    // 5. Fire repository_dispatch
    if (github_token.len == 0) {
        server.respond(io, 200, "New commit but no GITHUB_TOKEN") catch {};
        return;
    }

    fireRepositoryDispatch(github_token, github_repo) catch {
        server.respond(io, 502, "Failed to trigger dispatch") catch {};
        return;
    };

    server.respond(io, 200, "Triggered sync for new commit") catch {};
}

// ── RSS Fetch (raw TCP + TLS, request built via sig.http.buildRequest) ───

fn fetchRss(buf: []u8) ![]const u8 {
    var req_buf: [1024]u8 = undefined;
    const request = sig_http.buildRequest(
        &req_buf,
        "GET",
        rss_host,
        rss_path,
        &[_]sig_http.Header{
            .{ .name = "User-Agent", .value = "sig-sync-watcher/1.0" },
            .{ .name = "Connection", .value = "close" },
        },
        "",
    ) catch return error.BufferTooSmall;

    return tcpHttpsRaw(rss_host, request, buf);
}

// ── Commit Hash Extraction ───────────────────────────────────────────────

fn extractLatestCommitHash(rss: []const u8, out: *[40]u8) ?[]const u8 {
    const item_start = std.mem.indexOf(u8, rss, "<item>") orelse return null;
    const after_item = rss[item_start..];

    const link_tag = std.mem.indexOf(u8, after_item, "<link>") orelse return null;
    const content_start = link_tag + 6;
    const remaining = after_item[content_start..];

    const link_end = std.mem.indexOf(u8, remaining, "</link>") orelse return null;
    const link_url = remaining[0..link_end];

    if (link_url.len < 40) return null;
    const hash = link_url[link_url.len - 40 ..][0..40];

    for (hash) |c| {
        if (!isHex(c)) return null;
    }

    @memcpy(out, hash);
    return out;
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// ── GitHub API Dispatch (request built via sig.http.buildRequest) ─────────

fn fireRepositoryDispatch(token: []const u8, repo: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = sig_fmt.formatInto(&path_buf, "/repos/{s}/dispatches", .{repo}) catch return error.BufferTooSmall;

    var auth_buf: [256]u8 = undefined;
    const auth = sig_fmt.formatInto(&auth_buf, "Bearer {s}", .{token}) catch return error.BufferTooSmall;

    const body = "{\"event_type\":\"upstream-push\"}";

    var req_buf: [2048]u8 = undefined;
    const request = sig_http.buildRequest(
        &req_buf,
        "POST",
        github_api_host,
        path,
        &[_]sig_http.Header{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "User-Agent", .value = "sig-sync-watcher/1.0" },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        body,
    ) catch return error.BufferTooSmall;

    var resp_buf: [4096]u8 = undefined;
    const resp = tcpHttpsRaw(github_api_host, request, &resp_buf) catch return error.ConnectionFailed;

    // Parse response using sig.http.parseResponse
    var headers: [32]sig_http.Header = undefined;
    const parsed = sig_http.parseResponse(resp, &headers) catch {
        log("Failed to parse GitHub response", .{});
        return error.GitHubApiError;
    };

    if (parsed.status == 204 or parsed.status == 200) {
        log("repository_dispatch triggered successfully", .{});
    } else {
        log("GitHub API unexpected status: {d}", .{parsed.status});
        return error.GitHubApiError;
    }
}

// ── Raw TLS transport ────────────────────────────────────────────────────

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

// ── Logging ──────────────────────────────────────────────────────────────

fn log(comptime fmt_str: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr();
    stderr.writer().print("[sig-sync-watcher] " ++ fmt_str ++ "\n", args) catch {};
}
