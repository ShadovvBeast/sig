# bootstrap.ps1 — Build the Sig build runner from source on Windows.
#
# This script compiles tools/sig_build/main.sig into a standalone executable
# using a direct compiler invocation. Once built, `sig build` can rebuild
# itself (self-hosting).
#
# Usage:
#   .\bootstrap.ps1
#
# Environment variables:
#   SIG_COMPILER  — Path to the sig compiler binary (default: auto-detect)
#   SIG_OUT_DIR   — Output directory for the binary (default: zig-out\bin)

$ErrorActionPreference = 'Stop'

# ── Configuration ────────────────────────────────────────────────────────────

$SOURCE   = "tools/sig_build/main.sig"
$MOD_PATH = "lib/sig/sig.zig"
$OUT_DIR  = if ($env:SIG_OUT_DIR) { $env:SIG_OUT_DIR } else { "zig-out\bin" }
$OUT_NAME = "sig-build"
$OUT_PATH = "$OUT_DIR\$OUT_NAME.exe"

# ── Locate the sig compiler ─────────────────────────────────────────────────

$SIG = $null

if ($env:SIG_COMPILER) {
    $SIG = $env:SIG_COMPILER
} elseif (Get-Command "sig" -ErrorAction SilentlyContinue) {
    $SIG = "sig"
} else {
    # Check known local dev path
    $LOCAL_SIG = "C:\Just-Things\Projects\Lib\sig-bin\sig.exe"
    if (Test-Path $LOCAL_SIG) {
        $SIG = $LOCAL_SIG
    }
}

if (-not $SIG) {
    Write-Error @"
error: sig compiler not found

The sig compiler is required to bootstrap the build runner.
Install sig and ensure it is on your PATH, or set the SIG_COMPILER
environment variable to the full path of the sig binary.

  `$env:SIG_COMPILER = "C:\path\to\sig.exe"
  .\bootstrap.ps1
"@
    exit 1
}

# ── Verify source files exist ────────────────────────────────────────────────

if (-not (Test-Path $SOURCE)) {
    Write-Error "error: source file not found: $SOURCE`nRun this script from the repository root."
    exit 1
}

if (-not (Test-Path $MOD_PATH)) {
    Write-Error "error: sig module not found: $MOD_PATH`nRun this script from the repository root."
    exit 1
}

# ── Create output directory ──────────────────────────────────────────────────

if (-not (Test-Path $OUT_DIR)) {
    New-Item -ItemType Directory -Path $OUT_DIR -Force | Out-Null
}

# ── Compile the build runner ─────────────────────────────────────────────────

Write-Host "Bootstrapping sig build runner..."
Write-Host "  compiler: $SIG"
Write-Host "  source:   $SOURCE"
Write-Host "  output:   $OUT_PATH"

& $SIG build-exe $SOURCE --mod "sig:$MOD_PATH" --name $OUT_NAME -femit-bin=$OUT_PATH

if ($LASTEXITCODE -ne 0) {
    Write-Error "`nerror: compilation failed`nCheck the compiler output above for details."
    exit 1
}

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Bootstrap complete: $OUT_PATH"
Write-Host "You can now use 'sig build' via: $OUT_PATH"
