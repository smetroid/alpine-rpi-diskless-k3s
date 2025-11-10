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

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Alpine diskless k3s USB boot testing for Raspberry Pi 4 and Pi 5

OPTIONS:
    RAM_SIZE=<size>          RAM allocation (default: 512M)
    ALPINE_VERSION=<ver>     Alpine version (default: 3.22.1)
    ARCH=<arch>              Architecture: x86_64 or aarch64 (default: x86_64)
    HEADLESS=<bool>          Headless mode (default: false)
    USB_INTERFACE=<type>     USB interface: auto, scsi, usb, virtio, usb-storage (default: auto)

EXAMPLES:
    # Basic test with SCSI interface
    ./test/test-alpine-diskless-usb-boot.sh

    # Test with explicit USB interface
    USB_INTERFACE=usb ./test/test-alpine-diskless-usb-boot.sh

    # Headless mode for automation
    HEADLESS=true ./test/test-alpine-diskless-usb-boot.sh

    # ARM64 testing
    ARCH=aarch64 ./test/test-alpine-diskless-usb-boot.sh

EOF
    exit 0
}

# Check for help flag
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

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

    log "Determining QEMU USB interface configuration..." >&2

    if [ "$interface" != "auto" ]; then
        log "Using manual interface: $interface" >&2
        echo "$interface"
        return 0
    fi

    # Auto-detection: try different interfaces in order of preference
    # Preference order based on common USB storage behavior
    # 1. SCSI - most USB storage appears as SCSI devices
    # 2. USB - direct USB storage emulation
    # 3. virtio - fast paravirtualized storage

    log "Auto-detecting best USB interface configuration..." >&2
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

download_alpine() {
    local version="$1"
    local arch="$2"
    local vm_dir="$3"

    local alpine_iso
    local download_url

    if [ "$arch" = "aarch64" ]; then
        alpine_iso="alpine-rpi-${version}-aarch64.tar.gz"
        download_url="https://dl-cdn.alpinelinux.org/alpine/v$(echo "$version" | cut -d. -f1,2)/releases/aarch64/${alpine_iso}"
    else
        alpine_iso="alpine-virt-${version}-x86_64.iso"
        download_url="https://dl-cdn.alpinelinux.org/alpine/v$(echo "$version" | cut -d. -f1,2)/releases/x86_64/${alpine_iso}"
    fi

    if [ -f "$vm_dir/$alpine_iso" ]; then
        log "Alpine ISO already exists: $alpine_iso" >&2
    else
        log "Downloading Alpine Linux $arch..." >&2
        (cd "$vm_dir" && curl -L "$download_url" -o "$alpine_iso") || error "Failed to download Alpine"
        success "Alpine downloaded: $alpine_iso" >&2
    fi

    echo "$vm_dir/$alpine_iso"
}

find_apkovl() {
    local project_dir="$1"

    log "Searching for apkovl files..." >&2

    # Look for any k3s-*.apkovl.tar.gz in builds/
    for apkovl in "$project_dir"/builds/k3s-*.apkovl.tar.gz; do
        if [ -f "$apkovl" ]; then
            log "Found: $(basename "$apkovl")" >&2
            echo "$apkovl"
            return 0
        fi
    done

    error "No apkovl files found. Run: ./build-from-yaml.sh k3s.yaml"
}

create_usb_device_service() {
    local apkovl_dir="$1"

    log "Creating USB device setup service..."

    cat > "${apkovl_dir}/etc/init.d/usb-device-setup" << 'EOF'
#!/sbin/openrc-run

description="USB device setup for Pi 4/5 boot testing"
name="usb device setup"

depend() {
    need localmount
    before system-bootstrap
    provide usb-device-setup
}

start() {
    ebegin "Setting up USB boot device detection"

    # Install required tools
    apk add e2fsprogs >/dev/null 2>&1 || true

    # Log helper
    _log() { logger -t "usb-device-setup" "$*" 2>/dev/null || echo "$*"; }

    _log "=== USB BOOT DEVICE DETECTION ==="

    # Detect USB storage device
    USB_DEV=""
    for dev in /dev/sda /dev/sdb /dev/vda; do
        if [ -b "$dev" ]; then
            USB_DEV="$dev"
            _log "Found storage device: $USB_DEV"
            break
        fi
    done

    if [ -z "$USB_DEV" ]; then
        eerror "No USB storage device found"
        eend 1
        return 1
    fi

    # Check if already initialized
    mkdir -p /tmp/usb_check
    INITIALIZED=false

    if mount -t ext4 "${USB_DEV}2" /tmp/usb_check 2>/dev/null; then
        if [ -f "/tmp/usb_check/.usb-initialized" ]; then
            INITIALIZED=true
            _log "USB device already initialized"
        fi
        umount /tmp/usb_check
    fi

    if [ "$INITIALIZED" = "false" ]; then
        _log "First boot - initializing USB device..."

        # Format data partition
        _log "Formatting ${USB_DEV}2 as ext4..."
        mkfs.ext4 -F "${USB_DEV}2" >/dev/null 2>&1 || true

        # Create initialization marker
        if mount -t ext4 "${USB_DEV}2" /tmp/usb_check 2>/dev/null; then
            echo "$(date): USB device initialized" > /tmp/usb_check/.usb-initialized
            umount /tmp/usb_check
            _log "Initialization complete"
        fi
    fi

    rmdir /tmp/usb_check 2>/dev/null || true

    _log "=== USB DEVICE SETUP COMPLETE ==="
    _log "USB storage ready at $USB_DEV"

    eend 0
}
EOF

    chmod +x "${apkovl_dir}/etc/init.d/usb-device-setup"
    mkdir -p "${apkovl_dir}/etc/runlevels/default"
    ln -sf /etc/init.d/usb-device-setup "${apkovl_dir}/etc/runlevels/default/usb-device-setup"

    success "USB device setup service created"
}

create_dynamic_network_service() {
    local apkovl_dir="$1"

    log "Creating dynamic network service for QEMU testing..." >&2

    # Modify interfaces file for DHCP
    cat > "${apkovl_dir}/etc/network/interfaces" << 'EOF'
auto lo
iface lo inet loopback
EOF

    # Disable static networking service
    rm -f "${apkovl_dir}/etc/runlevels/default/networking"

    # Create dynamic network OpenRC service
    cat > "${apkovl_dir}/etc/init.d/dynamic-network" << 'EOF'
#!/sbin/openrc-run

description="Dynamic network interface configuration service"
name="dynamic network"

depend() {
    need localmount
    after localmount
    before system-bootstrap k3s-bootstrap
    provide network-config
}

start() {
    ebegin "Configuring network interfaces dynamically"

    # Build network interfaces file dynamically
    cat > /etc/network/interfaces << 'NETEOF'
auto lo
iface lo inet loopback

NETEOF

    # Scan for ethernet interfaces and add DHCP config
    local found_interfaces=0
    for dev in /sys/class/net/*; do
        [ -e "$dev" ] || continue
        INTERFACE=""
        . "$dev"/uevent 2>/dev/null || continue

        case ${INTERFACE%%[0-9]*} in
            lo) ;;
            eth|enp|ens)
                einfo "Found ethernet interface: $INTERFACE"
                cat >> /etc/network/interfaces << NETEOF
auto $INTERFACE
iface $INTERFACE inet dhcp

NETEOF
                found_interfaces=$((found_interfaces + 1))
                ;;
            *)
                # Try to configure any other interface as DHCP too
                einfo "Found other interface: $INTERFACE"
                cat >> /etc/network/interfaces << NETEOF
auto $INTERFACE
iface $INTERFACE inet dhcp

NETEOF
                found_interfaces=$((found_interfaces + 1))
                ;;
        esac
    done

    if [ $found_interfaces -eq 0 ]; then
        ewarn "No network interfaces found"
        eend 1 "No network interfaces detected"
        return 1
    fi

    einfo "Network interfaces file configured with $found_interfaces interfaces"

    # Start networking manually
    einfo "Starting network interfaces"
    if ifup -a; then
        eend 0 "Network interfaces brought up successfully"
    else
        eend 1 "Some network interfaces failed to start"
        return 1
    fi
}

stop() {
    ebegin "Stopping dynamic network"
    ifdown -a 2>/dev/null || true
    eend 0
}
EOF

    chmod +x "${apkovl_dir}/etc/init.d/dynamic-network"
    mkdir -p "${apkovl_dir}/etc/runlevels/default"
    ln -sf /etc/init.d/dynamic-network "${apkovl_dir}/etc/runlevels/default/dynamic-network"

    success "Dynamic network service created" >&2
}

prepare_overlay() {
    local apkovl_path="$1"
    local vm_dir="$2"

    log "Preparing overlay from: $(basename "$apkovl_path")" >&2

    local overlay_dir="$vm_dir/overlay"
    local temp_overlay="$vm_dir/temp-overlay"

    rm -rf "$overlay_dir" "$temp_overlay"
    mkdir -p "$overlay_dir" "$temp_overlay"

    # Extract original overlay
    (cd "$temp_overlay" && tar -xzf "$apkovl_path") || error "Failed to extract apkovl"

    # Add USB device setup service
    create_usb_device_service "$temp_overlay" >&2

    # Add dynamic network service for QEMU testing
    create_dynamic_network_service "$temp_overlay"

    # Repack overlay
    (cd "$temp_overlay" && tar -czf "$overlay_dir/usb-boot.apkovl.tar.gz" etc usr root var 2>/dev/null) || error "Failed to repack overlay"

    rm -rf "$temp_overlay"

    success "Overlay prepared: $overlay_dir/usb-boot.apkovl.tar.gz" >&2
    echo "$overlay_dir"
}

build_qemu_command() {
    local alpine_iso="$1"
    local usb_disk="$2"
    local usb_interface="$3"
    local overlay_dir="$4"

    log "Building QEMU command..." >&2

    # Determine QEMU binary
    if [ "$ARCH" = "aarch64" ]; then
        QEMU_BIN="qemu-system-aarch64"
        QEMU_MACHINE=("-machine" "virt" "-cpu" "cortex-a72")
    else
        QEMU_BIN="qemu-system-x86_64"
        QEMU_MACHINE=("-machine" "q35")
    fi

    # Build base options
    QEMU_CMD=(
        "$QEMU_BIN"
        "-m" "$RAM_SIZE"
        "-cdrom" "$alpine_iso"
        "-boot" "d"
        "${QEMU_MACHINE[@]}"
    )

    # Add USB drive with selected interface
    read -ra USB_DRIVE_OPTS <<< "$(build_qemu_drive_opts "$usb_disk" "$usb_interface")"
    QEMU_CMD+=("${USB_DRIVE_OPTS[@]}")

    # Add overlay
    QEMU_CMD+=("-drive" "file=fat:rw:$overlay_dir,format=raw")

    # Add network (simple user-mode for single node)
    QEMU_CMD+=(
        "-netdev" "user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::6443-:6443,dns=1.1.1.1"
        "-device" "virtio-net-pci,netdev=net0"
    )

    # Add headless options
    if [ "$HEADLESS" = "true" ]; then
        QEMU_CMD+=("-nographic" "-serial" "mon:stdio")
    fi

    echo "${QEMU_CMD[@]}"
}

show_test_info() {
    local usb_interface="$1"

    echo ""
    echo "🚀 USB Boot Test Configuration:"
    echo "   Architecture: $ARCH"
    echo "   RAM: $RAM_SIZE"
    echo "   USB Interface: $usb_interface"
    echo "   Headless: $HEADLESS"
    echo ""

    show_expected_devices "$usb_interface"

    echo "📝 Test Access:"
    echo "   SSH: ssh root@localhost -p 2222"
    echo "   k3s API: localhost:6443"
    echo ""
    echo "🎯 Success Criteria:"
    echo "   1. Alpine boots from USB"
    echo "   2. USB device detected and initialized"
    echo "   3. system-bootstrap completes"
    echo "   4. k3s-bootstrap completes"
    echo "   5. k3s node reaches Ready state"
    echo ""
}

run_qemu_test() {
    local qemu_cmd="$1"

    log "Starting QEMU USB boot test..."
    log "Command: $qemu_cmd"

    echo ""
    echo "🚀 Launching QEMU..."
    echo "   Press Ctrl-A then X to exit QEMU"
    echo ""

    # Execute
    eval "$qemu_cmd"

    log "QEMU test completed"
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

# Download Alpine
ALPINE_ISO=$(download_alpine "$ALPINE_VERSION" "$ARCH" "$VM_DIR")

# Find and prepare apkovl
APKOVL=$(find_apkovl "$PROJECT_DIR")
OVERLAY_DIR=$(prepare_overlay "$APKOVL" "$VM_DIR")

# Determine USB interface
USB_IF=$(determine_qemu_usb_interface "$USB_INTERFACE")

# Show test configuration
show_test_info "$USB_IF"

# Build QEMU command
QEMU_CMD=$(build_qemu_command "$ALPINE_ISO" "$USB_DISK" "$USB_IF" "$OVERLAY_DIR")

# Run test
run_qemu_test "$QEMU_CMD"

echo ""
echo "✅ USB Boot Test Complete"
echo ""
echo "💡 Validation Steps:"
echo ""
echo "1. Check USB device detection:"
echo "   # ls -la /dev/sd*"
echo "   # dmesg | grep -i usb"
echo ""
echo "2. Verify services:"
echo "   # rc-status"
echo "   # rc-service usb-device-setup status"
echo "   # rc-service k3s-bootstrap status"
echo ""
echo "3. Check k3s status:"
echo "   # kubectl get nodes"
echo "   # kubectl get pods -A"
echo ""
echo "4. Test different USB interfaces:"
echo "   USB_INTERFACE=scsi ./test/test-alpine-diskless-usb-boot.sh"
echo "   USB_INTERFACE=usb ./test/test-alpine-diskless-usb-boot.sh"
echo "   USB_INTERFACE=virtio ./test/test-alpine-diskless-usb-boot.sh"
echo ""
