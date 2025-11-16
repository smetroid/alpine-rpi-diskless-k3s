# Troubleshooting Guide

This guide covers common issues encountered when setting up and running Alpine Linux diskless k3s clusters.

## Table of Contents
- [First Boot Issues](#first-boot-issues)
- [Storage and Mounting](#storage-and-mounting)
- [Service Dependencies](#service-dependencies)
- [QEMU Testing](#qemu-testing)
- [Network Issues](#network-issues)

---

## First Boot Issues

### Mount Fails with "Invalid Argument"

**Symptom:**
```
* Formatting data partition...
* Data partition formatted successfully
* Mounting persistent storage...
mount: mounting /dev/mmcblk0p2 on /mnt/data failed: Invalid argument
```

**Root Cause:**
After `mkfs.ext4` formats a partition, the kernel needs time to:
- Flush write buffers to disk
- Update filesystem metadata cache
- Recognize the new filesystem

On fast systems (especially QEMU), mount attempts happen too quickly.

**Solution:**
The `storage-init` service now includes aggressive synchronization:
- 6-step sync process (~7-8 seconds)
- 3 mount attempts with retry logic
- Total potential sync time: up to 12 seconds

**If mount still fails:**
1. **Reboot** - On second boot, filesystem will mount successfully
2. **Wait and retry** - Run `rc-service storage-init restart` after 10 seconds
3. **Use pre-partitioned template** - See [QEMU Testing](#using-pre-partitioned-qcow2-template)

---

### Partition Devices Don't Appear

**Symptom:**
```
* First boot detected - setting up storage partitions...
(fdisk creates partitions)
* Creating Raspberry Pi device simulation...
mknod: /dev/mmcblk0p2: No such file or directory
```

**Root Cause:**
After `fdisk` creates partitions and `partprobe` tells the kernel to re-scan, the actual device nodes (`/dev/sda1`, `/dev/sda2`) are created asynchronously by the kernel.

**Solution:**
The `qemu-device-setup` service now polls for partition devices:
```bash
# Waits up to 10 seconds for /dev/sda1 and /dev/sda2 to appear
while [ $count -lt 10 ]; do
    if [ -b "${STORAGE_DEV}1" ] && [ -b "${STORAGE_DEV}2" ]; then
        break
    fi
    sleep 1
done
```

**If devices never appear:**
- Check kernel logs: `dmesg | grep sd`
- Manually run: `partprobe /dev/sda && sleep 3`
- Verify disk exists: `fdisk -l /dev/sda`

---

## Storage and Mounting

### Read-Only Filesystem After Boot

**Symptom:**
```
* Storage mounted at /mnt/data
* Storage mounted as read-only, attempting to remount...
```

**Root Cause:**
Filesystem mounted read-only due to:
- Filesystem errors (unclean shutdown)
- Mount options
- Device issues

**Solution:**
The `storage-init` service automatically:
1. Detects read-only mounts with write test
2. Runs `e2fsck -p` to check/fix filesystem errors
3. Remounts as read-write: `mount -o remount,rw`
4. Verifies write capability

**Manual fix:**
```bash
# Check filesystem
e2fsck -p /dev/sda2

# Remount read-write
mount -o remount,rw /mnt/data

# Verify
touch /mnt/data/test && rm /mnt/data/test
```

---

### Alpine Auto-Mounts Partition Before storage-init

**Symptom:**
```
mount: /dev/sda2 already mounted or mount point busy
sda2: Can't mount, would change RO state
```

**Root Cause:**
Alpine's init automatically mounts partitions to `/media/<partition-name>` during boot, before OpenRC services run. When `storage-init` tries to mount the same partition to `/mnt/data`, it fails.

**Solution:**
The `storage-init` service now uses smart bind mounting:

1. **Detects Alpine's mount:**
   ```bash
   PARTITION_NAME=$(basename "$DATA_PARTITION")  # sda2
   if mountpoint -q "/media/$PARTITION_NAME"; then
       ALPINE_MOUNT_POINT="/media/$PARTITION_NAME"
   fi
   ```

2. **Creates bind mount:**
   ```bash
   mount --bind /media/sda2 /mnt/data
   ```

**Result:** Both `/media/sda2` and `/mnt/data` work, no conflicts!

---

### Storage Works on SD Card but Not USB

**Root Cause:**
Hardcoded device paths in scripts only checked for `/media/mmcblk0p2` (SD card), missing `/media/sda2` (USB).

**Solution:**
Dynamic partition name detection:
```bash
# Works for ANY device type
PARTITION_NAME=$(basename "$DATA_PARTITION")
# /dev/mmcblk0p2 → mmcblk0p2
# /dev/sda2 → sda2
# /dev/vda2 → vda2

ALPINE_MOUNT_POINT="/media/$PARTITION_NAME"
```

**Supported devices:**
- SD cards: `/dev/mmcblk0`
- USB drives: `/dev/sda`, `/dev/sdb`
- QEMU virtio: `/dev/vda`

---

## Service Dependencies

### Services Start Out of Order

**Symptom:**
```
* Setting up QEMU device simulation...
(Installing packages...)  ← system-bootstrap running
* Preparing storage initialization... ← storage-init also running
* Failed to mount storage
```

**Root Cause:**
`system-bootstrap` didn't declare dependency on `storage-init`, so OpenRC started them in parallel.

**Solution:**
Fixed service dependencies in `scripts/build-from-yaml.sh`:

```bash
# system-bootstrap now requires storage-init
depend() {
    need localmount storage-init  # ← Added storage-init
    after localmount storage-init
    before k3s-bootstrap
}
```

**Service boot order:**
```
localmount
  ↓
qemu-device-setup (creates device nodes)
  ↓
storage-init (mounts /mnt/data) ✅ Completes first
  ↓
system-bootstrap (installs packages) ✅ Waits for storage
  ↓
k3s-bootstrap (installs k3s)
  ↓
lbu-persist (saves on shutdown)
```

---

## QEMU Testing

### No Space Left on Device (RAM Full)

**Symptom:**
```
ERROR: Failed to create usr/lib/libunistring.so.5.2.0: No space left on device
Failed to install tzdata package
```

**Root Cause:**
Alpine diskless runs entirely in RAM. With 512MB RAM:
- Alpine base: ~100MB
- Runtime apkovl extraction: ~200-500MB
- Package installation: ~300-500MB
- Total needed: **2GB minimum**

**Solution:**
Increased RAM in `test/test-alpine-diskless-boot.sh`:
```bash
RAM_SIZE="2048M"  # Was 512M
```

**Memory breakdown:**
- Alpine base system: ~100MB
- Runtime apkovl (full snapshot): ~200-500MB
- Package installation: ~300-500MB
- k3s runtime: ~500MB-1GB
- **Recommended: 2GB for comfortable operation**

---

### Using Pre-Partitioned qcow2 Template

**Problem:** First boot partitioning/formatting causes mount issues

**Solution:** Create a reusable template disk

**Step 1: Create template (one-time setup):**
```bash
# Run first boot to partition and format
./test/test-alpine-diskless-boot.sh

# After boot completes, save as template
cd test/vm-diskless
cp data.qcow2 data-partitioned-template.qcow2
```

**Step 2: Use template (every test):**
```bash
# Clean start
rm -f test/vm-diskless/data.qcow2

# Run test - automatically copies template
./test/test-alpine-diskless-boot.sh
```

**Benefits:**
✅ No partitioning on every boot
✅ No formatting delays
✅ Mount works immediately
✅ Faster test iterations

**Template detection:**
```bash
if [ -f "data-partitioned-template.qcow2" ]; then
    log "Using pre-partitioned template"
    cp data-partitioned-template.qcow2 data.qcow2
fi
```

---

## Persistence and LBU

### Runtime Changes Not Preserved

**Symptom:**
After reboot, installed packages or configuration changes are lost.

**Root Cause:**
The `lbu-commit-runtime` script only backed up `/etc`, not `/usr/local`, `/root`, or `/var/lib`.

**Solution:**
Full system snapshot now captures:
- `/etc` - All configuration files
- `/usr/local` - Custom scripts (`k3s_bootstrap`, etc.)
- `/root` - SSH keys and root configs
- `/var/lib` - Runtime state (selective)

**How it works:**
1. **First boot:** `system-bootstrap` creates `runtime-k3s-21-test.apkovl.tar.gz`
2. **Shutdown:** `lbu-persist` updates the runtime apkovl
3. **Next boot:** Alpine's init automatically loads runtime apkovl
4. **All changes preserved!**

---

### lbu-restore Service Redundant

**Why removed:**
Alpine's init automatically finds and loads any `.apkovl.tar.gz` files on mounted partitions **before OpenRC starts**. The `lbu-restore` service would re-extract the same files, wasting time.

**Boot sequence:**
```
Alpine init (before OpenRC):
  └─ Scans /media/sda2/
  └─ Finds runtime-k3s-21-test.apkovl.tar.gz
  └─ Extracts to / automatically ✅

OpenRC starts:
  └─ lbu-restore would re-extract (redundant) ❌
```

**Current design:**
- `lbu-persist`: Saves changes on shutdown ✅
- `lbu-restore`: Removed (Alpine handles it) ✅

---

## Network Issues

### DHCP Doesn't Work in QEMU

**Solution:**
The test script creates a dynamic network service that detects interfaces:

```bash
# Scans for eth0, enp*, ens*, etc.
for dev in /sys/class/net/*; do
    INTERFACE=$(basename "$dev")
    case ${INTERFACE%%[0-9]*} in
        eth|enp|ens)
            echo "auto $INTERFACE" >> /etc/network/interfaces
            echo "iface $INTERFACE inet dhcp" >> /etc/network/interfaces
            ;;
    esac
done
```

---

## Common Commands

### Check Service Status
```bash
rc-status
rc-service storage-init status
rc-service system-bootstrap status
```

### View Service Logs
```bash
# OpenRC doesn't log by default, check dmesg
dmesg | grep storage-init
dmesg | grep system-bootstrap

# Or check service output
rc-service storage-init start 2>&1 | tee /tmp/storage-init.log
```

### Manual Storage Recovery
```bash
# Check what's mounted
mount | grep sda
mount | grep mnt

# Manually mount
mkdir -p /mnt/data
mount /dev/sda2 /mnt/data

# Check filesystem
e2fsck -f /dev/sda2
```

### Rebuild Configuration
```bash
# Clean rebuild
rm -rf builds/k3s-*-apkovl builds/*.apkovl.tar.gz
./build-from-yaml.sh k3s.yaml

# Test changes
./test/test-alpine-diskless-boot.sh
```

---

## Debugging Tips

### Enable Verbose Boot
Add to kernel command line in boot config:
```
loglevel=7 debug
```

### Check Partition Table
```bash
fdisk -l /dev/sda
parted /dev/sda print
```

### Monitor Boot Process
```bash
# In QEMU
tail -f /var/log/messages

# Or watch dmesg
watch -n 1 dmesg | tail -20
```

### Verify apkovl Contents
```bash
# List files in apkovl
tar -tzf /media/sda2/runtime-k3s-21-test.apkovl.tar.gz

# Check for specific files
tar -tzf /media/sda2/runtime-k3s-21-test.apkovl.tar.gz | grep k3s_bootstrap
```
