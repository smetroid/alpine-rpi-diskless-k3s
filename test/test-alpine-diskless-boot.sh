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

# Network mode selection
NETWORK_MODE="${NETWORK_MODE:-dhcp}"  # dhcp or bridge
echo "🌐 Network mode: $NETWORK_MODE"

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

# Prepare overlay based on network mode
log "Preparing overlay for $NETWORK_MODE mode..."
TEMP_OVERLAY="$VM_DIR/temp-overlay"
rm -rf "$TEMP_OVERLAY"
mkdir -p "$TEMP_OVERLAY"

# Extract original overlay
cd "$TEMP_OVERLAY"
tar -xzf "$APKVOL"

# Modify network config for DHCP mode
if [ "$NETWORK_MODE" = "dhcp" ]; then
    log "Configuring DHCP networking for testing..."
    
    # Modify existing interfaces file to use DHCP instead of static
    # Keep the loopback configuration but replace eth0 static with dynamic detection
    cat > etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback
EOF
    
    # Change hostname for testing
    echo "k3s-21-test" > etc/hostname
    
    # Disable networking service to avoid conflicts
    rm -f etc/runlevels/default/networking
    
    # Create dynamic network OpenRC service
    cat > etc/init.d/dynamic-network << 'EOF'
#!/sbin/openrc-run

description="Dynamic network interface configuration service"
name="dynamic network"

depend() {
    need localmount
    after localmount
    before system-bootstrap k3s-bootstrap
    provide network-config
}

start_pre() {
    ebegin "Preparing dynamic network configuration"
    return 0
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
    chmod +x etc/init.d/dynamic-network
    
    # Enable the dynamic-network service in default runlevel
    ln -sf /etc/init.d/dynamic-network etc/runlevels/default/dynamic-network
fi

# Debug: Check what files exist before repacking
log "Files in overlay before repacking:"
find . -name "interfaces" -exec ls -la {} \;
ls -la etc/network/ || log "etc/network directory not found"
ls -la root/.ssh/authorized_keys 2>/dev/null || log "authorized_keys not found"

# Repack overlay (include root directory!)
tar -czf "$OVERLAY_DIR/k3s-21.apkovl.tar.gz" etc usr root var 2>/dev/null
cd "$VM_DIR"

# Debug: Check overlay contents
log "Checking overlay contents:"
tar -tzf "$OVERLAY_DIR/k3s-21.apkovl.tar.gz" | grep interfaces || log "No interfaces file in overlay"
tar -tzf "$OVERLAY_DIR/k3s-21.apkovl.tar.gz" | grep authorized_keys || log "No authorized_keys in overlay"

rm -rf "$TEMP_OVERLAY"

if [ -f "$OVERLAY_DIR/k3s-21.apkovl.tar.gz" ]; then
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
    
    qemu-system-x86_64 \
      -m $RAM_SIZE \
      -cdrom "$ALPINE_ISO" \
      -boot d \
      -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::6443-:6443,hostfwd=tcp::8080-:8080,dns=1.1.1.1 \
      -device virtio-net-pci,netdev=net0 \
      -drive file="$DATA_DISK",format=qcow2 \
      -drive file=fat:rw:"$OVERLAY_DIR",format=raw 
      #-nographic
      #-serial mon:stdio
      #-netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::6443-:6443,hostfwd=tcp::8080-:8080,dns=8.8.8.8 \
      #-device virtio-net-pci,netdev=net0 \
      #-netdev user,id=net0,dns=8.8.8.8 \
      #-device virtio-net-pci,netdev=net0 \

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
    
    qemu-system-x86_64 \
      -m $RAM_SIZE \
      -cdrom "$ALPINE_ISO" \
      -boot d \
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