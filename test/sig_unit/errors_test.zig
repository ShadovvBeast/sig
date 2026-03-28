const std = @import("std");
const testing = std.testing;
const errors = @import("errors");

const SigError = errors.SigError;

// ── Requirement 7.1: CapacityExceeded exists ─────────────────────────────

test "SigError contains CapacityExceeded variant" {
    const err: SigError = error.CapacityExceeded;
    try testing.expectEqual(error.CapacityExceeded, err);
}

// ── Requirement 7.2: BufferTooSmall exists ───────────────────────────────

test "SigError contains BufferTooSmall variant" {
    const err: SigError = error.BufferTooSmall;
    try testing.expectEqual(error.BufferTooSmall, err);
}

// ── Requirement 7.3: DepthExceeded exists ────────────────────────────────

test "SigError contains DepthExceeded variant" {
    const err: SigError = error.DepthExceeded;
    try testing.expectEqual(error.DepthExceeded, err);
}

// ── Requirement 7.4: QuotaExceeded exists ────────────────────────────────

test "SigError contains QuotaExceeded variant" {
    const err: SigError = error.QuotaExceeded;
    try testing.expectEqual(error.QuotaExceeded, err);
}

// ── All four variants are distinct ───────────────────────────────────────

test "all four SigError variants are distinct from each other" {
    const variants = [_]SigError{
        error.CapacityExceeded,
        error.BufferTooSmall,
        error.DepthExceeded,
        error.QuotaExceeded,
    };
    // Every pair must differ
    for (variants, 0..) |a, i| {
        for (variants, 0..) |b, j| {
            if (i != j) {
                try testing.expect(a != b);
            }
        }
    }
}

// ── Functions returning SigError!void can return each variant ────────────

fn failWith(err: SigError) SigError!void {
    return err;
}

test "function returning SigError!void can return CapacityExceeded" {
    try testing.expectError(error.CapacityExceeded, failWith(error.CapacityExceeded));
}

test "function returning SigError!void can return BufferTooSmall" {
    try testing.expectError(error.BufferTooSmall, failWith(error.BufferTooSmall));
}

test "function returning SigError!void can return DepthExceeded" {
    try testing.expectError(error.DepthExceeded, failWith(error.DepthExceeded));
}

test "function returning SigError!void can return QuotaExceeded" {
    try testing.expectError(error.QuotaExceeded, failWith(error.QuotaExceeded));
}
