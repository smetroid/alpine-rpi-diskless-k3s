#!/bin/bash

# True Alpine Diskless Boot Simulation
# Simulates exactly how Alpine diskless works on Raspberry Pi
#
# Usage: ./test-alpine-diskless-boot.sh [config-file]
#   config-file: YAML configuration file (default: qemu.yaml)

set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"

# Determine config file and build directory
CONFIG_FILE="${1:-qemu.yaml}"
CONFIG_BASENAME="$(basename "$CONFIG_FILE")"

# Determine build directory based on config basename
case "$CONFIG_BASENAME" in
    qemu.yaml|*-test.yaml|*-qemu.yaml)
        BUILD_DIR="builds-qemu"
        ;;
    *)
        BUILD_DIR="builds"
        ;;
esac

# Get first node name from config (for default testing)
NODE_NAME="${TEST_NODE:-qemu-test-1}"
APKVOL="$PROJECT_DIR/$BUILD_DIR/${NODE_NAME}.apkovl.tar.gz"

echo "Using configuration: $CONFIG_FILE"
echo "Build directory: $BUILD_DIR"
echo "Overlay archive: $APKVOL"
echo ""

# --- Logging setup ---
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/setup.log"

# Create log directory if it doesn't exist
touch "$LOG_FILE"

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $SCRIPT_NAME: $1" | tee -a "$LOG_FILE"
}

echo "🍃 Alpine Linux Diskless Boot Simulation"
echo "=========================================="
echo ""
echo "This test simulates the EXACT boot process of a Raspberry Pi:"
echo "  1. 🥧 Pi loads Alpine kernel from SD card boot partition"
echo "  2. 🔄 initramfs starts and mounts root as tmpfs (RAM)"  
echo "  3. 📦 Alpine automatically finds and loads .apkovl overlay"
echo "  4. 🚀 OpenRC starts services including local.d scripts"
echo "  5. ⚙️  Your k3s_bootstrap runs automatically via local.d"
echo ""

# Configuration
# 4GB RAM needed for k3s with all components (API server, metrics-server, traefik, coredns)
# 2GB is minimum but causes timeout issues under load
RAM_SIZE="8096M"
ALPINE_VERSION="3.22.1"
VM_DIR="$TEST_DIR/vm-diskless"
mkdir -p "$VM_DIR" 
cd "$VM_DIR"
DATA_DISK=data.qcow2
OVERLAY_DIR=$TEST_DIR/overlaydir
mkdir -p "$OVERLAY_DIR"

# Create QEMU device setup service for testing
create_qemu_device_service() {
    local apkovl_dir="$1"

    # Create qemu-device-setup OpenRC service
    # This service simulates Raspberry Pi SD card devices in QEMU environment
    # It creates /dev/mmcblk0* device nodes that point to the actual storage device
    cat > "${apkovl_dir}/etc/init.d/qemu-device-setup" << 'EOF'
#!/sbin/openrc-run

description="QEMU device simulation for testing"
name="qemu device setup"

depend() {
    need localmount
    before storage-init
    provide qemu-device-setup
}

start() {
    ebegin "Setting up QEMU device simulation"

    # Detect storage device (QEMU provides /dev/sda or /dev/vda)
    STORAGE_DEV=""
    if [ -b /dev/sda ]; then
        STORAGE_DEV="/dev/sda"
    elif [ -b /dev/vda ]; then
        STORAGE_DEV="/dev/vda"
    fi

    if [ -z "$STORAGE_DEV" ]; then
        einfo "No QEMU storage device found, assuming real Raspberry Pi hardware"
        eend 0
        return 0
    fi

    einfo "QEMU detected, using $STORAGE_DEV for SD card simulation"

    # Verify partitions exist (from pre-partitioned template)
    if [ ! -b "${STORAGE_DEV}1" ] || [ ! -b "${STORAGE_DEV}2" ]; then
        eerror "Partitions not found on $STORAGE_DEV - data-partitioned-template.qcow2 required"
        eend 1
        return 1
    fi

    # Create /dev/mmcblk0* device nodes to simulate Raspberry Pi SD card
    # This allows storage-init to use standard RPi paths (/dev/mmcblk0p2)
    einfo "Creating Raspberry Pi device nodes..."
    mknod /dev/mmcblk0 b $(stat -c "%t %T" "$STORAGE_DEV") 2>/dev/null || true
    mknod /dev/mmcblk0p1 b $(stat -c "%t %T" "${STORAGE_DEV}1") 2>/dev/null || true
    mknod /dev/mmcblk0p2 b $(stat -c "%t %T" "${STORAGE_DEV}2") 2>/dev/null || true

    eend 0 "QEMU device setup complete"
}
EOF
    chmod +x "${apkovl_dir}/etc/init.d/qemu-device-setup"

    # Enable the service in default runlevel
    mkdir -p "${apkovl_dir}/etc/runlevels/default"
    ln -sf /etc/init.d/qemu-device-setup "${apkovl_dir}/etc/runlevels/default/qemu-device-setup"
}

# Network mode selection
NETWORK_MODE="${NETWORK_MODE:-dhcp}"  # dhcp or bridge
echo "🌐 Network mode: $NETWORK_MODE"

# Check for overlay files first
if [ ! -f "$APKVOL" ]; then
    echo "❌ No overlay found: $APKVOL"
    echo ""
    echo "💡 Please run first:"
    if [ "$BUILD_DIR" = "builds-qemu" ]; then
        echo "   make build-test"
        echo "   or: ./scripts/build-from-yaml.sh qemu.yaml"
    else
        echo "   make build CONFIG=$CONFIG_FILE"
        echo "   or: ./scripts/build-from-yaml.sh $CONFIG_FILE"
    fi
    echo ""
    echo "This will generate the ${NODE_NAME}-apkovl overlay that contains:"
    echo "  • /usr/local/bin/k3s_bootstrap script"
    echo "  • /etc/local.d/10-k3s-bootstrap.start service"
    echo "  • /etc/runlevels/default/local symlink"
    echo "  • Network and k3s configuration"
    exit 1
fi

echo "✓ Found overlay archive: $APKVOL"
echo ""

# Download standard Alpine
ALPINE_ISO="alpine-virt-${ALPINE_VERSION}-x86_64.iso"
if [ ! -f "$ALPINE_ISO" ]; then
    echo "📥 Downloading Alpine Linux..."
    curl -L "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/${ALPINE_ISO}" -o "$ALPINE_ISO"
fi

# Extract kernel and initramfs for direct boot with custom kernel parameters
KERNEL_FILE="vmlinuz-virt"
INITRD_FILE="initramfs-virt"

if [ ! -f "$KERNEL_FILE" ] || [ ! -f "$INITRD_FILE" ]; then
    log "Extracting kernel and initramfs from ISO for direct boot..."

    # Try multiple extraction methods
    EXTRACTION_SUCCESS=false

    # Method 1: Try bsdtar (built into macOS, works on Linux too)
    if command -v bsdtar >/dev/null 2>&1; then
        log "Using bsdtar to extract kernel and initramfs..."
        if bsdtar -xf "$ALPINE_ISO" boot/vmlinuz-virt boot/initramfs-virt 2>/dev/null; then
            if [ -f "boot/vmlinuz-virt" ] && [ -f "boot/initramfs-virt" ]; then
                mv boot/vmlinuz-virt "$KERNEL_FILE"
                mv boot/initramfs-virt "$INITRD_FILE"
                rmdir boot 2>/dev/null || true
                EXTRACTION_SUCCESS=true
                log "Successfully extracted using bsdtar"
            fi
        fi
    fi

    # Method 2: Try 7z if available (works cross-platform)
    if [ "$EXTRACTION_SUCCESS" = "false" ] && command -v 7z >/dev/null 2>&1; then
        log "Using 7z to extract kernel and initramfs..."
        if 7z e "$ALPINE_ISO" boot/vmlinuz-virt boot/initramfs-virt -o. >/dev/null 2>&1; then
            if [ -f "vmlinuz-virt" ] && [ -f "initramfs-virt" ]; then
                EXTRACTION_SUCCESS=true
                log "Successfully extracted using 7z"
            fi
        fi
    fi

    # Method 3: Try direct mount on Linux
    if [ "$EXTRACTION_SUCCESS" = "false" ] && [[ "$OSTYPE" != "darwin"* ]]; then
        log "Trying direct mount method..."
        ISO_MOUNT=$(mktemp -d)
        if sudo mount -o loop,ro "$ALPINE_ISO" "$ISO_MOUNT" 2>/dev/null; then
            if [ -f "$ISO_MOUNT/boot/vmlinuz-virt" ]; then
                cp "$ISO_MOUNT/boot/vmlinuz-virt" "$KERNEL_FILE"
                cp "$ISO_MOUNT/boot/initramfs-virt" "$INITRD_FILE"
                EXTRACTION_SUCCESS=true
                log "Successfully extracted using mount"
            fi
            sudo umount "$ISO_MOUNT"
        fi
        rmdir "$ISO_MOUNT"
    fi

    # Check if extraction succeeded
    if [ "$EXTRACTION_SUCCESS" = "false" ]; then
        log "ERROR: Could not extract kernel and initramfs from ISO"
        log ""
        log "Extraction tools tried: bsdtar, 7z, mount"
        log "Please ensure one of these is available"
        exit 1
    fi

    log "Kernel and initramfs ready for direct boot"
fi

# --- Step 2: Create persistent data disk if missing ---
DATA_DISK_TEMPLATE="data-partitioned-template.qcow2"

# Check if we have a pre-partitioned template
if [ ! -f "$DATA_DISK" ]; then
  if [ -f "$DATA_DISK_TEMPLATE" ]; then
    log "Using pre-partitioned template: $DATA_DISK_TEMPLATE"
    qemu-img convert -f qcow2 -O qcow2 "$DATA_DISK_TEMPLATE" "$DATA_DISK"
    log "Copied template to $DATA_DISK"
  else
    log "Creating $DATA_DISK (4G)..."
    if qemu-img create -f qcow2 "$DATA_DISK" 4G; then
      log "Successfully created data disk"
      log "NOTE: First boot will partition this disk"
      log "After successful first boot, save as template:"
      log "  qemu-img convert -f qcow2 -O qcow2 $DATA_DISK $DATA_DISK_TEMPLATE"
    else
      log "ERROR: Failed to create data disk"
      exit 1
    fi
  fi
fi

# Prepare overlay - extract and add QEMU-specific testing services
# Note: For qemu.yaml configs, the overlay already has correct network configuration
log "Preparing overlay for testing..."
TEMP_OVERLAY="$VM_DIR/temp-overlay"
rm -rf "$TEMP_OVERLAY"
mkdir -p "$TEMP_OVERLAY"

# Extract original overlay
cd "$TEMP_OVERLAY"
tar -xzf "$APKVOL"

# Add QEMU device setup service for testing (storage simulation)
log "Adding QEMU device setup service for testing..."
create_qemu_device_service "$TEMP_OVERLAY"

# Debug: Check what files exist before repacking
log "Files in overlay before repacking:"
find . -name "interfaces" -exec ls -la {} \;
ls -la etc/network/ || log "etc/network directory not found"
ls -la root/.ssh/authorized_keys 2>/dev/null || log "authorized_keys not found"

# Repack overlay (include root directory!)
# Use node name from config for the overlay filename
TEST_OVERLAY_NAME="${NODE_NAME}-test.apkovl.tar.gz"
tar -czf "$OVERLAY_DIR/$TEST_OVERLAY_NAME" etc usr root var sbin 2>/dev/null
cd "$VM_DIR"

# Debug: Check overlay contents
log "Checking overlay contents:"
tar -tzf "$OVERLAY_DIR/$TEST_OVERLAY_NAME" | grep interfaces || log "No interfaces file in overlay"
tar -tzf "$OVERLAY_DIR/$TEST_OVERLAY_NAME" | grep authorized_keys || log "No authorized_keys in overlay"
tar -tzf "$OVERLAY_DIR/$TEST_OVERLAY_NAME" | grep mkfs.ext4 || log "No mkfs.ext4 in overlay"

rm -rf "$TEMP_OVERLAY"

if [ -f "$OVERLAY_DIR/$TEST_OVERLAY_NAME" ]; then
    log "Successfully prepared overlay for $NETWORK_MODE mode"
else
    log "ERROR: Failed to prepare overlay"
    exit 1
fi

echo ""
echo "🚀 Booting Alpine Linux in diskless mode..."
echo "   This simulates your Raspberry Pi SD card boot process"
echo ""

if [ "$NETWORK_MODE" = "dhcp" ]; then
    echo "📝 DHCP Mode - Network will start automatically:"
    echo "   • Test connectivity: ping 8.8.8.8"
    echo "   • SSH: ssh root@localhost -p 2222"
    echo "   • k3s API: localhost:6443"
    echo "   • Web services: localhost:8080"
    echo ""

    # Kernel command line matching RPi boot configuration with cgroups enabled
    # Serial console only for -nographic mode (no graphical console)
    KERNEL_CMDLINE="modules=loop,squashfs,sd-mod,usb-storage quiet console=ttyS0,115200 cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset swapaccount=1"

    echo "🔧 Booting with kernel parameters (matches RPi config):"
    echo "   $KERNEL_CMDLINE"
    echo ""

    qemu-system-x86_64 \
      -m $RAM_SIZE \
      -kernel "$KERNEL_FILE" \
      -initrd "$INITRD_FILE" \
      -append "$KERNEL_CMDLINE" \
      -cdrom "$ALPINE_ISO" \
      -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::6443-:6443,hostfwd=tcp::8080-:8080,dns=8.8.8.8 \
      -device virtio-net-pci,netdev=net0 \
      -drive file="$DATA_DISK",format=qcow2 \
      -drive file=fat:rw:"$OVERLAY_DIR",format=raw \
      -display none \
      -serial mon:stdio

elif [ "$NETWORK_MODE" = "bridge" ]; then
    echo "📝 Bridge Mode - Creates realistic network environment:"
    echo "   • VM will have static IP: 192.168.1.21"
    echo "   • Requires bridge setup on host"
    echo ""
    echo "⚠️  Bridge mode requires:"
    echo "   sudo ip link add br0 type bridge"
    echo "   sudo ip addr add 192.168.1.254/24 dev br0"
    echo "   sudo ip link set br0 up"
    echo ""

    # Kernel command line matching RPi boot configuration with cgroups enabled
    # Serial console only for terminal mode
    KERNEL_CMDLINE="modules loop,squashfs,sd-mod,usb-storage quiet console=ttyS0,115200 cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset swapaccount=1"

    echo "🔧 Booting with kernel parameters (matches RPi config):"
    echo "   $KERNEL_CMDLINE"
    echo ""

    qemu-system-x86_64 \
      -m $RAM_SIZE \
      -kernel "$KERNEL_FILE" \
      -initrd "$INITRD_FILE" \
      -append "$KERNEL_CMDLINE" \
      -cdrom "$ALPINE_ISO" \
      -drive file="$DATA_DISK",format=qcow2 \
      -drive file=fat:rw:"$OVERLAY_DIR",format=raw \
      -netdev bridge,id=net0,br=br0 \
      -device virtio-net-pci,netdev=net0 \
      -serial mon:stdio
fi
  #-nographic
  #-chardev socket,id=mon0,host=localhost,port=4444,server=on,wait=off \
  #-chardev socket,id=cons0,host=localhost,port=5555,server=on,wait=off \
  #-serial file:qemu-serial.log \
  #-monitor vc:1024x768 \#qemu-system-x86_64 \
#    -machine q35 \
#    -cpu max \
#    -m "$RAM_SIZE" \
#    -cdrom "$ALPINE_ISO" \
#    -virtfs local,path="$OVERLAY_SRC",mount_tag=overlay-src,security_model=none \
#    -virtfs local,path="$CUSTOM_DIR",mount_tag=custom,security_model=none \
#    -netdev user,id=net0,dns=8.8.8.8 \
#    -device virtio-net-pci,netdev=net0 \
#    -nographic \
#    -monitor none \
#    -serial mon:stdio \
#    -boot d

echo ""
echo "🔄 Alpine diskless boot simulation completed."
# Note: Alpine diskless architecture memory usage breakdown:
# - Alpine base system: ~100MB
# - Runtime apkovl extraction (full snapshot): ~200-500MB
# - Package installation (system-bootstrap): ~300-500MB
# - k3s server + kubelet: ~500MB-1GB
# - System pods (coredns, metrics-server, traefik): ~400-600MB
# Total recommended: 4GB for full k3s testing (2GB causes timeout issues)
