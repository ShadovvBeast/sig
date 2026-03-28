// Sig Conflict Resolver — Resolution Validator
//
// Pure byte-scanning validation for resolved conflict content.
// Zero allocators. All checks operate over the input slice directly.
//
// Requirements: 24.2, 24.3

const std = @import("std");

// ── Types ────────────────────────────────────────────────────────────────

pub const ValidationResult = struct {
    valid: bool,
    has_conflict_markers: bool,
    has_invalid_utf8: bool,
};

// ── Conflict Marker Detection ────────────────────────────────────────────

/// Returns false if content contains any conflict markers:
///   `<<<<<<<` (7 less-than signs)
///   `=======` (7 equals signs)
///   `>>>>>>>` (7 greater-than signs)
///
/// Pure byte scan — no allocations.
pub fn validateResolution(content: []const u8) bool {
    if (content.len < 7) return true;

    var i: usize = 0;
    while (i + 6 < content.len) : (i += 1) {
        const b = content[i];
        if (b == '<' or b == '=' or b == '>') {
            if (content[i + 1] == b and
                content[i + 2] == b and
                content[i + 3] == b and
                content[i + 4] == b and
                content[i + 5] == b and
                content[i + 6] == b)
            {
                return false;
            }
        }
    }
    return true;
}

// ── UTF-8 Validation ─────────────────────────────────────────────────────

/// Returns true if content is valid UTF-8.
///
/// Checks:
///   - Correct continuation byte counts (1–4 byte sequences)
///   - Valid continuation byte prefix (0x80..0xBF)
///   - Rejects overlong encodings
///   - Rejects surrogates (U+D800..U+DFFF)
///   - Rejects codepoints above U+10FFFF
///
/// Pure byte scan — no allocations.
pub fn isValidUtf8(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len) {
        const b0 = content[i];

        if (b0 < 0x80) {
            // ASCII — single byte
            i += 1;
            continue;
        }

        if (b0 & 0xE0 == 0xC0) {
            // 2-byte sequence: 110xxxxx 10xxxxxx
            if (i + 1 >= content.len) return false;
            const b1 = content[i + 1];
            if (b1 & 0xC0 != 0x80) return false;

            // Reject overlong: codepoint must be >= 0x80
            // 2-byte min is 110_00010 10_000000 = 0xC2 0x80
            if (b0 < 0xC2) return false;

            i += 2;
        } else if (b0 & 0xF0 == 0xE0) {
            // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
            if (i + 2 >= content.len) return false;
            const b1 = content[i + 1];
            const b2 = content[i + 2];
            if (b1 & 0xC0 != 0x80) return false;
            if (b2 & 0xC0 != 0x80) return false;

            // Reject overlong: codepoint must be >= 0x800
            // When b0 == 0xE0, b1 must be >= 0xA0
            if (b0 == 0xE0 and b1 < 0xA0) return false;

            // Reject surrogates: U+D800..U+DFFF
            // When b0 == 0xED, b1 must be < 0xA0
            if (b0 == 0xED and b1 >= 0xA0) return false;

            i += 3;
        } else if (b0 & 0xF8 == 0xF0) {
            // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
            if (i + 3 >= content.len) return false;
            const b1 = content[i + 1];
            const b2 = content[i + 2];
            const b3 = content[i + 3];
            if (b1 & 0xC0 != 0x80) return false;
            if (b2 & 0xC0 != 0x80) return false;
            if (b3 & 0xC0 != 0x80) return false;

            // Reject overlong: codepoint must be >= 0x10000
            // When b0 == 0xF0, b1 must be >= 0x90
            if (b0 == 0xF0 and b1 < 0x90) return false;

            // Reject codepoints above U+10FFFF
            // When b0 == 0xF4, b1 must be < 0x90
            if (b0 == 0xF4 and b1 >= 0x90) return false;

            // b0 > 0xF4 is always invalid (above U+10FFFF)
            if (b0 > 0xF4) return false;

            i += 4;
        } else {
            // Invalid leading byte (0x80..0xBF or 0xF8..0xFF)
            return false;
        }
    }
    return true;
}

// ── Combined Validation ──────────────────────────────────────────────────

/// Validates resolved content: no conflict markers AND valid UTF-8.
/// Returns a ValidationResult with individual check results.
///
/// `valid` is true only when both checks pass.
/// Pure byte scan — no allocations.
pub fn validateResolvedContent(content: []const u8) ValidationResult {
    const has_markers = !validateResolution(content);
    const bad_utf8 = !isValidUtf8(content);
    return ValidationResult{
        .valid = !has_markers and !bad_utf8,
        .has_conflict_markers = has_markers,
        .has_invalid_utf8 = bad_utf8,
    };
}
