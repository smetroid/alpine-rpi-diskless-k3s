#!/bin/bash

# Alpine k3s Cluster Boot Simulation
# Starts multiple QEMU instances for multi-node cluster testing
# Uses socket networking for VM-to-VM cluster communication
#
# Usage:
#   ./test-alpine-cluster.sh [config-file]           # Start all nodes
#   ./test-alpine-cluster.sh [config-file] <index>   # Start specific node
#   ./test-alpine-cluster.sh stop [all|name]         # Stop VMs
#   ./test-alpine-cluster.sh status                  # Show status

set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
VM_DIR="$TEST_DIR/vm-multinode"

# Handle stop command (before any config processing)
if [ "${1:-}" = "stop" ]; then
    cd "$VM_DIR"
    TARGET="${2:-all}"
    if [ "$TARGET" = "all" ] || [ -z "$TARGET" ]; then
        echo "Stopping all cluster VMs..."
        pkill -f "qemu-system.*-name.*qemu-test" 2>/dev/null || echo "No VMs to stop"
        rm -f *.pid 2>/dev/null
    else
        echo "Stopping VM: $TARGET"
        pkill -f "qemu-system.*-name $TARGET" 2>/dev/null || echo "VM not found: $TARGET"
        rm -f "${TARGET}.pid" 2>/dev/null
    fi
    exit 0
fi

# Handle status command (before any config processing)
if [ "${1:-}" = "status" ]; then
    echo "Running QEMU VMs:"
    echo ""
    pgrep -lf "qemu-system.*-name.*qemu-test" || echo "No VMs running"
    echo ""
    echo "VM directory: $VM_DIR"
    ls -la "$VM_DIR"/*.pid 2>/dev/null || echo "No PID files found"
    exit 0
fi

# Determine config file and build directory
CONFIG_FILE="${1:-qemu.yaml}"
CONFIG_BASENAME="$(basename "$CONFIG_FILE")"

# Export CONFIG_FILE before sourcing yaml-parser
export CONFIG_FILE

# Determine build directory based on config basename
case "$CONFIG_BASENAME" in
    qemu.yaml|*-test.yaml|*-qemu.yaml)
        BUILD_DIR="builds-qemu"
        ;;
    *)
        BUILD_DIR="builds"
        ;;
esac

echo "🍃 Alpine k3s Cluster Boot Simulation"
echo "=========================================="
echo ""
echo "Using configuration: $CONFIG_FILE"
echo "Build directory: $BUILD_DIR"

# Source the yaml parser to get node information
source "$PROJECT_DIR/lib/yaml-parser.sh"

# Get all nodes from config
echo ""
echo "Discovering nodes from configuration..."
NODES=()
while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    if [ -n "$NODE_NAME" ]; then
        NODES+=("$NODE_NAME:$NODE_IP:$NODE_ROLE")
        echo "  Found: $NODE_NAME ($NODE_ROLE) at $NODE_IP"
    fi
done < <(yaml_get_nodes | grep -v '^$')

if [ ${#NODES[@]} -eq 0 ]; then
    echo "❌ No nodes found in configuration!"
    exit 1
fi

echo ""
echo "Found ${#NODES[@]} node(s) in configuration"
echo ""

# Common paths
ALPINE_VERSION="${ALPINE_VERSION:-3.22.1}"
ALPINE_ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/x86_64/alpine-virt-${ALPINE_VERSION}-x86_64.iso"
VM_DIR="$TEST_DIR/vm-multinode"
mkdir -p "$VM_DIR"
cd "$VM_DIR"

# Use ISO in VM_DIR if exists, otherwise use ISO_DIR (for download)
ALPINE_ISO="$VM_DIR/alpine-virt-${ALPINE_VERSION}-x86_64.iso"

# QEMU socket port for VM-to-VM networking
SOCKET_PORT="1234"
RAM_SIZE="${RAM_SIZE:-4096M}"

# Download Alpine ISO if not present
if [ ! -f "$ALPINE_ISO" ]; then
    echo "📥 Downloading Alpine Linux..."
    curl -L -o "$ALPINE_ISO" "$ALPINE_ISO_URL"
fi

# Extract kernel and initramfs from ISO
echo "📦 Extracting kernel and initramfs from ISO for direct boot..."
KERNEL_FILE="vmlinuz-virt"
INITRD_FILE="initramfs-virt"

if [ -f "$KERNEL_FILE" ] && [ -f "$INITRD_FILE" ]; then
    echo "✅ Kernel and initramfs already present"
else
    echo "   Extracting from ISO..."
    # Clean up any partial boot directory
    rm -rf boot
    # Extract both files at once
    bsdtar -xf "$ALPINE_ISO" boot/vmlinuz-virt boot/initramfs-virt
    # Move to current directory
    mv boot/vmlinuz-virt "$KERNEL_FILE"
    mv boot/initramfs-virt "$INITRD_FILE"
    rmdir boot
    echo "✅ Kernel and initramfs ready"
fi
echo ""

# Function to start a single node
start_node() {
    local NODE_INFO="$1"
    local NODE_INDEX="$2"
    local IS_MASTER="$3"

    IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE <<< "$NODE_INFO"

    local APK_VOL="$PROJECT_DIR/$BUILD_DIR/${NODE_NAME}.apkovl.tar.gz"
    local SSH_PORT=$((2221 + NODE_INDEX))

    if [ ! -f "$APK_VOL" ]; then
        echo "⚠️  Warning: Overlay not found: $APKOL"
        echo "   Run 'make build-test' first"
        return 1
    fi

    echo "🚀 Starting node: $NODE_NAME"
    echo "   Role: $NODE_ROLE"
    echo "   SSH: ssh root@localhost -p $SSH_PORT"
    echo "   IP: $NODE_IP"
    echo ""

    # Create data disk if not exists
    local DATA_DISK="${NODE_NAME}-data.qcow2"
    if [ ! -f "$DATA_DISK" ]; then
        echo "   Creating data disk (1G)..."
        qemu-img create -f qcow2 "$DATA_DISK" 1G
    fi

    # Prepare overlay directory for this node
    local OVERLAY_DIR="$VM_DIR/overlay-${NODE_INDEX}"
    rm -rf "$OVERLAY_DIR"
    mkdir -p "$OVERLAY_DIR"

    # Extract apkovl to overlay directory
    echo "   Preparing overlay for $NODE_NAME..."
    tar -xzf "$APK_VOL" -C "$OVERLAY_DIR" 2>/dev/null || true

    # Set hostname in overlay
    echo "$NODE_NAME" > "$OVERLAY_DIR/etc/hostname"

    # Generate MAC address based on node index
    local mac_octet
    mac_octet="$(printf '%02x' $NODE_INDEX)"
    local MAC_ADDR="52:54:00:00:00:$mac_octet"

    # Kernel command line with cgroups for k3s
    local KERNEL_CMDLINE="modules=loop,squashfs,sd-mod,usb-storage quiet console=ttyS0,115200 cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset"

    # Network setup:
    # - eth0: socket network for VM-to-VM cluster (server listens, workers connect)
    # - eth1: user mode for host access with port forwarding (DHCP)
    local cluster_netdev
    if [ "$IS_MASTER" = "true" ]; then
        # Master listens for connections
        cluster_netdev="socket,id=cluster,listen=:${SOCKET_PORT}"
        echo "   Cluster network: Listening on socket port $SOCKET_PORT"
    else
        # Workers connect to master
        cluster_netdev="socket,id=cluster,connect=127.0.0.1:${SOCKET_PORT}"
        echo "   Cluster network: Connecting to master on socket port $SOCKET_PORT"
    fi

    # Start QEMU instance in background
    qemu-system-x86_64 \
        -name "$NODE_NAME" \
        -m "$RAM_SIZE" \
        -kernel "$KERNEL_FILE" \
        -initrd "$INITRD_FILE" \
        -append "$KERNEL_CMDLINE" \
        -cdrom "$ALPINE_ISO" \
        -drive "file=$DATA_DISK,format=qcow2" \
        -drive "file=fat:rw:$OVERLAY_DIR,format=raw" \
        -netdev "$cluster_netdev" \
        -device "virtio-net-pci,netdev=cluster,mac=$MAC_ADDR" \
        -netdev "user,id=hostnet,hostfwd=tcp::${SSH_PORT}-:22" \
        -device "virtio-net-pci,netdev=hostnet" \
        -display none \
        -serial mon:stdio \
        > "${NODE_NAME}.log" 2>&1 &

    local PID=$!
    echo "   PID: $PID"
    echo "   Log: ${VM_DIR}/${NODE_NAME}.log"
    echo ""

    # Save PID for cleanup
    echo "$PID" > "${NODE_NAME}.pid"

    return 0
}

# Check if a specific node was requested
if [ -n "$2" ]; then
    NODE_INDEX="$2"
    if [ "$NODE_INDEX" -lt 1 ] || [ "$NODE_INDEX" -gt "${#NODES[@]}" ]; then
        echo "❌ Invalid node index: $NODE_INDEX (valid: 1-${#NODES[@]})"
        exit 1
    fi

    NODE_INFO="${NODES[$((NODE_INDEX - 1))]}"
    IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE <<< "$NODE_INFO"
    IS_MASTER="$([ "$NODE_ROLE" = "master" ] && echo "true" || echo "false")"
    start_node "$NODE_INFO" "$NODE_INDEX" "$IS_MASTER"

    echo ""
    echo "✅ Single node started: $NODE_INFO"
    echo ""
    echo "Access the node:"
    echo "  ssh -o StrictHostKeyChecking=no root@localhost -p $((2221 + NODE_INDEX))"
else
    # Start all nodes with master first
    echo "Starting all ${#NODES[@]} nodes (master first)..."
    echo ""

    INDEX=1
    MASTER_STARTED=false

    for NODE_INFO in "${NODES[@]}"; do
        IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE <<< "$NODE_INFO"

        if [ "$NODE_ROLE" = "master" ] && [ "$MASTER_STARTED" = "false" ]; then
            # Start master first
            start_node "$NODE_INFO" "$INDEX" "true"
            MASTER_STARTED=true
            INDEX=$((INDEX + 1))

            echo "⏳ Waiting 60 seconds for master k3s initialization..."
            sleep 60
            echo "✅ Master initialization complete, starting workers..."
            echo ""
        elif [ "$NODE_ROLE" != "master" ]; then
            # Start workers
            start_node "$NODE_INFO" "$INDEX" "false"
            INDEX=$((INDEX + 1))
        fi
    done

    echo ""
    echo "=========================================="
    echo "✅ Cluster started with $((INDEX - 1)) node(s)"
    echo ""
    echo "Cluster access:"
    for i in $(seq 1 $((INDEX - 1))); do
        NODE_INFO="${NODES[$((i - 1))]}"
        IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE <<< "$NODE_INFO"
        SSH_PORT=$((2221 + i))
        echo "  $NODE_NAME ($NODE_ROLE): ssh root@localhost -p $SSH_PORT"
    done
    echo ""
    echo "Check logs: tail -f $VM_DIR/*.log"
    echo "Stop cluster: make qemu-cluster-stop"
    echo ""
fi

