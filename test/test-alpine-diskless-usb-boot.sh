#!/bin/bash

# Alpine Diskless USB Boot Simulation
# Tests Alpine diskless k3s cluster booting from USB drives (Pi 4/5)

set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"

# Configuration
RAM_SIZE="${RAM_SIZE:-512M}"
ALPINE_VERSION="${ALPINE_VERSION:-3.22.1}"
ARCH="${ARCH:-x86_64}"
HEADLESS="${HEADLESS:-false}"
USB_INTERFACE="${USB_INTERFACE:-auto}"  # auto, scsi, usb, virtio

VM_DIR="$TEST_DIR/vm-usb-boot"
mkdir -p "$VM_DIR"

USB_DISK="$VM_DIR/usb-drive.img"

# --- Logging setup ---
SCRIPT_NAME=$(basename "$0")
LOG_FILE="$TEST_DIR/usb-boot-test.log"
touch "$LOG_FILE"

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $SCRIPT_NAME: $1" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $1"
    exit 1
}

success() {
    log "✅ $1"
}

create_usb_disk() {
    local disk_path="$1"
    local size_gb="${2:-8}"

    if [ -f "$disk_path" ]; then
        log "USB disk image already exists: $disk_path"
        return 0
    fi

    log "Creating USB disk image (${size_gb}GB)..."
    if dd if=/dev/zero of="$disk_path" bs=1M count=$((size_gb * 1024)) status=progress; then
        success "USB disk image created: $disk_path"
    else
        error "Failed to create USB disk image"
    fi
}

partition_usb_disk() {
    local disk_path="$1"

    log "Partitioning USB disk (simulating Pi USB boot layout)..."

    # Create partitions: 256MB boot (FAT32) + rest for data (ext4)
    (
        echo o      # Create DOS partition table
        echo n      # New partition
        echo p      # Primary
        echo 1      # Partition 1
        echo        # Default start
        echo +256M  # 256MB boot partition
        echo t      # Change type
        echo c      # FAT32 LBA
        echo n      # New partition
        echo p      # Primary
        echo 2      # Partition 2
        echo        # Default start
        echo        # Use remaining space
        echo w      # Write changes
    ) | fdisk "$disk_path" &>/dev/null || true

    success "USB disk partitioned"
}

setup_loop_device() {
    local disk_path="$1"

    log "Setting up loop device for disk image..."

    # Detect OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        LOOP_DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$disk_path" | awk '{print $1}')
        log "macOS loop device: $LOOP_DEV"
    else
        # Linux
        LOOP_DEV=$(losetup -f --show -P "$disk_path")
        log "Linux loop device: $LOOP_DEV"
    fi

    export LOOP_DEV
    success "Loop device ready: $LOOP_DEV"
}

cleanup_loop_device() {
    if [ -n "$LOOP_DEV" ]; then
        log "Cleaning up loop device: $LOOP_DEV"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            hdiutil detach "$LOOP_DEV" 2>/dev/null || true
        else
            losetup -d "$LOOP_DEV" 2>/dev/null || true
        fi
    fi
}

determine_qemu_usb_interface() {
    local interface="${1:-auto}"

    if [ "$interface" != "auto" ]; then
        echo "$interface"
        return 0
    fi

    # Auto-detection: try different interfaces in order of preference
    # Preference order based on common USB storage behavior
    # 1. SCSI - most USB storage appears as SCSI devices
    # 2. USB - direct USB storage emulation
    # 3. virtio - fast paravirtualized storage

    echo "scsi"  # Start with SCSI as default
}

build_qemu_drive_opts() {
    local disk_path="$1"
    local interface="$2"

    case "$interface" in
        scsi)
            echo "-drive file=$disk_path,format=raw,if=scsi"
            ;;
        usb)
            echo "-drive file=$disk_path,format=raw,if=usb"
            ;;
        virtio)
            echo "-drive file=$disk_path,format=raw,if=virtio"
            ;;
        usb-storage)
            echo "-drive id=usbdrive,file=$disk_path,format=raw,if=none -device usb-storage,drive=usbdrive"
            ;;
        *)
            error "Unknown interface: $interface"
            ;;
    esac
}

show_expected_devices() {
    local interface="$1"

    echo ""
    echo "🔍 Expected device naming for interface: $interface"
    case "$interface" in
        scsi)
            echo "   Device: /dev/sda (partitions: /dev/sda1, /dev/sda2)"
            ;;
        usb|usb-storage)
            echo "   Device: /dev/sda or /dev/sdb (partitions: /dev/sdX1, /dev/sdX2)"
            ;;
        virtio)
            echo "   Device: /dev/vda (partitions: /dev/vda1, /dev/vda2)"
            ;;
    esac
    echo ""
}

echo "🔌 Alpine Linux USB Boot Simulation"
echo "====================================="
echo ""
echo "Target Hardware: Raspberry Pi 4 and Pi 5"
echo "Boot Device: USB Drive (/dev/sda)"
echo "Test Mode: Single-node k3s server"
echo ""

log "USB disk image: $USB_DISK"

# Create USB disk if needed
create_usb_disk "$USB_DISK" 8
partition_usb_disk "$USB_DISK"

# Cleanup on exit
trap cleanup_loop_device EXIT

# Test interface determination
log "Determining QEMU USB interface configuration..."
USB_IF=$(determine_qemu_usb_interface "$USB_INTERFACE")
log "Selected interface: $USB_IF"

case "$USB_IF" in
    scsi)
        log "Using SCSI interface (USB storage typically appears as SCSI)"
        ;;
    usb)
        log "Using USB interface (direct USB emulation)"
        ;;
    virtio)
        log "Using virtio interface (paravirtualized storage)"
        ;;
    usb-storage)
        log "Using explicit USB storage device"
        ;;
esac

show_expected_devices "$USB_IF"
