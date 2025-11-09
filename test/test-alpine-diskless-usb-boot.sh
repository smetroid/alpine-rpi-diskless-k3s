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

echo "🔌 Alpine Linux USB Boot Simulation"
echo "====================================="
echo ""
echo "Target Hardware: Raspberry Pi 4 and Pi 5"
echo "Boot Device: USB Drive (/dev/sda)"
echo "Test Mode: Single-node k3s server"
echo ""
