#!/bin/bash

# Unified QEMU Test Script
# Handles both single-node and multi-node cluster testing
#
# Usage:
#   ./qemu-test.sh server                    # Start the k3s server (master node)
#   ./qemu-test.sh worker <node-name>        # Start a worker node
#   ./qemu-test.sh status                    # Show running VMs
#   ./qemu-test.sh stop [node-name|all]      # Stop VM(s)
#
# Environment Variables:
#   CONFIG_FILE    YAML config file (default: qemu.yaml)
#   RAM_SIZE       VM RAM size (default: 4096M)
#   NETWORK_MODE   Networking mode (default: socket)

set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
VM_DIR="$TEST_DIR/qemu-cluster"
OVERLAY_DIR="$VM_DIR/overlays"

# Default configuration
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/qemu.yaml}"
[[ "$CONFIG_FILE" != /* ]] && CONFIG_FILE="$PROJECT_DIR/$CONFIG_FILE"
export CONFIG_FILE

RAM_SIZE="${RAM_SIZE:-4096M}"
NETWORK_MODE="${NETWORK_MODE:-socket}"
SOCKET_PORT="1234"

# Determine build directory based on config basename
CONFIG_BASENAME="$(basename "$CONFIG_FILE")"
case "$CONFIG_BASENAME" in
    qemu.yaml|*-test.yaml|*-qemu.yaml)
        BUILD_DIR="$PROJECT_DIR/builds-qemu"
        ;;
    *)
        BUILD_DIR="$PROJECT_DIR/builds"
        ;;
esac

# Source YAML parser
source "$PROJECT_DIR/lib/yaml-parser.sh"

# Source cache library if available
if [ -f "$PROJECT_DIR/lib/cache.sh" ]; then
    source "$PROJECT_DIR/lib/cache.sh"
fi

usage() {
    cat << EOF
Unified QEMU Test Script

Usage: $0 <command> [options]

Commands:
    server                    Boot the master node from config
    worker <node-name>        Boot a specific worker node
    status                    Show running VMs
    stop [node-name|all]      Stop VM(s)

Environment Variables:
    CONFIG_FILE    YAML config file (default: qemu.yaml)
    RAM_SIZE       VM RAM size (default: 4096M)
    NETWORK_MODE   Networking mode (default: socket)

Examples:
    # Single-node test
    $0 server

    # Multi-node cluster
    $0 server                      # Terminal 1
    $0 worker qemu-2               # Terminal 2
    $0 worker qemu-3               # Terminal 3

    # Management
    $0 status
    $0 stop all

EOF
    exit 1
}

# Get node info from YAML config
# yaml_get_nodes returns lines in format: name:ip:role
get_node_ip() {
    local node_name="$1"
    yaml_get_nodes | grep "^${node_name}:" | cut -d: -f2
}

get_node_role() {
    local node_name="$1"
    yaml_get_nodes | grep "^${node_name}:" | cut -d: -f3
}

get_master_node() {
    yaml_get_nodes | grep ":master$" | head -1 | cut -d: -f1
}

get_master_ip() {
    yaml_get_nodes | grep ":master$" | head -1 | cut -d: -f2
}

generate_mac() {
    local node_name="$1"
    local ip
    ip=$(get_node_ip "$node_name")
    local last_octet
    last_octet=$(echo "$ip" | cut -d. -f4)
    printf "52:54:00:12:34:%02x" "$last_octet"
}

list_worker_nodes() {
    echo "Available worker nodes:"
    while IFS=: read -r node ip role; do
        if [ "$role" = "worker" ]; then
            echo "  $node ($ip)"
        fi
    done < <(yaml_get_nodes)
}

# Get Alpine version from config
get_alpine_version() {
    local version
    version=$(yaml_get "alpine.version")
    echo "${version:-3.22.1}"  # Default fallback
}

# Get Alpine architecture from config
get_alpine_arch() {
    local arch
    arch=$(yaml_get "alpine.architecture")
    echo "${arch:-x86_64}"  # Default fallback
}

# Setup VM directory and download Alpine
setup_environment() {
    mkdir -p "$VM_DIR" "$OVERLAY_DIR"
    cd "$VM_DIR"

    # Get Alpine version and architecture from config
    local alpine_version
    local alpine_arch
    alpine_version=$(get_alpine_version)
    alpine_arch=$(get_alpine_arch)

    # Extract major.minor version for download URL (e.g., "3.22.1" -> "3.22")
    local alpine_series
    alpine_series=$(echo "$alpine_version" | cut -d. -f1-2)

    local alpine_iso="alpine-virt-${alpine_version}-${alpine_arch}.iso"

    # Check cache first
    if [ -n "$ALPINE_CACHE_KEY" ] && type cache_get >/dev/null 2>&1; then
        local cache_key=$(cache_key_alpine_iso "virt" "$alpine_version" "$alpine_arch" "iso" 2>/dev/null || echo "")
        if [ -n "$cache_key" ] && cache_get "alpine-iso" "$cache_key" "$alpine_iso"; then
            echo "Using cached Alpine ISO: $alpine_iso"
        fi
    fi

    # Download if not in cache
    if [ ! -f "$alpine_iso" ]; then
        echo "Downloading Alpine Linux ${alpine_version} (${alpine_arch})..."
        local iso_url="https://dl-cdn.alpinelinux.org/alpine/v${alpine_series}/releases/${alpine_arch}/${alpine_iso}"
        curl -L "$iso_url" -o "$alpine_iso"

        # Store in cache for next time
        if [ -n "$cache_key" ] && type cache_put >/dev/null 2>&1; then
            cache_put "alpine-iso" "$cache_key" "$alpine_iso"
        fi
    fi

    # Extract kernel and initramfs
    if [ ! -f "vmlinuz-virt" ] || [ ! -f "initramfs-virt" ]; then
        echo "Extracting kernel and initramfs..."

        EXTRACTION_SUCCESS=false

        # Try bsdtar first (built into macOS, works on Linux too)
        if command -v bsdtar >/dev/null 2>&1; then
            if bsdtar -xf "$alpine_iso" boot/vmlinuz-virt boot/initramfs-virt 2>/dev/null; then
                if [ -f "boot/vmlinuz-virt" ] && [ -f "boot/initramfs-virt" ]; then
                    mv boot/vmlinuz-virt vmlinuz-virt
                    mv boot/initramfs-virt initramfs-virt
                    rmdir boot 2>/dev/null || true
                    EXTRACTION_SUCCESS=true
                fi
            fi
        fi

        # Try 7z if bsdtar failed
        if [ "$EXTRACTION_SUCCESS" = "false" ] && command -v 7z >/dev/null 2>&1; then
            if 7z e "$alpine_iso" boot/vmlinuz-virt boot/initramfs-virt -o. >/dev/null 2>&1; then
                if [ -f "vmlinuz-virt" ] && [ -f "initramfs-virt" ]; then
                    EXTRACTION_SUCCESS=true
                fi
            fi
        fi

        # Try direct mount on Linux
        if [ "$EXTRACTION_SUCCESS" = "false" ] && [[ "$OSTYPE" != "darwin"* ]]; then
            local iso_mount
            iso_mount=$(mktemp -d)
            if sudo mount -o loop,ro "$alpine_iso" "$iso_mount" 2>/dev/null; then
                if [ -f "$iso_mount/boot/vmlinuz-virt" ]; then
                    cp "$iso_mount/boot/vmlinuz-virt" vmlinuz-virt
                    cp "$iso_mount/boot/initramfs-virt" initramfs-virt
                    EXTRACTION_SUCCESS=true
                fi
                sudo umount "$iso_mount"
            fi
            rmdir "$iso_mount"
        fi

        if [ "$EXTRACTION_SUCCESS" = "false" ]; then
            echo "ERROR: Failed to extract kernel. Install bsdtar or 7z."
            exit 1
        fi
    fi
}

# Create apkovl extract service for QEMU testing
create_apkovl_extract_service() {
    local apkovl_dir="$1"

    mkdir -p "${apkovl_dir}/etc/init.d"
    cat > "${apkovl_dir}/etc/init.d/apkovl-extract" << 'EOF'
#!/sbin/openrc-run

description="Extract apkovl overlay from FAT drive"
name="apkovl extract"

depend() {
    need localmount
    before qemu-device-setup
    provide apkovl-extract
}

start() {
    ebegin "Extracting apkovl overlay"

    # Find the FAT drive with apkovl
    for mount in /media/sdb1 /media/sda1 /media/cdrom; do
        if [ -f "$mount"/*.apkovl.tar.gz ]; then
            APOVL_FILE=$(ls "$mount"/*.apkovl.tar.gz | head -1)
            einfo "Found apkovl: $APOVL_FILE"

            # Extract to root filesystem
            cd /
            if tar -xzf "$APOVL_FILE" 2>/dev/null; then
                einfo "Successfully extracted overlay"
                eend 0
                return 0
            else
                eerror "Failed to extract overlay"
                eend 1
                return 1
            fi
        fi
    done

    ewarn "No apkovl found on FAT drives"
    eend 0  # Not fatal - system can boot without apkovl
}
EOF
    chmod +x "${apkovl_dir}/etc/init.d/apkovl-extract"

    mkdir -p "${apkovl_dir}/etc/runlevels/boot"
    ln -sf /etc/init.d/apkovl-extract "${apkovl_dir}/etc/runlevels/boot/apkovl-extract"
}

# Create QEMU device setup service
create_qemu_device_service() {
    local apkovl_dir="$1"

    mkdir -p "${apkovl_dir}/etc/init.d"
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

    # Find storage device
    STORAGE_DEV=""
    [ -b /dev/sda ] && STORAGE_DEV="/dev/sda"
    [ -b /dev/vda ] && STORAGE_DEV="/dev/vda"

    if [ -z "$STORAGE_DEV" ]; then
        eerror "No storage device found"
        eend 1
        return 1
    fi

    einfo "Using storage device: $STORAGE_DEV"

    # Check if already partitioned
    if [ -b "${STORAGE_DEV}1" ] && [ -b "${STORAGE_DEV}2" ]; then
        einfo "Partitions already exist"
    else
        # Partition the disk
        einfo "Creating partitions..."
        (echo n; echo p; echo 1; echo; echo +256M; echo n; echo p; echo 2; echo; echo; echo t; echo 1; echo c; echo w) | fdisk "$STORAGE_DEV" >/dev/null 2>&1 || true

        partprobe "$STORAGE_DEV" 2>/dev/null || true

        einfo "Waiting for partition devices to appear..."
        local timeout=10
        local count=0
        while [ $count -lt $timeout ]; do
            if [ -b "${STORAGE_DEV}1" ] && [ -b "${STORAGE_DEV}2" ]; then
                einfo "Partition devices ready: ${STORAGE_DEV}1, ${STORAGE_DEV}2"
                break
            fi
            sleep 1
            count=$((count + 1))
        done

        if [ $count -ge $timeout ]; then
            eerror "Timeout waiting for partition devices"
            eend 1
            return 1
        fi
    fi

    # Create mmcblk0 device nodes for Pi compatibility
    if [ -b "${STORAGE_DEV}1" ] && [ -b "${STORAGE_DEV}2" ]; then
        mknod /dev/mmcblk0 b $(stat -c "%t %T" "$STORAGE_DEV") 2>/dev/null || true
        mknod /dev/mmcblk0p1 b $(stat -c "%t %T" "${STORAGE_DEV}1") 2>/dev/null || true
        mknod /dev/mmcblk0p2 b $(stat -c "%t %T" "${STORAGE_DEV}2") 2>/dev/null || true
        einfo "Created /dev/mmcblk0 device nodes"
    fi

    eend 0
}
EOF
    chmod +x "${apkovl_dir}/etc/init.d/qemu-device-setup"

    mkdir -p "${apkovl_dir}/etc/runlevels/default"
    ln -sf /etc/init.d/qemu-device-setup "${apkovl_dir}/etc/runlevels/default/qemu-device-setup"
}

# Create data disk for a node
create_data_disk() {
    local node_name="$1"
    local disk_file="$VM_DIR/${node_name}-data.qcow2"

    if [ ! -f "$disk_file" ]; then
        echo "Creating data disk for $node_name..." >&2
        qemu-img create -f qcow2 "$disk_file" 4G >/dev/null
    fi
    echo "$disk_file"
}

# Prepare overlay for a specific node
prepare_overlay() {
    local node_name="$1"

    local apkovl_file="$BUILD_DIR/${node_name}.apkovl.tar.gz"
    local overlay_subdir="$OVERLAY_DIR/$node_name"
    local temp_dir="$VM_DIR/temp-${node_name}"

    if [ ! -f "$apkovl_file" ]; then
        echo "ERROR: Overlay not found: $apkovl_file"
        echo "Run 'make build' or './scripts/build-from-yaml.sh $CONFIG_FILE' first."
        exit 1
    fi

    # Get node IP for dual NIC configuration
    local node_ip
    node_ip=$(get_node_ip "$node_name")

    # Clean and recreate overlay directory
    rm -rf "$overlay_subdir" "$temp_dir"
    mkdir -p "$overlay_subdir" "$temp_dir"

    # Extract original overlay
    cd "$temp_dir"
    tar -xzf "$apkovl_file"

    # Add QEMU device setup service
    create_qemu_device_service "$temp_dir"

    # Add apkovl extract service for ISO boot
    create_apkovl_extract_service "$temp_dir"

    # Configure dual NICs for QEMU testing:
    # - eth0: Cluster network (static IP, VM-to-VM via socket, NO gateway)
    # - eth1: Host access network (DHCP via QEMU user mode, provides internet)
    if [ -f etc/network/interfaces ]; then
        cat > etc/network/interfaces << EOF
auto lo
iface lo inet loopback

# Cluster network (VM-to-VM, static IP, no gateway)
auto eth0
iface eth0 inet static
    address $node_ip
    netmask 255.255.255.0

# Host access network (QEMU user mode, DHCP, provides internet)
auto eth1
iface eth1 inet dhcp
EOF
    fi

    # Repack overlay (include all overlay directories)
    tar -czf "$overlay_subdir/${node_name}.apkovl.tar.gz" etc usr root var sbin lib 2>/dev/null || \
    tar -czf "$overlay_subdir/${node_name}.apkovl.tar.gz" etc usr root sbin lib 2>/dev/null

    cd "$VM_DIR"
    rm -rf "$temp_dir"

    echo "$overlay_subdir"
}

# Start a VM
start_vm() {
    local node_name="$1"
    local node_ip="$2"
    local role="$3"

    # Get Alpine version and architecture from config
    local alpine_version
    local alpine_arch
    alpine_version=$(get_alpine_version)
    alpine_arch=$(get_alpine_arch)

    local alpine_iso="alpine-virt-${alpine_version}-${alpine_arch}.iso"

    local mac_addr
    mac_addr=$(generate_mac "$node_name")

    local data_disk
    data_disk=$(create_data_disk "$node_name")

    local overlay_dir
    overlay_dir=$(prepare_overlay "$node_name")

    echo ""
    echo "Starting $node_name ($role) - IP: $node_ip"
    echo "============================================="
    echo "  MAC: $mac_addr"
    echo "  RAM: $RAM_SIZE"
    echo "  Data disk: $data_disk"
    echo ""

    if [ "$role" = "master" ]; then
        echo "This is the k3s SERVER node."
        echo "Wait for k3s to start (~2-3 min) before starting workers."
        echo ""
        echo "Monitor k3s status inside VM:"
        echo "  kubectl get nodes"
        echo "  journalctl -u k3s -f"
    else
        echo "This is a k3s WORKER node."
        echo "It will attempt to join the server at $(get_master_ip):6443"
        echo ""
        echo "Make sure the server is running and k3s is initialized!"
    fi
    echo ""

    # Port forwarding for host access
    local last_octet
    last_octet=$(echo "$node_ip" | cut -d. -f4)
    local ssh_port=$((2200 + last_octet))
    local api_fwd=""

    if [ "$role" = "master" ]; then
        api_fwd=",hostfwd=tcp::6443-:6443"
    fi

    echo "Host access:"
    echo "  SSH: ssh root@localhost -p $ssh_port"
    if [ "$role" = "master" ]; then
        echo "  k3s API: localhost:6443"
    fi
    echo ""

    cd "$VM_DIR"

    # Kernel command line with cgroups for k3s
    local kernel_cmd="modules=loop,squashfs,sd-mod,usb-storage quiet console=ttyS0,115200 cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset"

    # Network setup based on mode
    if [ "$NETWORK_MODE" = "socket" ]; then
        # Socket networking for multi-node clusters
        local cluster_netdev
        if [ "$role" = "master" ]; then
            cluster_netdev="socket,id=cluster,listen=:${SOCKET_PORT}"
            echo "Cluster network: Server listening on port $SOCKET_PORT"
        else
            cluster_netdev="socket,id=cluster,connect=127.0.0.1:${SOCKET_PORT}"
            echo "Cluster network: Connecting to server on port $SOCKET_PORT"
        fi

        qemu-system-x86_64 \
            -name "$node_name" \
            -m "$RAM_SIZE" \
            -kernel vmlinuz-virt \
            -initrd initramfs-virt \
            -append "$kernel_cmd" \
            -cdrom "$alpine_iso" \
            -drive "file=$data_disk,format=qcow2" \
            -drive "file=fat:rw:$overlay_dir,format=raw" \
            -netdev "$cluster_netdev" \
            -device "virtio-net-pci,netdev=cluster,mac=$mac_addr" \
            -netdev "user,id=hostnet,hostfwd=tcp::${ssh_port}-:22${api_fwd}" \
            -device "virtio-net-pci,netdev=hostnet" \
            -display none \
            -serial mon:stdio

    elif [ "$NETWORK_MODE" = "dhcp" ]; then
        # Single VM with user networking (DHCP)
        echo "Network mode: DHCP (user networking)"
        qemu-system-x86_64 \
            -name "$node_name" \
            -m "$RAM_SIZE" \
            -kernel vmlinuz-virt \
            -initrd initramfs-virt \
            -append "$kernel_cmd" \
            -cdrom "$alpine_iso" \
            -drive "file=$data_disk,format=qcow2" \
            -drive "file=fat:rw:$overlay_dir,format=raw" \
            -netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22${api_fwd},dns=8.8.8.8" \
            -device "virtio-net-pci,netdev=net0" \
            -display none \
            -serial mon:stdio

    elif [ "$NETWORK_MODE" = "bridge" ]; then
        # Single VM with bridge networking
        echo "Network mode: Bridge (requires br0)"
        qemu-system-x86_64 \
            -name "$node_name" \
            -m "$RAM_SIZE" \
            -kernel vmlinuz-virt \
            -initrd initramfs-virt \
            -append "$kernel_cmd" \
            -cdrom "$alpine_iso" \
            -drive "file=$data_disk,format=qcow2" \
            -drive "file=fat:rw:$overlay_dir,format=raw" \
            -netdev "bridge,id=net0,br=br0" \
            -device "virtio-net-pci,netdev=net0" \
            -serial mon:stdio
    fi
}

# Show status of running VMs
show_status() {
    echo "Running QEMU VMs:"
    echo ""
    pgrep -af "qemu-system.*-name" | grep -v grep || echo "No VMs running"
}

# Stop VM(s)
stop_vm() {
    local target="$1"

    if [ "$target" = "all" ]; then
        echo "Stopping all VMs..."
        pkill -f "qemu-system.*socket.*cluster" || echo "No VMs to stop"
    else
        echo "Stopping $target..."
        pkill -f "qemu-system.*-name $target" || echo "VM not found: $target"
    fi
}

# Main
case "${1:-}" in
    server)
        setup_environment
        master_node=$(get_master_node)
        if [ -z "$master_node" ]; then
            echo "ERROR: No master node found in config"
            exit 1
        fi
        master_ip=$(get_master_ip)
        start_vm "$master_node" "$master_ip" "master"
        ;;

    worker)
        if [ -z "${2:-}" ]; then
            echo "ERROR: Node name required for worker"
            echo ""
            list_worker_nodes
            exit 1
        fi

        node_name="$2"
        node_ip=$(get_node_ip "$node_name")
        node_role=$(get_node_role "$node_name")

        if [ -z "$node_ip" ]; then
            echo "ERROR: Node '$node_name' not found in config"
            echo ""
            list_worker_nodes
            exit 1
        fi

        if [ "$node_role" = "master" ]; then
            echo "ERROR: $node_name is a master node, use '$0 server' instead"
            exit 1
        fi

        setup_environment
        start_vm "$node_name" "$node_ip" "$node_role"
        ;;

    status)
        show_status
        ;;

    stop)
        stop_vm "${2:-all}"
        ;;

    *)
        usage
        ;;
esac
