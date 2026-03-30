#!/bin/sh
# bootstrap.sh — Build the Sig build runner from source on Linux/macOS.
#
# This script compiles tools/sig_build/main.sig into a standalone executable
# using a direct compiler invocation. Once built, `sig build` can rebuild
# itself (self-hosting).
#
# Usage:
#   ./bootstrap.sh
#
# Environment variables:
#   SIG_COMPILER  — Path to the sig compiler binary (default: auto-detect on PATH)
#   SIG_OUT_DIR   — Output directory for the binary (default: zig-out/bin)

set -e

# ── Configuration ────────────────────────────────────────────────────────────

SOURCE="tools/sig_build/main.sig"
MOD_PATH="lib/sig/sig.zig"
OUT_DIR="${SIG_OUT_DIR:-zig-out/bin}"
OUT_NAME="sig-build"
OUT_PATH="${OUT_DIR}/${OUT_NAME}"

# ── Locate the sig compiler ─────────────────────────────────────────────────

if [ -n "${SIG_COMPILER}" ]; then
    SIG="${SIG_COMPILER}"
elif command -v sig >/dev/null 2>&1; then
    SIG="sig"
else
    # Check common install locations
    for candidate in \
        /usr/local/bin/sig \
        /usr/bin/sig \
        "${HOME}/.local/bin/sig" \
        "${HOME}/bin/sig"; do
        if [ -x "${candidate}" ]; then
            SIG="${candidate}"
            break
        fi
    done
fi

if [ -z "${SIG}" ]; then
    echo "error: sig compiler not found" >&2
    echo "" >&2
    echo "The sig compiler is required to bootstrap the build runner." >&2
    echo "Install sig and ensure it is on your PATH, or set the SIG_COMPILER" >&2
    echo "environment variable to the full path of the sig binary." >&2
    echo "" >&2
    echo "  export SIG_COMPILER=/path/to/sig" >&2
    echo "  ./bootstrap.sh" >&2
    exit 1
fi

# ── Verify source files exist ────────────────────────────────────────────────

if [ ! -f "${SOURCE}" ]; then
    echo "error: source file not found: ${SOURCE}" >&2
    echo "Run this script from the repository root." >&2
    exit 1
fi

if [ ! -f "${MOD_PATH}" ]; then
    echo "error: sig module not found: ${MOD_PATH}" >&2
    echo "Run this script from the repository root." >&2
    exit 1
fi

# ── Create output directory ──────────────────────────────────────────────────

mkdir -p "${OUT_DIR}"

# ── Compile the build runner ─────────────────────────────────────────────────

echo "Bootstrapping sig build runner..."
echo "  compiler: ${SIG}"
echo "  source:   ${SOURCE}"
echo "  output:   ${OUT_PATH}"

if ! "${SIG}" build-exe "${SOURCE}" --mod "sig:${MOD_PATH}" --name "${OUT_NAME}" -femit-bin="${OUT_PATH}"; then
    echo "" >&2
    echo "error: compilation failed" >&2
    echo "Check the compiler output above for details." >&2
    exit 1
fi

# ── Make executable ──────────────────────────────────────────────────────────

chmod +x "${OUT_PATH}"

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "Bootstrap complete: ${OUT_PATH}"
echo "You can now use 'sig build' via: ${OUT_PATH}"
