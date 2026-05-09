#!/sbin/openrc-run

description="Storage initialization and persistent storage service"
name="storage init"

depend() {
    need localmount
    after localmount
    before system-bootstrap
    provide storage-init
}

start() {
    ebegin "Setting up persistent storage"

    # Ensure ext4 module is loaded (needed for mkfs.ext4 and mount)
    modprobe ext4 2>/dev/null || true

    # Auto-detect storage device - supports SD card, USB, and virtio
    einfo "Auto-detecting storage device..."
    STORAGE_DEVICE=""
    DATA_PARTITION=""

    # Check for SD card device (Raspberry Pi SD card)
    if [ -b "/dev/mmcblk0" ]; then
        STORAGE_DEVICE="/dev/mmcblk0"
        DATA_PARTITION="/dev/mmcblk0p2"
        einfo "Detected SD card device: $STORAGE_DEVICE"
    # Check for SCSI/USB storage (first device)
    elif [ -b "/dev/sda" ]; then
        STORAGE_DEVICE="/dev/sda"
        DATA_PARTITION="/dev/sda2"
        einfo "Detected SCSI/USB device: $STORAGE_DEVICE"
    # Check for virtio storage
    elif [ -b "/dev/vda" ]; then
        STORAGE_DEVICE="/dev/vda"
        DATA_PARTITION="/dev/vda2"
        einfo "Detected virtio device: $STORAGE_DEVICE"
    # Check for second SCSI/USB device
    elif [ -b "/dev/sdb" ]; then
        STORAGE_DEVICE="/dev/sdb"
        DATA_PARTITION="/dev/sdb2"
        einfo "Detected SCSI/USB device: $STORAGE_DEVICE"
    else
        eerror "No storage device found"
        einfo "Available devices:"
        ls -la /dev/mmc* /dev/sd* /dev/vd* 2>/dev/null || einfo "No storage devices found"
        eend 1 "Storage device not found"
        return 1
    fi

    # Verify data partition exists
    einfo "Verifying data partition $DATA_PARTITION..."
    if [ ! -b "$DATA_PARTITION" ]; then
        eerror "Data partition $DATA_PARTITION not found"
        einfo "Run setup-sd-card.sh first to create the partition layout"
        einfo "Available partitions:"
        ls -la ${STORAGE_DEVICE}* 2>/dev/null || einfo "No partitions found"
        eend 1 "Data partition not found"
        return 1
    fi
    einfo "Data partition verified"

    # Format if needed
    if [ -b "$DATA_PARTITION" ] && ! blkid $DATA_PARTITION | grep -q ext4; then
        einfo "Formatting data partition..."
        if /sbin/mkfs.ext4 -F -L DATA $DATA_PARTITION; then
            einfo "Data partition formatted successfully"

            # CRITICAL: Aggressive sync - wait for kernel to recognize filesystem
            # After mkfs, the kernel needs time to update metadata before mounting
            einfo "Syncing filesystem buffers (this may take a few seconds)..."

            # Step 1: Flush all kernel buffers to disk
            sync
            blockdev --flushbufs $DATA_PARTITION 2>/dev/null || true

            # Step 2: Wait for I/O to complete
            sleep 3

            # Step 3: Force kernel to re-read device metadata
            blockdev --rereadpt $STORAGE_DEVICE 2>/dev/null || true
            partprobe $DATA_PARTITION 2>/dev/null || true

            # Step 4: Trigger udev to recognize filesystem (if available)
            if command -v udevadm >/dev/null 2>&1; then
                einfo "Triggering udev device recognition..."
                udevadm trigger --subsystem-match=block >/dev/null 2>&1 || true
                udevadm settle --timeout=5 2>/dev/null || true
            fi

            # Step 5: Final sync and wait
            sync
            sleep 2

            # Step 6: Verify filesystem is recognized
            if blkid $DATA_PARTITION | grep -q ext4; then
                einfo "Filesystem verified and ready for mounting"
            else
                ewarn "Filesystem created but not yet recognized by kernel"
                ewarn "Mount may fail - this is expected on first boot"
            fi
        else
            eend 1 "Failed to format data partition"
            return 1
        fi
    fi

    # Check if Alpine already mounted the data partition (common during boot)
    # Alpine mounts partitions to /media/<partition-name>
    # Note: In QEMU testing, we create /dev/mmcblk0p2 as a block device with same
    # major:minor as /dev/sda2, but Alpine mounts the real device at /media/sda2
    PARTITION_NAME=$(basename "$DATA_PARTITION")
    ALPINE_MOUNT_POINT=""

    # First, check if mounted by our partition name (e.g., mmcblk0p2)
    if mountpoint -q "/media/$PARTITION_NAME" 2>/dev/null; then
        ALPINE_MOUNT_POINT="/media/$PARTITION_NAME"
        einfo "Data partition already mounted by Alpine at /media/$PARTITION_NAME"
    else
        # Check if the same device (by major:minor) is mounted elsewhere in /media
        # This handles QEMU simulation where mmcblk0p2 and sda2 share the same major:minor
        if [ -b "$DATA_PARTITION" ]; then
            DATA_MAJOR_MINOR=$(stat -c "%t:%T" "$DATA_PARTITION" 2>/dev/null)
            for media_mount in /media/*; do
                if [ -d "$media_mount" ] && mountpoint -q "$media_mount" 2>/dev/null; then
                    # Get the device mounted here
                    MOUNTED_DEV=$(mount | grep " $media_mount " | awk '{print $1}')
                    if [ -b "$MOUNTED_DEV" ]; then
                        MOUNTED_MAJOR_MINOR=$(stat -c "%t:%T" "$MOUNTED_DEV" 2>/dev/null)
                        if [ "$DATA_MAJOR_MINOR" = "$MOUNTED_MAJOR_MINOR" ]; then
                            ALPINE_MOUNT_POINT="$media_mount"
                            einfo "Data partition already mounted by Alpine at $media_mount (same device)"
                            break
                        fi
                    fi
                fi
            done
        fi
    fi

    # Mount data partition
    mkdir -p /mnt/data
    if [ -n "$ALPINE_MOUNT_POINT" ]; then
        # Alpine already mounted it - remount read-write if needed, then bind mount
        # Alpine often mounts partitions read-only during boot
        if mount | grep " $ALPINE_MOUNT_POINT " | grep -q "[ (]ro[,)]"; then
            einfo "Remounting $ALPINE_MOUNT_POINT as read-write..."
            mount -o remount,rw "$ALPINE_MOUNT_POINT" || {
                ewarn "Could not remount as read-write, trying to continue..."
            }
        fi

        einfo "Creating bind mount from $ALPINE_MOUNT_POINT to /mnt/data..."
        if mount --bind "$ALPINE_MOUNT_POINT" /mnt/data; then
            einfo "Storage bind-mounted at /mnt/data (source: $ALPINE_MOUNT_POINT)"
        else
            eend 1 "Failed to bind mount storage"
            return 1
        fi
    else
        # Alpine hasn't mounted it yet - mount directly to /mnt/data
        einfo "Mounting persistent storage directly to /mnt/data..."

        # Try mounting with retry logic (filesystem may not be immediately recognized)
        local mount_attempts=3
        local mount_success=false
        local attempt=1

        while [ $attempt -le $mount_attempts ]; do
            if [ $attempt -gt 1 ]; then
                einfo "Mount attempt $attempt of $mount_attempts..."
                # Between retries, force another sync
                sync
                sleep 2
            fi

            if mount $DATA_PARTITION /mnt/data 2>/dev/null; then
                einfo "Storage mounted at /mnt/data (attempt $attempt)"
                mount_success=true
                break
            else
                if [ $attempt -lt $mount_attempts ]; then
                    ewarn "Mount attempt $attempt failed, retrying..."
                fi
            fi

            attempt=$((attempt + 1))
        done

        if [ "$mount_success" = "false" ]; then
            eerror "Failed to mount storage after $mount_attempts attempts"
            eerror "This can happen on first boot - filesystem needs kernel recognition"
            einfo "Possible solutions:"
            einfo "  1. Reboot - filesystem will mount successfully"
            einfo "  2. Wait a few seconds and run: rc-service storage-init restart"
            eend 1 "Failed to mount storage"
            return 1
        fi
    fi

    # CRITICAL: Check if mount is read-only and fix if needed
    if ! touch /mnt/data/.write-test 2>/dev/null; then
        ewarn "Storage mounted as read-only, attempting to remount as read-write..."

        # First, try to investigate WHY it's read-only
        einfo "Checking filesystem for errors..."
        e2fsck -p $DATA_PARTITION 2>&1 | head -5 || true

        # Attempt remount as read-write
        # If using Alpine's mount, we need to remount the source partition
        if [ -n "$ALPINE_MOUNT_POINT" ]; then
            einfo "Remounting source partition $ALPINE_MOUNT_POINT as read-write..."
            if mount -o remount,rw "$ALPINE_MOUNT_POINT"; then
                einfo "Successfully remounted $ALPINE_MOUNT_POINT as read-write"
            else
                eerror "Failed to remount $ALPINE_MOUNT_POINT as read-write"
                eend 1 "Cannot fix read-only filesystem"
                return 1
            fi
        else
            # Direct mount - remount /mnt/data
            if mount -o remount,rw /mnt/data; then
                einfo "Successfully remounted /mnt/data as read-write"
            else
                eerror "Failed to remount /mnt/data as read-write"
                eend 1 "Cannot fix read-only filesystem"
                return 1
            fi
        fi

        # Verify write capability
        if touch /mnt/data/.write-test 2>/dev/null; then
            rm -f /mnt/data/.write-test
            einfo "Write test successful"
        else
            eerror "Still cannot write to /mnt/data after remount"
            eend 1 "Filesystem remains read-only"
            return 1
        fi
    else
        rm -f /mnt/data/.write-test
        einfo "Storage is writable"
    fi

    # Create directories for k3s, APK cache, LBU config, usr/local/bin, and chrony
    mkdir -p /mnt/data/k3s /mnt/data/etc-persistent /mnt/data/var-lib-k3s /mnt/data/apk-cache /mnt/data/etc-lbu /mnt/data/usr-local-bin /mnt/data/var-lib-chrony

    # Set up APK local cache (Alpine's official mechanism)
    # This enables packages to be cached and restored across reboots
    if [ ! -L /etc/apk/cache ]; then
        einfo "Setting up APK local cache on persistent storage"
        mkdir -p /mnt/data/apk-cache
        ln -sf /mnt/data/apk-cache /etc/apk/cache
        eend $? "APK cache symlink"
    fi

    # Set up LBU config bind mount to persistent storage
    if ! mountpoint -q /etc/lbu 2>/dev/null; then
        einfo "Setting up LBU config on persistent storage"
        # Copy overlay LBU config to persistent storage if it doesn't exist
        if [ -d /etc/lbu ] && [ ! -f /mnt/data/etc-lbu/lbu.conf ]; then
            cp -a /etc/lbu/* /mnt/data/etc-lbu/ 2>/dev/null || true
        fi
        mount --bind /mnt/data/etc-lbu /etc/lbu
        eend $? "LBU config mount"
    fi

    # Set up /usr/local/bin bind mount to persistent storage
    if ! mountpoint -q /usr/local/bin 2>/dev/null; then
        einfo "Setting up /usr/local/bin on persistent storage"
        # Copy overlay files from /usr/local/bin to persistent storage if they don't exist
        if [ -d /usr/local/bin ]; then
            for file in /usr/local/bin/*; do
                if [ -f "$file" ] && [ ! -f "/mnt/data/usr-local-bin/$(basename "$file")" ]; then
                    cp -a "$file" /mnt/data/usr-local-bin/
                fi
            done
        fi
        mount --bind /mnt/data/usr-local-bin /usr/local/bin
        eend $? "/usr/local/bin mount"
    fi

    # Set up chrony drift file on persistent storage
    mkdir -p /mnt/data/var-lib-chrony
    if ! mountpoint -q /var/lib/chrony 2>/dev/null; then
        einfo "Setting up /var/lib/chrony on persistent storage"
        mkdir -p /var/lib/chrony
        # Copy any existing drift data
        if [ -f /var/lib/chrony/chrony.drift ] && [ ! -f /mnt/data/var-lib-chrony/chrony.drift ]; then
            cp -a /var/lib/chrony/chrony.drift /mnt/data/var-lib-chrony/
        fi
        mount --bind /mnt/data/var-lib-chrony /var/lib/chrony
        eend $? "/var/lib/chrony mount"
    fi

    # Set up rancher config bind mount to persistent storage
    # Persist entire /etc/rancher directory (not just k3s subdirectory)
    # This supports k3s, Rancher Desktop, and other Rancher products
    mkdir -p /mnt/data/etc-rancher /mnt/data/var-lib-rancher-k3s
    mkdir -p /etc/rancher /var/lib/rancher/k3s

    # Copy overlay rancher configs to persistent storage if they don't exist there
    # This preserves k3s config.yaml and any other files in /etc/rancher from the overlay
    if [ -d /etc/rancher ] && [ "$(ls -A /etc/rancher 2>/dev/null)" ] && [ ! -f /mnt/data/etc-rancher/.copied-from-overlay ]; then
        einfo "Copying overlay rancher configs to persistent storage"
        cp -a /etc/rancher/* /mnt/data/etc-rancher/ 2>/dev/null || true
        touch /mnt/data/etc-rancher/.copied-from-overlay
    fi

    if ! mountpoint -q /etc/rancher 2>/dev/null; then
        einfo "Setting up /etc/rancher on persistent storage"
        mount --bind /mnt/data/etc-rancher /etc/rancher
        eend $? "/etc/rancher mount"
    fi

    if ! mountpoint -q /var/lib/rancher/k3s 2>/dev/null; then
        einfo "Setting up /var/lib/rancher/k3s on persistent storage"
        mount --bind /mnt/data/var-lib-rancher-k3s /var/lib/rancher/k3s
        eend $? "/var/lib/rancher/k3s mount"
    fi

    # Mark storage initialization as complete
    echo "$(date): Storage initialization completed successfully" > /mnt/data/.storage-init-complete

    eend 0 "Persistent storage setup complete"
}

stop() {
    ebegin "Unmounting persistent storage"
    umount /mnt/data 2>/dev/null || true
    eend 0
}
