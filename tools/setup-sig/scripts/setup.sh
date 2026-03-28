#!/usr/bin/env bash
# [sig] setup-sig — Linux/macOS setup script for the Sig compiler
set -euo pipefail

ACTION="$1"
GITHUB_RELEASE_BASE="https://github.com/ShadovvBeast/sig/releases"

# --- Helpers ---

detect_platform() {
  local os arch
  case "$(uname -s)" in
    Linux*)  os="linux" ;;
    Darwin*) os="macos" ;;
    *)       echo "::error::Unsupported OS: $(uname -s)"; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *)       echo "::error::Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
  echo "${arch}-${os}"
}

resolve_version_from_manifest() {
  local manifest=""
  if [ -f "build.sig.zon" ]; then
    manifest="build.sig.zon"
  elif [ -f "build.zig.zon" ]; then
    manifest="build.zig.zon"
  fi
  if [ -n "$manifest" ]; then
    grep -oP '\.minimum_zig_version\s*=\s*"\K[^"]+' "$manifest" 2>/dev/null || true
  fi
}

resolve_latest_version() {
  # Query GitHub API for latest release tag
  local tag
  tag=$(curl -fsSL "${GITHUB_RELEASE_BASE}/latest" -o /dev/null -w '%{redirect_url}' 2>/dev/null \
    | grep -oP 'v\K[^/]+$' || true)
  if [ -z "$tag" ]; then
    # Fallback: query API directly
    tag=$(curl -fsSL "https://api.github.com/repos/ShadovvBeast/sig/releases/latest" \
      | grep -oP '"tag_name":\s*"v?\K[^"]+' 2>/dev/null || true)
  fi
  echo "$tag"
}

compute_download_url() {
  local version="$1" mirror="$2" triple="$3"
  local base_url="${mirror:-${GITHUB_RELEASE_BASE}/download/v${version}}"
  echo "${base_url}/sig-${version}-${triple}.tar.xz"
}

get_zig_cache_dir() {
  case "$(uname -s)" in
    Linux*)  echo "${HOME}/.cache/zig" ;;
    Darwin*) echo "${HOME}/Library/Caches/zig" ;;
  esac
}

# --- Actions ---

action_resolve() {
  local input_version="$2" mirror="${3:-}"
  local version="$input_version"
  local triple
  triple=$(detect_platform)

  # Auto-detect version if not specified
  if [ -z "$version" ]; then
    version=$(resolve_version_from_manifest)
  fi
  if [ -z "$version" ] || [ "$version" = "latest" ]; then
    version=$(resolve_latest_version)
  fi
  if [ -z "$version" ]; then
    echo "::error::Could not resolve Sig version. Specify one explicitly."
    exit 1
  fi

  local url
  url=$(compute_download_url "$version" "$mirror" "$triple")

  echo "resolved-version=${version}" >> "$GITHUB_OUTPUT"
  echo "download-url=${url}" >> "$GITHUB_OUTPUT"
  echo "platform-triple=${triple}" >> "$GITHUB_OUTPUT"
  echo "Resolved Sig version: ${version} for ${triple}"
}

action_install() {
  local version="$2" url="$3" tool_dir="$4" cache_hit="${5:-false}"

  if [ "$cache_hit" = "true" ] && [ -x "${tool_dir}/bin/zig" ]; then
    echo "Sig ${version} restored from cache"
    return 0
  fi

  echo "Downloading Sig ${version} from ${url}"
  local tmpdir
  tmpdir=$(mktemp -d)
  local tarball="${tmpdir}/sig.tar.xz"

  curl -fsSL "$url" -o "$tarball"

  # Download and verify checksum
  local checksums_url
  checksums_url="${url%/*}/sha256sums.txt"
  local checksums_file="${tmpdir}/sha256sums.txt"
  if curl -fsSL "$checksums_url" -o "$checksums_file" 2>/dev/null; then
    local expected actual tarball_name
    tarball_name=$(basename "$url")
    expected=$(grep "$tarball_name" "$checksums_file" | awk '{print $1}')
    if [ -n "$expected" ]; then
      if command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "$tarball" | awk '{print $1}')
      else
        actual=$(shasum -a 256 "$tarball" | awk '{print $1}')
      fi
      if [ "$expected" != "$actual" ]; then
        echo "::error::Checksum mismatch! Expected: ${expected}, Got: ${actual}"
        rm -rf "$tmpdir"
        exit 1
      fi
      echo "Checksum verified"
    else
      echo "::warning::Tarball not found in sha256sums.txt — skipping verification"
    fi
  else
    echo "::warning::sha256sums.txt not available — skipping checksum verification"
  fi

  # Extract
  mkdir -p "$tool_dir"
  tar -xJf "$tarball" -C "$tool_dir" --strip-components=1
  rm -rf "$tmpdir"

  echo "Sig ${version} installed to ${tool_dir}"
}

action_cache_limit() {
  local limit_mib="$2"
  local cache_dir
  cache_dir=$(get_zig_cache_dir)

  if [ ! -d "$cache_dir" ]; then
    return 0
  fi

  local size_bytes size_mib
  if du -sb "$cache_dir" &>/dev/null; then
    size_bytes=$(du -sb "$cache_dir" | awk '{print $1}')
  else
    # macOS: du -sk gives kilobytes
    size_bytes=$(( $(du -sk "$cache_dir" | awk '{print $1}') * 1024 ))
  fi
  size_mib=$((size_bytes / 1048576))

  if [ "$size_mib" -gt "$limit_mib" ]; then
    echo "Zig cache (${size_mib} MiB) exceeds limit (${limit_mib} MiB) — clearing"
    rm -rf "$cache_dir"
  else
    echo "Zig cache size: ${size_mib} MiB (limit: ${limit_mib} MiB)"
  fi
}

# --- Dispatch ---

case "$ACTION" in
  resolve)     action_resolve "$@" ;;
  install)     action_install "$@" ;;
  cache-limit) action_cache_limit "$@" ;;
  *)           echo "::error::Unknown action: $ACTION"; exit 1 ;;
esac
