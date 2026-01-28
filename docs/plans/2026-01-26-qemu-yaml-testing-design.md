# QEMU YAML Testing Design

**Date:** 2026-01-26
**Status:** Design
**Author:** Claude Code

## Problem Statement

Currently, the Alpine diskless k3s project has a single configuration (`k3s.yaml`) that is configured for Raspberry Pi hardware (aarch64 architecture). Testing on macOS using QEMU requires:

1. **Architecture mismatch** - Building aarch64 packages that won't run in x86_64 QEMU
2. **Config complexity** - Test script must manually override/hack config values for QEMU
3. **Testing requires RPi config** - Can't run `make build` without having RPi-specific values
4. **Hardcoded package lists** - OpenSSH and e2fsprogs are hardcoded in shell scripts
5. **No separation** - Production and test artifacts mix in the same `builds/` directory

**Goal:** Create a clean separation between production (RPi/aarch64) and testing (QEMU/x86_64) environments with declarative, architecture-aware overlay package management.

## Proposed Solution

1. **Create `qemu.yaml`** - Full test configuration with QEMU-appropriate values
2. **Add `overlay_packages` section** - Declarative package listing with automatic architecture detection
3. **Separate build directories** - `builds/` for production, `builds-qemu/` for testing
4. **Simplify test script** - Remove overlay hacks, use pre-built apkovl
5. **Generic package processing** - Replace hardcoded package functions with YAML-driven approach

## Architecture

### Configuration Files

```
k3s.yaml (production)          qemu.yaml (testing)
├── arch: aarch64              ├── arch: x86_64
├── network: 192.168.1.x     ├── network: 10.0.2.x
├── storage: /dev/sda          ├── storage: /dev/sda
├── nodes: k3s-21/22/23        ├── nodes: qemu-test-1/2
└── overlay_packages           └── overlay_packages
    └── openssh, e2fsprogs         └── openssh, e2fsprogs
```

### Directory Structure

```
alpine-rpi-diskless/
├── k3s.yaml                 # Production: RPi/aarch64
├── qemu.yaml                # Testing: QEMU/x86_64
├── builds/                  # Production builds (aarch64)
│   ├── k3s-21.apkovl.tar.gz
│   └── ...
├── builds-qemu/             # Test builds (x86_64)
│   ├── qemu-test-1.apkovl.tar.gz
│   └── ...
└── test/
    └── test-alpine-diskless-boot.sh
```

## Components

### 1. New YAML Parser Functions

**File:** `lib/yaml-parser.sh`

```bash
# Get array of values from YAML
yaml_get_array() {
    local key="$1"
    local config_file="$2"

    python3 -c "
import yaml, sys
with open('$config_file') as f:
    data = yaml.safe_load(f)

keys = '$key'.split('.')
value = data
for k in keys:
    value = value.get(k, [])

if isinstance(value, list):
    for item in value:
        # If item is a dict, get its 'name' field
        if isinstance(item, dict):
            print(item.get('name', item))
        else:
            print(item)
" 2>/dev/null
}
```

### 2. Overlay Packages Section

**New YAML section:**

```yaml
overlay_packages:
  - name: "openssh"
  - name: "e2fsprogs"
  - name: "chrony"       # Optional: add more as needed
```

**How it works:**
1. Build script reads `overlay_packages` array from YAML
2. For each package:
   - Discovers version from APKINDEX (using architecture from `alpine.architecture`)
   - Downloads correct `.apk` file (aarch64 for RPi, x86_64 for QEMU)
   - Extracts entire package to overlay (binaries, libraries, configs)
3. Result: Architecture-aware binaries automatically included

### 3. Generic Package Processing Function

**File:** `scripts/create-apkovl-yaml.sh`

Replace hardcoded `prepare_openssh()`, `prepare_e2fsprogs()` with:

```bash
process_overlay_packages() {
    local apkovl_dir="$1"
    local config_file="$2"
    local arch=$(yaml_get "alpine.architecture" "$config_file")
    local alpine_version=$(yaml_get "alpine.version" "$config_file")
    local alpine_major=$(echo "$alpine_version" | cut -d'.' -f1-2)
    local base_url="http://dl-cdn.alpinelinux.org/alpine/v${alpine_major}/main/${arch}"

    local packages=$(yaml_get_array "overlay_packages" "$config_file")

    if [ -z "$packages" ]; then
        echo "No overlay packages specified"
        return 0
    fi

    # Download APKINDEX once for all packages
    local cache_dir="/tmp/overlay-packages-cache"
    rm -rf "$cache_dir"
    mkdir -p "$cache_dir"

    if ! curl -sL "${base_url}/APKINDEX.tar.gz" -o "$cache_dir/APKINDEX.tar.gz"; then
        echo "Error: Failed to download APKINDEX"
        return 1
    fi

    tar -xzf "$cache_dir/APKINDEX.tar.gz" -C "$cache_dir"

    # Process each package
    while IFS= read -r pkg_name; do
        echo "Processing overlay package: $pkg_name"

        # Discover version using fixed discover_package_version function
        local version=$(discover_package_version "$pkg_name" "$cache_dir")
        if [ -z "$version" ]; then
            echo "Error: Package $pkg_name not found in APKINDEX"
            return 1
        fi

        echo "Found $pkg_name version: $version"

        # Download package
        local apk_file="${cache_dir}/${pkg_name}.apk"
        if ! curl -sL "${base_url}/${pkg_name}-${version}.apk" -o "$apk_file"; then
            echo "Error: Failed to download $pkg_name"
            return 1
        fi

        # Extract entire package to overlay
        # This includes: binaries, libraries, config files, documentation
        tar -xzf "$apk_file" -C "$apkovl_dir"

        echo "Added $pkg_name to overlay"
    done <<< "$packages"

    # Clean up cache
    rm -rf "$cache_dir"
}
```

### 4. Separate Build Directories

**File:** `scripts/build-from-yaml.sh`

```bash
# Detect config type and set output directory
CONFIG_BASENAME=$(basename "$CONFIG_FILE" .yaml)

if [ "$CONFIG_BASENAME" = "qemu" ]; then
    BUILD_DIR="builds-qemu"
else
    BUILD_DIR="builds"
fi

mkdir -p "$BUILD_DIR"
```

### 5. Simplified Test Script

**File:** `test/test-alpine-diskless-boot.sh`

**Remove:**
- Overlay creation/modification logic
- Network config overrides
- qemu-device-setup service creation

**Keep:**
- QEMU VM management (download ISO, create disk, start VM)
- SSH connection info

**New approach:**
```bash
# Build with qemu config first
cd "$PROJECT_DIR"
make build CONFIG=qemu.yaml

# Use the built apkovl directly
APKVOL="$PROJECT_DIR/builds-qemu/qemu-test-1.apkovl.tar.gz"

# Extract and boot - no modifications needed
```

### 6. Updated Makefile

```makefile
# Production build (default)
build:
	./scripts/build-from-yaml.sh k3s.yaml

# Test build
build-test:
	./scripts/build-from-yaml.sh qemu.yaml

# Clean all builds
clean-all:
	rm -rf builds/* builds-qemu/*

# Clean production only
clean:
	rm -rf builds/*

# Clean test only
clean-test:
	rm -rf builds-qemu/*

# Run QEMU test
test-qemu: build-test
	./test/test-alpine-diskless-boot.sh
```

## File Changes Summary

### New Files
- `qemu.yaml` - QEMU testing configuration

### Modified Files
- `lib/yaml-parser.sh` - Add `yaml_get_array()` function
- `scripts/create-apkovl-yaml.sh` - Replace hardcoded package functions with `process_overlay_packages()`
- `test/test-alpine-diskless-boot.sh` - Simplify to use pre-built apkovl
- `Makefile` - Add test targets
- `k3s.yaml` - Add `overlay_packages` section

### Files to Delete
- None (backward compatible)

## Example Configs

### qemu.yaml (Complete)

```yaml
# Alpine Diskless k3s Cluster Configuration - QEMU Testing Environment

cluster:
  name: "alpine-k3s-test"
  k3s_version: "1.33"
  token: ""

network:
  domain: "local"
  subnet: "10.0.2.0/24"
  gateway: "10.0.2.2"
  dns_servers:
    - "10.0.2.3"
  loadbalancer_pool:
    start: "10.0.2.70"
    end: "10.0.2.80"

nodes:
  - name: "qemu-test-1"
    ip: "10.0.2.15"
    role: "master"
  - name: "qemu-test-2"
    ip: "10.0.2.16"
    role: "worker"

k3s:
  cluster_cidr: "10.42.0.0/16"
  service_cidr: "10.43.0.0/16"
  flannel_backend: "vxlan"

alpine:
  version: "3.22.1"
  architecture: "x86_64"
  timezone: "America/Denver"
  packages:
    - "curl"
    - "ca-certificates"
    - "iptables"
    - "ip6tables"
    - "util-linux"
    - "coreutils"
    - "findutils"
    - "netcat-openbsd"
    - "cgroup-tools"
    - "parted"
    - "chrony"

storage:
  device: "/dev/sda"
  boot_partition_size: "512MiB"
  data_mount: "/mnt/data"
  persistent_paths:
    - "/etc/k3s"
    - "/var/lib/k3s"

ssh:
  port: 22
  permit_root_login: true
  password_authentication: true
  authorized_keys:
    - "ssh-ed25519 REDACTED_SSH_KEY_1 you@example.com"
    - "ssh-ed25519 REDACTED_SSH_KEY_2 user@host.local"

overlay_packages:
  - name: "openssh"
  - name: "e2fsprogs"
```

### k3s.yaml (Add overlay_packages section)

```yaml
# ... existing content ...
# Add at the end:

overlay_packages:
  - name: "openssh"
  - name: "e2fsprogs"
```

## Migration Strategy

### Phase 1: Add Infrastructure (No breaking changes)
1. Add `yaml_get_array()` to `lib/yaml-parser.sh`
2. Add `process_overlay_packages()` to `scripts/create-apkovl-yaml.sh`
3. Keep old functions, call both for now
4. Test: Existing builds still work

### Phase 2: Create qemu.yaml
1. Create `qemu.yaml` with x86_64 architecture and QEMU network
2. Add overlay_packages section
3. Test: `make build CONFIG=qemu.yaml`
4. Verify: x86_64 binaries in `builds-qemu/`

### Phase 3: Update k3s.yaml
1. Add overlay_packages section to `k3s.yaml`
2. Test: `make build CONFIG=k3s.yaml`
3. Verify: aarch64 binaries in `builds/`
4. Remove old hardcoded functions

### Phase 4: Simplify Test Script
1. Update `test/test-alpine-diskless-boot.sh`
2. Remove overlay creation/modification logic
3. Use pre-built `builds-qemu/qemu-test-1.apkovl.tar.gz`
4. Test: `make test-qemu`

## Testing & Validation

### Verification Commands

```bash
# Verify architecture-specific binaries
make build CONFIG=k3s.yaml
tar -tzf builds/k3s-21.apkovl.tar.gz | grep "usr/sbin/sshd"

make build CONFIG=qemu.yaml
tar -tzf builds-qemu/qemu-test-1.apkovl.tar.gz | grep "usr/sbin/sshd"

# Verify overlay packages included
tar -tzf builds/k3s-21.apkovl.tar.gz | grep -E "ssh|e2fsprogs"
tar -tzf builds-qemu/qemu-test-1.apkovl.tar.gz | grep -E "ssh|e2fsprogs"
```

### QEMU Test

```bash
# Build and test
make test-qemu

# SSH into QEMU VM
ssh root@localhost -p 2222
```

## Success Criteria

- [ ] `qemu.yaml` builds successfully with x86_64 binaries
- [ ] `k3s.yaml` builds successfully with aarch64 binaries
- [ ] Separate build directories (builds/ vs builds-qemu/)
- [ ] overlay_packages section works for both configs
- [ ] QEMU test boots and SSH accessible
- [ ] Test script simplified (no overlay hacks)
- [ ] Backward compatible (existing k3s.yaml still works)

## Benefits

- **Declarative** - Config shows exactly what packages are included
- **Architecture-aware** - Correct binaries auto-selected per config
- **Clean separation** - Production and test artifacts in separate directories
- **Simple** - No need to know package internals
- **Backward compatible** - Existing configs continue to work
