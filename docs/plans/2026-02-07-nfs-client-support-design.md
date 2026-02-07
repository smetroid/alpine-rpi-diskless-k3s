# NFS Client Support Design

**Date:** 2026-02-07
**Author:** Claude Code
**Status:** Implemented

## Overview

This document describes the NFS client support added to the Alpine Linux diskless k3s cluster. The feature enables Kubernetes pods (deployed via Helm) to mount NFS volumes from a Synology NAS for persistent storage, shared data, and backups.

## Problem Statement

When attempting to mount NFS volumes from a Synology NAS, the following error occurred:

```
mount.nfs: rpc bind failed: Operation not permitted
```

The solution required:
1. Installing `nfs-utils` package
2. Installing and enabling `rpcbind` service
3. Starting the rpcbind service

These manual steps needed to be automated as part of the overlay generation.

## Solution

Add NFS client packages to the overlay and automatically enable the rpcbind service during apkovl generation.

## Implementation

### 1. Package Additions

Added the following packages to `overlay_packages` in `k3s.yaml`:

```yaml
overlay_packages:
  # ... existing packages ...
  # NFS client support (for mounting from NAS via Kubernetes/Helm)
  - name: "nfs-utils"      # NFS client utilities
  - name: "rpcbind"        # RPC portmapper (required for NFS)
  - name: "rpcbind-openrc" # OpenRC init script for rpcbind
  - name: "keyutils"       # Key utilities for NFS authentication
  - name: "libevent"       # Event library (dependency for rpcbind)
```

### 2. Automatic Service Configuration

Added `configure_nfs_client()` function in `scripts/create-apkovl-yaml.sh`:

```bash
configure_nfs_client() {
    local apkovl_dir="$1"
    local config_file="$2"

    # Check if nfs-utils is in overlay packages
    local packages=$(yaml_get_array ".overlay_packages[].name" "$config_file")
    local has_nfs_utils=0

    while IFS= read -r pkg_name; do
        [ -z "$pkg_name" ] && continue
        if [ "$pkg_name" = "nfs-utils" ]; then
            has_nfs_utils=1
            break
        fi
    done <<< "$packages"

    # If nfs-utils is included, enable rpcbind service
    if [ "$has_nfs_utils" = "1" ]; then
        echo "Configuring NFS client support..."

        # Enable rpcbind in default runlevel
        ln -sf /etc/init.d/rpcbind "${apkovl_dir}/etc/runlevels/default/rpcbind"
        echo "  ✓ rpcbind service enabled for NFS client support"
    fi
}
```

### 3. Boot Sequence

With NFS client support, the boot sequence is:

```
1. Overlay extracted from apkovl
   ├── nfs-utils binaries installed
   ├── rpcbind init script present
   └── rpcbind enabled in default runlevel

2. OpenRC starts services
   ├── rpcbind starts (required for NFS)
   ├── Network becomes ready
   └── k3s starts

3. Kubernetes pods can now mount NFS volumes
   └── Helm-deployed NFS provisioner/client works
```

## Files Modified

**Modified:**
- `k3s.yaml` - Added NFS client packages to overlay_packages
- `scripts/create-apkovl-yaml.sh` - Added configure_nfs_client() function

## Result

**What's Included:**
- `mount.nfs` - NFS mount utility (in `/sbin/mount.nfs`)
- `showmount` - Show NFS exports (in `/usr/sbin/showmount`)
- `rpcbind` - RPC portmapper service
- Various NFS utilities in `/usr/sbin/`

**Service Status:**
- `rpcbind` enabled in default runlevel
- Starts automatically on boot
- No manual configuration needed

**Use Cases Enabled:**
- Persistent storage for Kubernetes pods (PVs/PVCs backed by NAS)
- Shared data between nodes via NFS
- Backup/restore to NAS

## Usage

No configuration changes needed - simply rebuild the apkovl archives:

```bash
make build
```

The NFS client support will be included automatically when `nfs-utils` is in the overlay packages list.

**In Kubernetes/Helm:**

Deploy your NFS provisioner or client via Helm. The pods will be able to mount NFS shares from your Synology NAS:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: 192.168.1.3  # Synology NAS IP
    path: /volume1/kubernetes
```

## Verification

After building, verify the configuration:

```bash
# Check rpcbind service is enabled
ls -la builds/k3s-21-apkovl/etc/runlevels/default/rpcbind

# Check NFS utilities exist
ls builds/k3s-21-apkovl/sbin/mount.nfs
ls builds/k3s-21-apkovl/usr/sbin/showmount

# Check rpcbind init script exists
ls builds/k3s-21-apkovl/etc/init.d/rpcbind
```

## Cache Impact

The new packages add approximately 900KB to the overlay:
- nfs-utils: ~400KB
- rpcbind: ~80KB
- rpcbind-openrc: ~5KB
- keyutils: ~50KB
- libevent: ~350KB

These are cached in `.cache/apk/aarch64/` after first download.
