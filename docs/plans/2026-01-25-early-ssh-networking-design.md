# Early SSH and Networking Design

**Date:** 2026-01-25
**Status:** Design
**Author:** Claude Code

## Problem Statement

Currently, SSH and networking setup depend on the `storage-init` service completing successfully. This creates a circular dependency problem:

1. If `storage-init` fails (partition issues, filesystem corruption, etc.)
2. SSH is never started
3. No remote troubleshooting is possible
4. Physical access to the device is required to diagnose the issue

**Goal:** Enable networking and SSH access before `storage-init` runs, enabling remote troubleshooting even when storage fails.

## Current Architecture

### Service Dependency Chain
```
localmount → networking (default runlevel)
localmount → storage-init
storage-init → ssh-persist (installs openssh, generates keys, starts SSH)
storage-init → system-bootstrap
system-bootstrap → k3s-bootstrap
```

### Current Setup
- `/etc/network/interfaces` - Static network config (from apkovl overlay)
- `/etc/ssh/sshd_config` - SSH daemon config (from apkovl overlay)
- `ssh-persist` service - Installs openssh packages via apk, then starts SSH

### Issue
- `networking` is in default runlevel (starts relatively late)
- `ssh-persist` waits for `storage-init` to install openssh
- No SSH access if storage fails

## Proposed Solution

Reorder services and add OpenSSH binaries to the apkovl overlay:

1. **Add OpenSSH to overlay** - Binaries available immediately, no apk install needed
2. **Move networking to boot runlevel** - Starts earlier in boot sequence
3. **Create early-ssh service** - Starts SSH in boot runlevel, before storage-init
4. **Modify ssh-persist** - Detect if SSH already running, skip redundant setup

## New Architecture

### Service Dependency Chain
```
localmount → networking (boot runlevel) ← MOVED EARLIER
         → early-ssh (boot runlevel) ← NEW
         → storage-init
         → ssh-persist (backs up keys to persistent storage)
         → system-bootstrap
         → k3s-bootstrap
```

### Boot Runlevel Services
- `networking` - Network interface configuration
- `early-ssh` - Generate SSH keys (if needed), start SSH daemon

### Default Runlevel Services
- `storage-init` - Mount persistent storage, setup bind mounts
- `ssh-persist` - Backup SSH keys to persistent storage
- `system-bootstrap` - System initialization
- `k3s-bootstrap` - Kubernetes initialization

## Components

### 1. Modified: `scripts/create-apkovl-yaml.sh`

#### Change: Add OpenSSH packages to overlay

Add functions to download and extract OpenSSH binaries (similar to e2fsprogs handling):

```bash
prepare_openssh() {
    # Downloads openssh, openssh-server, openssh-keygen packages
    # Extracts to cache directory
}

add_openssh_to_apkovl() {
    # Copies binaries to overlay:
    # - /usr/bin/ssh, /usr/bin/scp
    # - /usr/sbin/sshd
    # - Required libraries
}
```

#### Change: Move networking to boot runlevel

```bash
# OLD:
ln -sf /etc/init.d/networking "${NODE_NAME}-apkovl/etc/runlevels/default/networking"

# NEW:
ln -sf /etc/init.d/networking "${NODE_NAME}-apkovl/etc/runlevels/boot/networking"
```

#### Change: Create early-ssh service

New OpenRC service at `/etc/init.d/early-ssh`:

```bash
#!/sbin/openrc-run

description="Early SSH service - starts before storage-init"
name="early ssh"

depend() {
    need networking
    after networking
    before storage-init
    provide early-ssh
}

start() {
    # Generate SSH host keys if not present
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N "" -q
        ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key -N "" -q
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q
    fi

    # Start sshd if not already running
    if ! rc-service sshd status >/dev/null 2>&1; then
        rc-service sshd start
    fi
}
```

Add to boot runlevel:
```bash
ln -sf /etc/init.d/early-ssh "${NODE_NAME}-apkovl/etc/runlevels/boot/early-ssh"
```

### 2. Modified: `ssh-persist` Service

Update `start()` function to detect already-running SSH:

```bash
start() {
    # Check if SSH already started by early-ssh
    if rc-service sshd status >/dev/null 2>&1; then
        einfo "SSH already running - ensuring persistence"

        # Backup keys to persistent storage
        if [ -d /mnt/data ] && mountpoint -q /mnt/data; then
            mkdir -p /mnt/data/ssh
            cp -a /etc/ssh/ssh_host_*_key* /mnt/data/ssh/ 2>/dev/null
        fi

        return 0
    fi

    # Fallback: install openssh and start SSH (current behavior)
    ...
}
```

## Boot Sequence Flow

### Current Boot Order
1. `localmount` - Mount local filesystems
2. `networking` - Start network (default runlevel)
3. `storage-init` - Mount /mnt/data
4. `ssh-persist` - Install openssh, generate keys, start SSH
5. `system-bootstrap` - Install packages, configure system
6. `k3s-bootstrap` - Install and start k3s

### New Boot Order
1. `localmount` - Mount local filesystems
2. `networking` - Start network (**boot runlevel**)
3. `early-ssh` - Generate keys, start SSH (**boot runlevel**)
4. `storage-init` - Mount /mnt/data
5. `ssh-persist` - Backup keys to /mnt/data/ssh
6. `system-bootstrap` - Install packages, configure system
7. `k3s-bootstrap` - Install and start k3s

## SSH Key Lifecycle

### First Boot
1. `early-ssh` runs: No keys exist → generates new keys → starts SSH
2. `ssh-persist` runs: SSH already running → copies keys to `/mnt/data/ssh/`

### Subsequent Boots
1. `early-ssh` runs: Keys exist in overlay (from previous LBU commit) → uses those → starts SSH
2. `ssh-persist` runs: SSH already running → ensures keys backed up to `/mnt/data/ssh/`

### Storage Failure Scenario
1. `early-ssh` runs: Generates keys → starts SSH
2. `storage-init` fails: Storage partition not available
3. `ssh-persist` runs: Detects SSH running, tries to backup keys, skips if `/mnt/data` unavailable
4. **Result:** SSH still accessible for troubleshooting!

## Testing & Validation

### Test Scenarios

#### 1. Normal Boot (First Boot)
- Build new apkovl with changes
- Boot fresh node
- Verify: `networking` starts in boot runlevel
- Verify: `early-ssh` starts and generates keys
- Verify: SSH accessible before storage-init
- Verify: `storage-init` completes
- Verify: `ssh-persist` backs up keys to `/mnt/data/ssh/`

#### 2. Normal Boot (Subsequent Boot)
- Reboot node
- Verify: SSH starts quickly with existing keys
- Verify: Keys backed up to persistent storage

#### 3. Storage Failure Scenario
- Simulate failed storage partition (remove or corrupt)
- Boot node
- Verify: `networking` starts
- Verify: `early-ssh` starts and generates new keys
- Verify: SSH accessible for troubleshooting
- Verify: `storage-init` fails gracefully
- Verify: `ssh-persist` detects SSH running, skips backup gracefully

### Validation Commands

```bash
# Check service runlevels
rc-status --boot
# Should show: networking, early-ssh

rc-status --default
# Should show: storage-init, ssh-persist, system-bootstrap

# Check service dependencies
rc-depend --notreally early-ssh
rc-depend --notreally ssh-persist

# Verify SSH accessible early
ssh -o ConnectTimeout=5 root@<node-ip>

# Check if openssh binaries in overlay
tar -tzf builds/<node>.apkovl.tar.gz | grep -E "usr/bin/ssh|usr/sbin/sshd"
```

## Files to Modify

1. **`scripts/create-apkovl-yaml.sh`** - Main build script
   - Add `prepare_openssh()` function
   - Add `add_openssh_to_apkovl()` function
   - Move networking to boot runlevel
   - Create `early-ssh` service definition
   - Modify `ssh-persist` service definition

## Risk Assessment

**Risk Level:** Low

- Service reordering is reversible
- Keeping openssh in overlay is harmless even if not used early
- Existing `ssh-persist` behavior remains as fallback
- No changes to storage or networking logic

## Rollback Plan

If issues arise:
1. Revert `networking` to default runlevel
2. Remove `early-ssh` from boot runlevel
3. Revert `ssh-persist` to original behavior
4. Keep openssh in overlay (harmless if not used early)

## Success Criteria

- [ ] SSH accessible within 30 seconds of boot (before storage-init)
- [ ] Storage failure doesn't prevent SSH access
- [ ] Existing functionality unchanged after storage-init completes
- [ ] QEMU testing passes all scenarios
- [ ] No package size regression (openssh ~2MB)
