#!/bin/sh
# Minimal config backup script - only saves essential configuration files
# Large data (k3s, containers) is already persisted via bind mounts

HOSTNAME=$(hostname)
BACKUP_FILE="/mnt/data/runtime-${HOSTNAME}.apkovl.tar.gz"
TEMP_DIR="/tmp/runtime-snapshot"

# Ensure /mnt/data is writable
if [ ! -w "/mnt/data" ]; then
    echo "ERROR: /mnt/data is not writable, attempting remount..."
    mount -o remount,rw /mnt/data 2>/dev/null || {
        echo "ERROR: Failed to remount /mnt/data as read-write"
        exit 1
    }
fi

echo "Creating minimal config snapshot..."

# Clean up any previous temp directory
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Only capture essential configuration files (NOT large data dirs)
# These are files that may change at runtime and aren't covered by bind mounts

# /etc - selective capture (skip large/transient dirs)
mkdir -p "$TEMP_DIR/etc"
echo "  📋 Capturing essential /etc configs..."
# Core system config
cp -a /etc/hostname "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/hosts "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/resolv.conf "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/passwd "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/shadow "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/group "$TEMP_DIR/etc/" 2>/dev/null || true
# Network config
cp -a /etc/network "$TEMP_DIR/etc/" 2>/dev/null || true
# SSH config (keys are in /mnt/data/ssh via ssh-persist)
cp -a /etc/ssh "$TEMP_DIR/etc/" 2>/dev/null || true
# APK config
cp -a /etc/apk "$TEMP_DIR/etc/" 2>/dev/null || true
# Init scripts and runlevels
cp -a /etc/init.d "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/runlevels "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/local.d "$TEMP_DIR/etc/" 2>/dev/null || true
# LBU config
cp -a /etc/lbu "$TEMP_DIR/etc/" 2>/dev/null || true
# Timezone
cp -a /etc/timezone "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/localtime "$TEMP_DIR/etc/" 2>/dev/null || true
# Machine ID (required for k3s/containerd node identification)
cp -a /etc/machine-id "$TEMP_DIR/etc/" 2>/dev/null || true

# /root/.ssh - authorized keys
if [ -d /root/.ssh ]; then
    echo "  🔑 Capturing /root/.ssh..."
    mkdir -p "$TEMP_DIR/root"
    cp -a /root/.ssh "$TEMP_DIR/root/" 2>/dev/null || true
fi

# Create the runtime snapshot tarball
cd "$TEMP_DIR" || exit 1
if tar -czf "$BACKUP_FILE" . 2>/dev/null; then
    echo "✅ Runtime config saved: $BACKUP_FILE"
    # Verify the archive
    if tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
        ARCHIVE_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        FILE_COUNT=$(tar -tzf "$BACKUP_FILE" | wc -l)
        echo "   Size: $ARCHIVE_SIZE ($FILE_COUNT files)"
        sync
    else
        echo "⚠️  Warning: Archive verification failed, removing corrupted file"
        rm -f "$BACKUP_FILE"
    fi
else
    echo "❌ ERROR: Failed to create config backup"
    cd /
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Cleanup
cd /
rm -rf "$TEMP_DIR"

echo "Config snapshot complete"
