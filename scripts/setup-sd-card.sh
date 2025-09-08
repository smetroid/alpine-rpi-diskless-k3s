#!/bin/bash

# SD Card setup script for Alpine diskless k3s
# This script prepares the SD card with proper partitioning and boot files

# WARNING: This script will format the SD card. Make sure you specify the correct device!

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <sd_card_device> [config_file]"
    echo "Example: $0 /dev/sdb"
    echo "Example: $0 /dev/sdb my-cluster.yaml"
    echo "WARNING: This will FORMAT the entire SD card!"
    exit 1
fi

SD_DEVICE=$1
CONFIG_FILE="${CONFIG_FILE:-${2:-cluster-config.yaml}}"

# Load YAML parser if config file exists
if [ -f "$CONFIG_FILE" ]; then
    source "$LIB_DIR/yaml-parser.sh"
    export CONFIG_FILE
    echo "Using configuration: $CONFIG_FILE"
else
    echo "Warning: Configuration file '$CONFIG_FILE' not found, using defaults"
fi

# Verify device exists
if [ ! -b "$SD_DEVICE" ]; then
    echo "Error: $SD_DEVICE is not a valid block device"
    exit 1
fi

echo "WARNING: This will completely format $SD_DEVICE"
echo "All data on the device will be lost!"
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Operation cancelled"
    exit 1
fi

echo "Setting up SD card $SD_DEVICE for Alpine diskless k3s..."

# Unmount any mounted partitions
sudo umount ${SD_DEVICE}* 2>/dev/null || true

# Get boot partition size from config early (before using it)
if [ -f "$CONFIG_FILE" ]; then
    BOOT_PARTITION_SIZE=$(yaml_get "storage.boot_partition_size" || echo "512MiB")
else
    BOOT_PARTITION_SIZE="512MiB"
fi

# We'll handle partition size conversion per platform

# Check if we're on macOS and use appropriate partitioning tool
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Detected macOS - using diskutil for partitioning..."
    
    # Create partition layout: Boot partition + Data partition
    echo ""
    echo "📋 Creating partition layout:"
    echo "  Partition 1: Boot partition ($BOOT_PARTITION_SIZE, FAT32, bootable)"
    echo "  Partition 2: Data partition (remaining space, unformatted)"
    echo "  Note: Data partition will be formatted to ext4 during Alpine boot"
    echo ""
    
    # Unmount the disk first
    sudo diskutil unmountDisk $SD_DEVICE

    #echo "Formatting boot partition..."
    #diskutil eraseDisk free EMPTY ${SD_DEVICE}
    
    # Convert boot partition size from MiB to MB for diskutil
    BOOT_SIZE_MB=$(echo "$BOOT_PARTITION_SIZE" | sed 's/MiB//' | sed 's/MB//')
    BOOT_SIZE_DISKUTIL="${BOOT_SIZE_MB}MB"
    
    echo "Creating partitions with diskutil..."
    
    # Create both partitions: boot (FAT32) and data (ExFAT as placeholder)
    # We use ExFAT for the data partition as a placeholder - Alpine will reformat it to ext4
    if sudo diskutil partitionDisk $SD_DEVICE MBR \
        FAT32 ALPINE_BOOT $BOOT_SIZE_DISKUTIL \
        ExFAT DATA 0; then
        echo "✅ Boot and data partitions created with diskutil"
        
        # Verify both partitions exist
        echo "🔍 Verifying partition layout..."
        if diskutil list $SD_DEVICE | grep -q "2:" ; then
            echo "✅ Both partitions confirmed"
        else
            echo "⚠️  Warning: Second partition may not be visible"
        fi
        
        # Try to change the data partition to Linux type (0x83) using fdisk
        echo "🔧 Converting data partition to Linux type..."
        if command -v fdisk >/dev/null 2>&1; then
            printf 't\n2\n83\nw\n' | sudo fdisk $SD_DEVICE 2>/dev/null && {
                echo "✅ Data partition type set to Linux"
            } || {
                echo "⚠️  Could not change partition type (Alpine will handle formatting)"
            }
        else
            echo "ℹ️  fdisk not available - partition will be reformatted by Alpine"
        fi
    else
        echo "❌ Failed to create partitions"
        exit 1
    fi
    
    # Wait a moment for the system to recognize the partition
    sleep 2
    
    # Verify partition was created
    echo "Verifying partition layout..."
    diskutil list $SD_DEVICE

else
    # Create partition layout: Boot partition + Data partition
    echo ""
    echo "📋 Creating partition layout:"
    echo "  Partition 1: Boot partition ($BOOT_PARTITION_SIZE, FAT32, bootable)"
    echo "  Partition 2: Data partition (remaining space, unformatted)"
    echo "  Note: Data partition will be formatted to ext4 during Alpine boot"
    echo ""

    # Check available partitioning tools
    if command -v sfdisk >/dev/null 2>&1; then
        echo "Using sfdisk for partitioning..."
        
        # Convert boot partition size to sectors (assuming 512 byte sectors)
        BOOT_SIZE_SECTORS=$(echo "$BOOT_PARTITION_SIZE" | sed 's/MiB//' | awk '{print int($1 * 2048)}')
        
        # Create partition layout with sfdisk
        sudo sfdisk $SD_DEVICE << EOF
label: dos
label-id: 0x12345678
unit: sectors

${SD_DEVICE}1 : start=2048, size=$BOOT_SIZE_SECTORS, type=c, bootable
${SD_DEVICE}2 : start=$((2048 + BOOT_SIZE_SECTORS)), type=83
EOF

        if [ $? -eq 0 ]; then
            echo "✅ Boot and data partitions created with sfdisk"
        else
            echo "❌ sfdisk failed, trying manual approach..."
            if command -v cfdisk >/dev/null 2>&1; then
                echo ""
                echo "Please manually create partitions using cfdisk:"
                echo "1. Boot partition (FAT32): Start=1MiB, Size=$BOOT_PARTITION_SIZE, Type=c, Bootable=yes"
                echo "2. Data partition (Linux): Use remaining space, Type=83"
                read -p "Press Enter to open cfdisk..."
                sudo cfdisk $SD_DEVICE
            else
                echo "❌ No suitable partitioning tools found. Please install util-linux package."
                exit 1
            fi
        fi
    elif command -v parted >/dev/null 2>&1; then
        echo "Using parted for partitioning..."
        # Create partition table
        sudo parted -s $SD_DEVICE mklabel msdos
        
        # Create both boot and data partitions
        sudo parted -s $SD_DEVICE mkpart primary fat32 1MiB $BOOT_PARTITION_SIZE
        sudo parted -s $SD_DEVICE set 1 boot on
        sudo parted -s $SD_DEVICE mkpart primary ext4 $BOOT_PARTITION_SIZE 100%
        
        echo "✅ Boot and data partitions created with parted"
    else
        echo "❌ No suitable partitioning tools found."
        echo "Please install one of: util-linux (sfdisk/cfdisk), parted"
        echo ""
        echo "On Ubuntu/Debian: sudo apt install util-linux parted"
        echo "On RHEL/CentOS: sudo yum install util-linux parted"
        echo "On Alpine: apk add util-linux parted"
        exit 1
    fi
fi

# Wait for kernel to recognize partitions
sleep 2

# Set boot partition device path
if [[ "$OSTYPE" == "darwin"* ]]; then
    # On macOS, partition names include 's'
    BOOT_PARTITION="${SD_DEVICE}s1"
    echo "Boot partition: $BOOT_PARTITION"
else
    BOOT_PARTITION="${SD_DEVICE}1"
    echo "Boot partition: $BOOT_PARTITION"
    
    # On Linux, we need to manually format since partitionDisk handles it on macOS
    echo "Formatting boot partition as FAT32..."
    if sudo mkfs.vfat -F 32 -n ALPINE_BOOT ${SD_DEVICE}1; then
        echo "✅ Boot partition formatted"
    else
        echo "❌ Failed to format boot partition"
        exit 1
    fi
fi

echo "✅ Boot partition ready"
echo "📝 Data partition created (will be formatted by Alpine on first boot)"

# Mount boot partition only
MOUNT_BOOT=$(mktemp -d)

echo "Mounting boot partition..."

if [[ "$OSTYPE" == "darwin"* ]]; then
    # On macOS, check what's currently mounted and unmount any auto-mounted partitions
    echo "Checking current mount status..."
    mount | grep $SD_DEVICE || echo "No partitions currently mounted"
    
    echo "Unmounting any auto-mounted partitions..."
    sudo diskutil unmount ${SD_DEVICE}s1 2>/dev/null || echo "Boot partition not mounted"
    
    # Wait a moment for unmounting to complete
    sleep 2
    
    # On macOS, use mount with filesystem types
    echo "Mounting boot partition (FAT32)..."
    if ! sudo mount -t msdos $BOOT_PARTITION $MOUNT_BOOT; then
        echo "❌ Failed to mount boot partition"
        echo "Attempting to force unmount and retry..."
        sudo diskutil unmount force ${SD_DEVICE}s1 2>/dev/null || true
        sleep 1
        if ! sudo mount -t msdos $BOOT_PARTITION $MOUNT_BOOT; then
            echo "❌ Still failed to mount boot partition"
            echo "You may need to manually unmount: diskutil unmount ${SD_DEVICE}s1"
            exit 1
        fi
    fi
else
    # On Linux, mount boot partition
    echo "Mounting boot partition..."
    if ! sudo mount $BOOT_PARTITION $MOUNT_BOOT; then
        echo "❌ Failed to mount boot partition"
        exit 1
    fi
fi

echo "✅ Boot partition mounted successfully"

echo "Downloading Alpine Linux..."

# Get Alpine version and architecture from YAML config or use defaults
if [ -f "$CONFIG_FILE" ]; then
    ALPINE_VERSION=$(yaml_get "alpine.version" || echo "3.18.6")
    ALPINE_ARCH=$(yaml_get "alpine.architecture" || echo "aarch64")
    echo "Alpine version: $ALPINE_VERSION ($ALPINE_ARCH)"
else
    ALPINE_VERSION="3.18.6"
    ALPINE_ARCH="aarch64"
    echo "Using default Alpine version: $ALPINE_VERSION ($ALPINE_ARCH)"
fi

# Download Alpine Linux for Raspberry Pi
ALPINE_IMAGE="alpine-rpi-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
ALPINE_MAJOR_VERSION=$(echo "$ALPINE_VERSION" | cut -d'.' -f1-2)

# Store the original directory path
ORIGINAL_DIR="$PWD"

# Check if Alpine image exists and is valid
if [ -f "$ALPINE_IMAGE" ]; then
    echo "✅ Alpine image already exists: $ALPINE_IMAGE"
    
    # Verify it's a valid gzip archive
    if gzip -t "$ALPINE_IMAGE" 2>/dev/null; then
        echo "✅ Existing Alpine image is valid"
    else
        echo "⚠️  Existing Alpine image appears corrupted, re-downloading..."
        rm -f "$ALPINE_IMAGE"
    fi
fi

# Download if not exists or was corrupted
if [ ! -f "$ALPINE_IMAGE" ]; then
    echo "📥 Downloading $ALPINE_IMAGE..."
    ALPINE_URL="http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MAJOR_VERSION}/releases/${ALPINE_ARCH}/$ALPINE_IMAGE"
    echo "URL: $ALPINE_URL"
    
    if ! curl -L -f -o "$ALPINE_IMAGE" "$ALPINE_URL"; then
        echo "❌ Failed to download Alpine Linux $ALPINE_VERSION for $ALPINE_ARCH"
        echo "Please check if the version exists at: $ALPINE_URL"
        echo ""
        echo "Available Alpine versions can be found at:"
        echo "  http://dl-cdn.alpinelinux.org/alpine/"
        exit 1
    fi
    echo "✅ Downloaded $ALPINE_IMAGE successfully ($(du -h "$ALPINE_IMAGE" | cut -f1))"
fi

# Extract Alpine to boot partition
echo "Installing Alpine Linux to boot partition..."

# Verify the image file exists before extraction
if [ ! -f "$ORIGINAL_DIR/$ALPINE_IMAGE" ]; then
    echo "❌ Error: Alpine image file not found at $ORIGINAL_DIR/$ALPINE_IMAGE"
    exit 1
fi

cd $MOUNT_BOOT

# Extract with verbose output and error checking
if ! sudo tar -xzf "$ORIGINAL_DIR/$ALPINE_IMAGE"; then
    echo "❌ Error: Failed to extract Alpine Linux image"
    echo "Check if the downloaded file is valid:"
    echo "  file $ORIGINAL_DIR/$ALPINE_IMAGE"
    exit 1
fi

echo "✅ Alpine Linux extracted successfully"

# Verify extraction worked by checking for key files
if [ ! -f "boot/vmlinuz-rpi" ] && [ ! -f "vmlinuz-rpi" ]; then
    echo "⚠️  Warning: Expected Alpine boot files not found. Listing boot partition contents:"
    sudo ls -la $MOUNT_BOOT/
fi

# Configure boot
sudo tee cmdline.txt << 'EOF'
modules=loop,squashfs,sd-mod,usb-storage console=ttyS0,115200 console=tty1
EOF

sudo tee usercfg.txt << 'EOF'
# Enable cgroups for k3s
cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset swapaccount=1

# Enable UART for serial console access
enable_uart=1
EOF

echo "✅ Boot configuration files created"

echo "✅ Boot partition setup complete"
echo "✅ Data partition created (will be formatted during Alpine boot)"

echo "SD card setup complete!"
echo ""
echo "Next steps:"
echo "1. Copy the appropriate .apkovl.tar.gz file to the boot partition"
echo "2. Insert SD card into Raspberry Pi and boot"
echo "3. The system will automatically:"
echo "   - Format the data partition to ext4"
echo "   - Mount persistent storage"
echo "   - Install and configure k3s"
echo "   - Join the k3s cluster"
echo ""

# Unmount all partitions
echo "Unmounting partitions..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    # On macOS, unmount both boot and data partitions
    echo "Unmounting boot partition..."
    sudo diskutil umount $BOOT_PARTITION 2>/dev/null || true
    sudo diskutil umount $MOUNT_BOOT 2>/dev/null || true
    
    # Also unmount the data partition (which may have auto-mounted)
    echo "Unmounting data partition..."
    DATA_PARTITION="${SD_DEVICE}s2"
    sudo diskutil umount $DATA_PARTITION 2>/dev/null || true
    
    # Unmount any other auto-mounted partitions from this disk
    echo "Ensuring all partitions are unmounted..."
    sudo diskutil unmountDisk $SD_DEVICE 2>/dev/null || true
    
    # Wait longer for macOS to release everything
    echo "Waiting for macOS to release resources..."
    sleep 5
    
    # Change to a different directory to avoid keeping temp directory busy
    cd /tmp
    
    # Now try to remove the temp directory with better cleanup
    if ! rmdir "$MOUNT_BOOT" 2>/dev/null; then
        echo "🔍 Investigating what's using the temp directory..."
        sudo lsof +D "$MOUNT_BOOT" 2>/dev/null || echo "No processes found using directory"
        
        # Force unmount anything still mounted there
        sudo diskutil umount force "$MOUNT_BOOT" 2>/dev/null || true
        
        # Wait a bit more
        sleep 3
        
        # Try removal again
        if ! rmdir "$MOUNT_BOOT" 2>/dev/null; then
            echo "⚠️  Could not remove temp directory $MOUNT_BOOT"
            echo "   This is usually harmless - the directory will be cleaned up on reboot"
            echo "   You can manually remove it later with: rm -rf '$MOUNT_BOOT'"
        else
            echo "✅ Temp directory cleaned up successfully"
        fi
    else
        echo "✅ Temp directory cleaned up successfully"
    fi
else
    # Linux cleanup
    sudo umount $MOUNT_BOOT
    rmdir $MOUNT_BOOT
fi

echo ""
echo "🎉 SD card is ready for Alpine diskless k3s deployment!"
echo ""
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "📋 Final partition layout:"
    diskutil list $SD_DEVICE | grep -A 10 "${SD_DEVICE}:"
    echo ""
    echo "✅ Both partitions created and unmounted"
    echo "   - Boot partition: Ready for apkovl file"  
    echo "   - Data partition: Will be formatted to ext4 by Alpine"
fi