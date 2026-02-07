# Download Caching System Design

**Date:** 2026-02-06
**Author:** Claude Code
**Status:** Implemented

## Overview

This document describes the download caching system implemented for the Alpine Linux diskless k3s cluster build process. The system caches downloaded packages and binaries to significantly speed up subsequent builds.

## Problem Statement

Previously, every build operation downloaded the same files from the internet:
- **k3s binary** (~66MB for arm64) - downloaded once per node
- **Alpine APK packages** (~1.5MB total) - downloaded once per node
- **Alpine ISO images** (~150-200MB) - downloaded for SD card setup and testing

For a 3-node cluster, each build would download ~200MB+ of data, even when nothing changed in the configuration.

## Solution

A content-addressable cache system that:
1. Stores downloads in a `.cache/` directory at the project root
2. Checks cache before downloading
3. Falls back to download if cache miss
4. Supports cache cleanup via make targets

## Architecture

### Cache Directory Structure

```
.cache/
├── apk/
│   ├── aarch64/
│   │   ├── openssh-10.0_p1-r10.apk
│   │   ├── chrony-4.6.1-r1.apk
│   │   └── ...
│   └── x86_64/
├── k3s/
│   ├── k3s-v1.35.0+k3s1-arm64
│   └── k3s-v1.35.0+k3s1-amd64
└── alpine-iso/
    ├── alpine-rpi-3.22.1-aarch64.tar.gz
    └── alpine-virt-3.22.1-x86_64.iso
```

### Cache Key Generation

Keys are generated to include version and architecture information:

- **APK packages:** `{arch}/{pkg_name}-{version}.apk`
- **k3s binary:** `k3s-{version}-{arch}`
- **Alpine ISO:** `alpine-{variant}-{version}-{arch}.{ext}`

This allows multiple versions and architectures to coexist in the cache.

## Components

### 1. Cache Library (`lib/cache.sh`)

Core functions:

- `cache_root()` - Returns the absolute path to the cache directory
- `cache_get(subdir, key, dest)` - Retrieves file from cache if exists
- `cache_put(subdir, key, source)` - Stores file in cache
- `cache_clear([subdir])` - Clears all or specific cache subdirectory
- `cache_stats()` - Displays cache statistics

### 2. Script Modifications

**`scripts/create-apkovl-yaml.sh`:**
- `process_overlay_packages()` - Checks cache before downloading APK packages
- `download_k3s_binary()` - Checks cache before downloading k3s binary

**`scripts/setup-bootable-device.sh`:**
- Alpine ISO download section - Checks cache before downloading

**`test/qemu-test.sh`:**
- Alpine ISO download for QEMU testing - Checks cache before downloading

### 3. Makefile Updates

```makefile
# New targets
make clean-cache    # Remove .cache/ directory
make cache-stats    # Show cache statistics

# Modified target
make clean-all      # Now includes cache cleanup
```

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        Build Process                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │ Generate Cache  │
                    │      Key        │
                    │ (name, ver,     │
                    │   arch)         │
                    └────────┬────────┘
                             │
                             ▼
                   ┌─────────────────────┐
                   │  cache_get(key)     │
                   └──────────┬──────────┘
                              │
                ┌─────────────┴─────────────┐
                │                           │
                ▼                           ▼
         ┌───────────┐              ┌──────────────┐
         │  FOUND    │              │ NOT FOUND    │
         │  in cache │              │ in cache     │
         └─────┬─────┘              └──────┬───────┘
               │                            │
               ▼                            ▼
    ┌──────────────────┐         ┌──────────────────┐
    │ Copy from cache  │         │ Download from    │
    │ to destination   │         │ internet         │
    └──────────────────┘         └────────┬─────────┘
                                           │
                                           ▼
                                  ┌──────────────────┐
                                  │ cache_put(key)   │
                                  │ Store in cache   │
                                  └────────┬─────────┘
                                           │
                                           ▼
                                  ┌──────────────────┐
                                  │ Copy to          │
                                  │ destination      │
                                  └──────────────────┘
```

## Error Handling

**Cache Failures:**
- Cache read failure → Falls back to download (logs warning)
- Cache write failure → Continues with downloaded file (logs warning)
- Cache directory missing → Auto-created on first `cache_put()`
- Corrupted cache file → Detected via size check, re-downloaded

**Download Failures:**
- Unchanged from current behavior → Fails build with clear error message

## Performance Impact

**Before Caching:**
- First build: Downloads ~200MB (k3s × 3 nodes + packages)
- Subsequent builds: Downloads ~200MB again

**After Caching:**
- First build: Downloads ~67MB (stores in cache)
- Subsequent builds: ~7 seconds (no downloads, uses cache)

## Testing Strategy

**Manual Testing:**
1. First build → Downloads everything, populates cache
2. Second build → Uses cache, should be significantly faster
3. Version change → Downloads new version, old version remains in cache
4. `make clean-cache` → Cache emptied
5. Build after clean → Re-downloads everything

**Cache Validation:**
- Verify cached files are identical to originals (size comparison)
- Test multiple architectures don't conflict
- Test version coexistence

## Future Enhancements

Potential improvements for future consideration:
1. **Cache TTL** - Automatically expire old entries after X days
2. **Cache size limits** - Auto-remove oldest entries when cache exceeds size limit
3. **Parallel downloads** - Download packages in parallel for faster initial builds
4. **Checksum verification** - Verify SHA256 of cached files
5. **Resumable downloads** - Support partial download resume

## Files Modified

**New Files:**
- `lib/cache.sh` - Cache library

**Modified Files:**
- `scripts/create-apkovl-yaml.sh` - Use cache for APK and k3s downloads
- `scripts/setup-bootable-device.sh` - Use cache for Alpine ISO
- `test/qemu-test.sh` - Use cache for test Alpine ISO
- `Makefile` - Added clean-cache and cache-stats targets
- `.gitignore` - Added .cache/ directory

## Usage Examples

```bash
# Normal build (uses cache if available)
make build

# Show cache statistics
make cache-stats

# Clear cache (e.g., to force fresh downloads)
make clean-cache

# Clean everything including cache
make clean-all
```
