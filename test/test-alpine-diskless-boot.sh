#!/bin/bash

# True Alpine Diskless Boot Simulation
# Simulates exactly how Alpine diskless works on Raspberry Pi

set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"

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
RAM_SIZE="512M"
ALPINE_VERSION="3.22.1"
VM_DIR="$TEST_DIR/vm-diskless"
mkdir -p "$VM_DIR" 
cd "$VM_DIR"
DATA_DISK=data.qcow2
OVERLAY_DIR=$TEST_DIR/overlaydir
mkdir -p "$OVERLAY_DIR"
APKVOL="$PROJECT_DIR/builds/k3s-21.apkovl.tar.gz"

# Check for overlay files first
if [ ! -d "$PROJECT_DIR/builds/k3s-21-apkovl" ] && [ ! -f "$PROJECT_DIR/builds/k3s-21.apkovl.tar.gz" ]; then
    echo "❌ No overlay found in builds/ directory"
    echo "💡 Please run first: ./scripts/build-from-yaml.sh"
    echo ""
    echo "This will generate the k3s-21-apkovl overlay that contains:"
    echo "  • /usr/local/bin/k3s_bootstrap script"
    echo "  • /etc/local.d/10-k3s-bootstrap.start service"
    echo "  • /etc/runlevels/default/local symlink"
    echo "  • Network and k3s configuration"
    exit 1
fi

# Download standard Alpine 
ALPINE_ISO="alpine-virt-${ALPINE_VERSION}-x86_64.iso"
if [ ! -f "$ALPINE_ISO" ]; then
    echo "📥 Downloading Alpine Linux..."
    curl -L "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/${ALPINE_ISO}" -o "$ALPINE_ISO"
fi

# --- Step 2: Create persistent data disk if missing ---
if [ ! -f "$DATA_DISK" ]; then
  log "Creating $DATA_DISK (4G)..."
  if qemu-img create -f qcow2 "$DATA_DISK" 4G; then
    log "Successfully created data disk"
  else
    log "ERROR: Failed to create data disk"
    exit 1
  fi
fi

# Pack overlay
log "Creating overlay archive..."
if cp "$APKVOL" "$OVERLAY_DIR/"; then
    log "Successfully copied overlay to overlay directory"
else
    log "ERROR: Failed to copy overlay to overlay directory"
    exit 1
fi

echo ""
echo "🚀 Booting Alpine Linux in diskless mode..."
echo "   This simulates your Raspberry Pi SD card boot process"
echo ""
echo "📝 After boot, run these commands to start the simulation:"
echo ""

qemu-system-x86_64 \
  -m $RAM_SIZE \
  -cdrom "$ALPINE_ISO" \
  -boot d \
  -drive file="$DATA_DISK",format=qcow2 \
  -drive file=fat:rw:"$OVERLAY_DIR",format=raw \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device e1000,netdev=net0 \
  -serial mon:stdio
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