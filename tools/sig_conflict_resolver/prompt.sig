// Sig Conflict Resolver — Sig-Aware Prompt Construction
//
// Builds LLM prompts for AI-powered merge conflict resolution.
// Encodes all Sig conventions so the model understands how Sig
// modifies files alongside upstream Zig code.
//
// Zero allocators. Prompt is built into a caller-provided stack buffer
// using inline byte copying (no sig module dependencies, same pattern
// as validator.sig).
//
// Requirements: 20.1, 20.2, 20.3, 20.4, 20.5, 20.6

const std = @import("std");

// ── Error ────────────────────────────────────────────────────────────────

pub const PromptError = error{BufferTooSmall};

// ── System Prompt ────────────────────────────────────────────────────────

/// Comptime string literal encoding all Sig conventions for the LLM.
pub const SYSTEM_PROMPT =
    \\You are resolving Git merge conflicts in the Sig repository.
    \\Sig is a memory-model layer on top of Zig. It never modifies upstream
    \\Zig lines — it only adds code alongside them, marked with [sig] comments.
    \\
    \\## Sig Conventions
    \\
    \\1. Sig NEVER modifies upstream lines. It only adds code alongside them
    \\   using [sig] comment markers.
    \\2. All [sig] comment markers MUST be preserved in the resolved output.
    \\3. Sig code blocks (delimited by [sig] markers) must stay adjacent to
    \\   the upstream code they extend.
    \\4. Accept ALL upstream changes verbatim. Re-position Sig additions
    \\   alongside the updated upstream code.
    \\5. If a conflict region contains ONLY upstream code (no [sig] markers),
    \\   accept the upstream version as-is.
    \\
    \\## Example
    \\
    \\Before (conflicted):
    \\```
    \\<<<<<<< HEAD
    \\pub fn parse(input: []const u8) !Result {
    \\    // [sig] capacity-first parse
    \\    return parseInto(input, &stack_buf);
    \\=======
    \\pub fn parse(allocator: Allocator, input: []const u8) !Result {
    \\    return allocator.create(Result);
    \\>>>>>>> upstream/main
    \\```
    \\
    \\After (resolved):
    \\```
    \\pub fn parse(allocator: Allocator, input: []const u8) !Result {
    \\    return allocator.create(Result);
    \\}
    \\// [sig] capacity-first parse
    \\pub fn sigParse(input: []const u8, buf: []u8) SigError!Result {
    \\    return parseInto(input, buf);
    \\}
    \\```
    \\
    \\The upstream function signature changed. The Sig addition was repositioned
    \\as a separate function alongside the upstream code, preserving the [sig]
    \\marker and accepting the upstream change verbatim.
    \\
    \\## File Extension Rules
    \\
    \\- `.zig` files: Standard Zig. Allocator usage produces diagnostics per
    \\  mode (warnings in default, errors in strict).
    \\- `.sig` files: Strict Sig. Allocator usage is ALWAYS a compile error
    \\  regardless of flags. The file extension itself is the contract.
    \\
    \\## Output Rules
    \\
    \\- Return ONLY the resolved file content with no conflict markers.
    \\- Preserve all [sig] comment markers exactly as they appear.
    \\- Do not add new [sig] markers that were not in the original.
    \\- Do not remove any [sig] markers from the original.
;

// ── Prompt Builder ───────────────────────────────────────────────────────

/// Builds a complete prompt for the AI conflict resolver into a caller-provided
/// stack buffer. Combines the system prompt, file context, and conflicted content.
///
/// Returns the filled slice of `buf`, or `BufferTooSmall` if the prompt exceeds
/// the buffer capacity.
pub fn buildPrompt(
    buf: []u8,
    file_path: []const u8,
    conflicted_content: []const u8,
    upstream_commit: []const u8,
    sig_commit: []const u8,
) PromptError![]const u8 {
    const ext_context = extensionContext(file_path);

    const slices = [_][]const u8{
        SYSTEM_PROMPT,
        "\n\n## File Context\n\nFile: ",
        file_path,
        "\nUpstream commit: ",
        upstream_commit,
        "\nSig commit: ",
        sig_commit,
        "\nFile type: ",
        ext_context,
        "\n\n## Conflicted Content\n\n```\n",
        conflicted_content,
        "\n```\n\nResolve the conflicts above following the Sig conventions.\n",
    };

    var offset: usize = 0;
    for (slices) |s| {
        if (offset + s.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[offset..][0..s.len], s);
        offset += s.len;
    }
    return buf[0..offset];
}

/// Returns a human-readable description of the file extension context.
fn extensionContext(file_path: []const u8) []const u8 {
    if (endsWith(file_path, ".sig")) {
        return ".sig (Strict Sig — allocator usage is ALWAYS a compile error)";
    } else if (endsWith(file_path, ".zig")) {
        return ".zig (Standard Zig — allocator usage produces diagnostics per mode)";
    } else {
        return "unknown (apply general Sig conventions)";
    }
}

/// Simple suffix check without pulling in std.mem.
fn endsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    const tail = haystack[haystack.len - needle.len ..];
    for (tail, needle) |a, b| {
        if (a != b) return false;
    }
    return true;
}
