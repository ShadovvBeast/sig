# setup-sig

A GitHub Action (and Forgejo Action) that downloads and installs the [Sig](https://github.com/ShadovvBeast/sig) compiler for use in CI workflows.

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ShadovvBeast/setup-sig@v1
      - run: sig build test
```

### Pin a specific version

```yaml
      - uses: ShadovvBeast/setup-sig@v1
        with:
          version: 0.0.1
```

### Auto-detect from manifest

When `version` is omitted, the action reads `minimum_zig_version` from `build.sig.zon` (or `build.zig.zon`), falling back to the latest release.

### Matrix strategy

```yaml
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: ShadovvBeast/setup-sig@v1
        with:
          cache-key: ${{ matrix.os }}
      - run: sig build test
```

### Custom mirror

```yaml
      - uses: ShadovvBeast/setup-sig@v1
        with:
          mirror: https://my-mirror.example.com/sig/releases
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | *(auto-detect)* | Sig version to install (`"0.0.1"`, `"master"`, `"latest"`, or empty for auto-detect) |
| `mirror` | *(GitHub releases)* | Custom mirror base URL for downloading tarballs |
| `use-cache` | `true` | Cache the compiler tarball between workflow runs |
| `cache-key` | `""` | Additional cache key suffix for matrix disambiguation |
| `cache-size-limit` | `2048` | Max Sig global cache size in MiB before clearing (`0` to disable) |

## Supported platforms

| Runner | Architecture | Status |
|---|---|---|
| `ubuntu-latest` | x86_64 | Supported |
| `ubuntu-latest` (ARM) | aarch64 | Supported |
| `macos-latest` | aarch64 | Supported |
| `windows-latest` | x86_64 | Supported |

## How it works

1. Resolves the Sig version (explicit, from manifest, or latest release)
2. Downloads the platform-appropriate tarball from GitHub releases (or a custom mirror)
3. Verifies the SHA-256 checksum against `sha256sums.txt`
4. Extracts the compiler and adds it to `PATH`
5. Caches the tarball and Sig global cache directory for faster subsequent runs
6. Enforces a configurable size limit on the Sig cache directory

## License

Same license as the [Sig](https://github.com/ShadovvBeast/sig) project.
