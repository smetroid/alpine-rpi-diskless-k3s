# k3s Binary in apkovl Overlay Design

**Date:** 2026-02-05
**Status:** Design
**Author:** kike + Claude

## Overview

Embed the k3s binary directly in each node's apkovl overlay during build, eliminating the need for first-boot download/install.

## Problem Statement

Currently, k3s is downloaded and installed during the first boot via `get.k3s.io` in the `system-bootstrap` service. This has several drawbacks:

- Slower first boot (~50MB download)
- Requires internet connectivity on first boot
- Adds complexity to system-bootstrap (~100 lines)
- Breaks air-gapped deployments

## Solution

Download the k3s binary during the build process and include it directly in the apkovl overlay at `/usr/local/bin/k3s`.

## Architecture

### Current Flow (Before)

```
System boots → apkovl loads → system-bootstrap runs
                                              ↓
                                  Downloads k3s via get.k3s.io
                                              ↓
                                      k3s starts
```

### New Flow (After)

```
Build time → Download k3s binary for target arch
                              ↓
            Place in apkovl/usr/local/bin/k3s
                              ↓
System boots → apkovl loads (k3s already present)
                              ↓
                        k3s starts immediately
```

## Components

### New Function: `download_k3s_binary()`

**Location:** `scripts/create-apkovl-yaml.sh`

```bash
download_k3s_binary() {
    local apkovl_dir="$1"
    local config_file="$2"
    local arch=$(yaml_get "alpine.architecture" "$config_file")
    local version=$(yaml_get "cluster.k3s_version" "$config_file")

    # Map alpine arch to k3s arch names
    case "$arch" in
        aarch64) k3s_arch="arm64" ;;
        armv7|armhf) k3s_arch="arm" ;;
        x86_64) k3s_arch="amd64" ;;
        *) k3s_arch="$arch" ;;
    esac

    local url="https://github.com/k3s-io/k3s/releases/download/${version}/k3s"
    local dest="${apkovl_dir}/usr/local/bin/k3s"

    log_info "Downloading k3s ${version} (${k3s_arch})..."

    if ! curl -fL --progress-bar "${url}" -o "$dest"; then
        log_error "Failed to download k3s binary"
        rm -f "$dest"
        return 1
    fi

    # Verify it's a valid ELF binary
    if ! file "$dest" | grep -q "ELF"; then
        log_error "Downloaded file is not a valid binary"
        rm -f "$dest"
        return 1
    fi

    chmod +x "$dest"
    log_success "k3s ${version} downloaded ($(du -h "$dest" | cut -f1))"
}
```

### Modified: `create-apkovl-yaml.sh` Main Loop

After creating the apkovl directory structure (line ~164):

```bash
download_k3s_binary "${NODE_NAME}-apkovl" "$CONFIG_FILE"
```

### Removed: `system-bootstrap` k3s Installation

Remove lines ~279-431 from `scripts/build-from-yaml.sh`:
- k3s version placeholder logic
- k3s binary download via get.k3s.io
- k3s installer save/restore logic
- Time sync (move earlier in bootstrap)

### Simplified: k3s Service Start

```bash
# Start k3s service (binary already in apkovl)
echo "🔄 Starting k3s service..."
if [ -x /usr/local/bin/k3s ]; then
    if ! rc-service k3s status >/dev/null 2>&1; then
        rc-service k3s start
        rc-update add k3s default
        echo "✅ k3s service started"
    else
        echo "✅ k3s service already running"
    fi
else
    echo "⚠️ k3s binary not found"
fi
```

## Error Handling

### Download Validation

- Validate version exists on GitHub before downloading
- Verify downloaded file is a valid ELF binary
- Check file size (k3s is ~50MB+, warn if too small)
- Fail build immediately if download fails (don't create broken apkovl)

### Pre-Build Validation

Add to `scripts/validate-config.sh`:

```bash
validate_k3s_version() {
    local version=$(yaml_get "cluster.k3s_version" "$CONFIG_FILE")

    if [ "$version" = "latest" ]; then
        log_warn "Using 'latest' for k3s - consider pinning a version"
    fi

    if ! curl -s "https://api.github.com/repos/k3s-io/k3s/releases/tags/${version}" | grep -q "tag_name"; then
        log_error "k3s version '${version}' not found"
        log_info "Available versions: https://github.com/k3s-io/k3s/releases"
        return 1
    fi
}
```

## Configuration

Add to `k3s.yaml`:

```yaml
cluster:
  k3s_version: "v1.35.0+k3s1"
```

## Data Flow

```
YAML config (k3s_version + alpine.architecture)
                    ↓
        download_k3s_binary() function
                    ↓
        Fetch from GitHub releases
                    ↓
    Validate (ELF check, size verify)
                    ↓
    Place in apkovl/usr/local/bin/k3s
                    ↓
         Create apkovl.tar.gz
                    ↓
           Boot → k3s ready immediately
```

## Benefits

1. **Faster first boot** - No ~50MB download required
2. **Offline capable** - Works air-gapped after initial build
3. **Simpler bootstrap** - Removes ~100 lines from system-bootstrap
4. **Predictable versions** - Each node's apkovl contains exact k3s version
5. **Build-time validation** - Fail fast if version doesn't exist

## Files to Modify

1. `scripts/create-apkovl-yaml.sh` - Add download function, call in main loop
2. `scripts/build-from-yaml.sh` - Remove k3s installation from system-bootstrap
3. `k3s.yaml` - Add `cluster.k3s_version` field
4. `scripts/validate-config.sh` - Add k3s version validation (optional)

## Architecture Mapping

| Alpine Architecture | k3s Architecture |
|---------------------|------------------|
| aarch64             | arm64            |
| armv7 / armhf       | arm              |
| x86_64              | amd64            |

## Implementation Order

1. Add `download_k3s_binary()` function to `create-apkovl-yaml.sh`
2. Add `cluster.k3s_version` to `k3s.yaml`
3. Test build with single node
4. Remove k3s installation logic from `build-from-yaml.sh`
5. Update system-bootstrap to start k3s directly
6. Test full cluster build

## Testing

1. Build with different architectures (aarch64, x86_64)
2. Verify k3s binary exists in apkovl tarball
3. QEMU boot test - confirm k3s starts without download
4. Version mismatch test - confirm build fails with invalid version
5. Air-gap simulation - boot without network after build
