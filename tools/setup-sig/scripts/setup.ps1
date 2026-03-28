# [sig] setup-sig — Windows setup script for the Sig compiler
param(
    [Parameter(Mandatory)][string]$Action,
    [string]$Version = '',
    [string]$Mirror = '',
    [string]$DownloadUrl = '',
    [string]$ToolDir = '',
    [string]$CacheHit = 'false',
    [string]$CacheSizeLimit = '2048'
)

$ErrorActionPreference = 'Stop'
$GithubReleaseBase = 'https://github.com/ShadovvBeast/sig/releases'

# --- Helpers ---

function Get-PlatformTriple {
    $arch = if ([System.Environment]::Is64BitOperatingSystem) { 'x86_64' } else {
        Write-Output "::error::Unsupported architecture: 32-bit Windows"
        exit 1
    }
    return "${arch}-windows"
}

function Resolve-VersionFromManifest {
    $manifest = $null
    if (Test-Path 'build.sig.zon') { $manifest = 'build.sig.zon' }
    elseif (Test-Path 'build.zig.zon') { $manifest = 'build.zig.zon' }

    if ($manifest) {
        $content = Get-Content $manifest -Raw
        if ($content -match '\.minimum_zig_version\s*=\s*"([^"]+)"') {
            return $Matches[1]
        }
    }
    return ''
}

function Resolve-LatestVersion {
    try {
        $response = Invoke-RestMethod -Uri "https://api.github.com/repos/ShadovvBeast/sig/releases/latest" `
            -Headers @{ 'User-Agent' = 'setup-sig' } -ErrorAction Stop
        $tag = $response.tag_name -replace '^sig-', ''
        return $tag
    } catch {
        Write-Output "::warning::Could not query latest release from GitHub API"
        return ''
    }
}

function Get-DownloadUrl {
    param([string]$Ver, [string]$Mir, [string]$Triple)
    $base = if ($Mir) { $Mir } else { "${GithubReleaseBase}/download/sig-${Ver}" }
    return "${base}/sig-${Ver}-${Triple}.zip"
}

function Get-ZigCacheDir {
    return Join-Path $env:LOCALAPPDATA 'zig'
}

# --- Actions ---

function Invoke-Resolve {
    $triple = Get-PlatformTriple
    $ver = $Version

    if (-not $ver) {
        $ver = Resolve-VersionFromManifest
    }
    if (-not $ver -or $ver -eq 'latest') {
        $ver = Resolve-LatestVersion
    }
    if (-not $ver) {
        Write-Output "::error::Could not resolve Sig version. Specify one explicitly."
        exit 1
    }

    $url = Get-DownloadUrl -Ver $ver -Mir $Mirror -Triple $triple

    "resolved-version=${ver}" | Out-File -Append -FilePath $env:GITHUB_OUTPUT -Encoding utf8
    "download-url=${url}" | Out-File -Append -FilePath $env:GITHUB_OUTPUT -Encoding utf8
    "platform-triple=${triple}" | Out-File -Append -FilePath $env:GITHUB_OUTPUT -Encoding utf8
    Write-Output "Resolved Sig version: ${ver} for ${triple}"
}

function Invoke-Install {
    if ($CacheHit -eq 'true' -and (Test-Path (Join-Path $ToolDir 'bin/sig'))) {
        Write-Output "Sig ${Version} restored from cache"
        return
    }

    Write-Output "Downloading Sig ${Version} from ${DownloadUrl}"
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $zipFile = Join-Path $tmpDir 'sig.zip'

    Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipFile -UseBasicParsing

    # Download and verify checksum
    $checksumsUrl = (Split-Path $DownloadUrl -Parent) + '/sha256sums.txt'
    $checksumsFile = Join-Path $tmpDir 'sha256sums.txt'
    $checksumVerified = $false
    try {
        Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumsFile -UseBasicParsing -ErrorAction Stop
        $tarballName = Split-Path $DownloadUrl -Leaf
        $checksumLine = Get-Content $checksumsFile | Where-Object { $_ -match $tarballName }
        if ($checksumLine) {
            $expected = ($checksumLine -split '\s+')[0]
            $actual = (Get-FileHash -Path $zipFile -Algorithm SHA256).Hash.ToLower()
            if ($expected -ne $actual) {
                Write-Output "::error::Checksum mismatch! Expected: ${expected}, Got: ${actual}"
                Remove-Item -Recurse -Force $tmpDir
                exit 1
            }
            $checksumVerified = $true
            Write-Output "Checksum verified"
        } else {
            Write-Output "::warning::Tarball not found in sha256sums.txt — skipping verification"
        }
    } catch {
        Write-Output "::warning::sha256sums.txt not available — skipping checksum verification"
    }

    # Extract
    if (-not (Test-Path $ToolDir)) {
        New-Item -ItemType Directory -Path $ToolDir -Force | Out-Null
    }
    Expand-Archive -Path $zipFile -DestinationPath $tmpDir -Force
    # Move contents (strip top-level directory if present)
    $extracted = Get-ChildItem -Path $tmpDir -Directory | Where-Object { $_.Name -ne 'sig.zip' } | Select-Object -First 1
    if ($extracted -and (Test-Path (Join-Path $extracted.FullName 'bin'))) {
        Copy-Item -Path (Join-Path $extracted.FullName '*') -Destination $ToolDir -Recurse -Force
    } else {
        Copy-Item -Path (Join-Path $tmpDir '*') -Destination $ToolDir -Recurse -Force -Exclude 'sig.zip','sha256sums.txt'
    }
    Remove-Item -Recurse -Force $tmpDir

    Write-Output "Sig ${Version} installed to ${ToolDir}"
}

function Invoke-CacheLimit {
    $cacheDir = Get-ZigCacheDir
    if (-not (Test-Path $cacheDir)) { return }

    $sizeBytes = (Get-ChildItem -Path $cacheDir -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $sizeMib = [math]::Floor($sizeBytes / 1048576)
    $limitMib = [int]$CacheSizeLimit

    if ($sizeMib -gt $limitMib) {
        Write-Output "Zig cache (${sizeMib} MiB) exceeds limit (${limitMib} MiB) — clearing"
        Remove-Item -Recurse -Force $cacheDir
    } else {
        Write-Output "Zig cache size: ${sizeMib} MiB (limit: ${limitMib} MiB)"
    }
}

# --- Dispatch ---

switch ($Action) {
    'resolve'     { Invoke-Resolve }
    'install'     { Invoke-Install }
    'cache-limit' { Invoke-CacheLimit }
    default {
        Write-Output "::error::Unknown action: $Action"
        exit 1
    }
}
