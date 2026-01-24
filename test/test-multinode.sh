#!/bin/bash

# Multi-Node Alpine Diskless Boot Test
# Uses QEMU socket networking to create a virtual LAN between VMs
#
# Usage:
#   ./test-multinode.sh server              # Start the k3s server (master)
#   ./test-multinode.sh worker k3s-22       # Start a worker node
#   ./test-multinode.sh worker k3s-23       # Start another worker
#
# The VMs communicate over a virtual network using QEMU multicast sockets.
# No root/sudo required.

set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
VM_DIR="$TEST_DIR/vm-multinode"
OVERLAY_DIR="$VM_DIR/overlays"

# Configuration - must export CONFIG_FILE BEFORE sourcing yaml-parser
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/k3s.yaml}"
# Ensure absolute path
[[ "$CONFIG_FILE" != /* ]] && CONFIG_FILE="$PROJECT_DIR/$CONFIG_FILE"
export CONFIG_FILE

RAM_SIZE="${RAM_SIZE:-4096M}"
ALPINE_VERSION="3.22.1"

# Test network subnet (isolated from home network)
# Uses 10.99.0.x to avoid conflicts with typical home networks (192.168.x.x, 10.0.0.x)
TEST_SUBNET="10.99.0"

# QEMU socket port for VM-to-VM networking
# Server listens, workers connect (more reliable than multicast on macOS)
SOCKET_PORT="1234"

# Source YAML parser (after CONFIG_FILE is exported)
source "$PROJECT_DIR/lib/yaml-parser.sh"

usage() {
    cat << EOF
Multi-Node Alpine Diskless k3s Test

Usage:
    $0 server                    Start the k3s server (master node)
    $0 worker <node-name>        Start a worker node (e.g., k3s-22, k3s-23)
    $0 status                    Show running VMs
    $0 stop [node-name|all]      Stop VM(s)

Examples:
    # Terminal 1: Start server
    $0 server

    # Terminal 2: Start first worker (after server is ready)
    $0 worker k3s-22

    # Terminal 3: Start second worker
    $0 worker k3s-23

Environment Variables:
    CONFIG_FILE     YAML config file (default: k3s.yaml)
    RAM_SIZE        VM RAM size (default: 4096M)

Notes:
    - Start the server first and wait for k3s to initialize (~2-3 min)
    - Workers will automatically join using the token from config
    - VMs communicate over isolated test network (10.99.0.0/24)
    - This avoids conflicts with your home network
    - SSH from host: ssh root@localhost -p <port>

EOF
    exit 1
}

# Convert production IP to test IP
# e.g., 192.168.1.21 -> 10.99.0.21
prod_ip_to_test_ip() {
    local prod_ip="$1"
    local last_octet
    last_octet=$(echo "$prod_ip" | cut -d. -f4)
    echo "${TEST_SUBNET}.${last_octet}"
}

# Get node info from YAML config
# yaml_get_nodes returns lines in format: name:ip:role
get_node_ip() {
    local node_name="$1"
    local prod_ip
    prod_ip=$(yaml_get_nodes | grep "^${node_name}:" | cut -d: -f2)
    # Convert to test subnet IP
    prod_ip_to_test_ip "$prod_ip"
}

get_node_role() {
    local node_name="$1"
    yaml_get_nodes | grep "^${node_name}:" | cut -d: -f3
}

get_master_node() {
    # Find the first master node (format: name:ip:role)
    yaml_get_nodes | grep ":master$" | head -1 | cut -d: -f1
}

get_master_ip() {
    # Find the first master node's IP (converted to test subnet)
    local prod_ip
    prod_ip=$(yaml_get_nodes | grep ":master$" | head -1 | cut -d: -f2)
    prod_ip_to_test_ip "$prod_ip"
}

# Generate unique MAC address from node name
generate_mac() {
    local node_name="$1"
    # Use last octet of IP for uniqueness
    local ip
    ip=$(get_node_ip "$node_name")
    local last_octet
    last_octet=$(echo "$ip" | cut -d. -f4)
    printf "52:54:00:12:34:%02x" "$last_octet"
}

# Setup VM directory and download Alpine
setup_vm_environment() {
    mkdir -p "$VM_DIR" "$OVERLAY_DIR"
    cd "$VM_DIR"

    # Download Alpine ISO if needed
    local alpine_iso="alpine-virt-${ALPINE_VERSION}-x86_64.iso"
    if [ ! -f "$alpine_iso" ]; then
        echo "Downloading Alpine Linux $ALPINE_VERSION..."
        curl -L "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/${alpine_iso}" -o "$alpine_iso"
    fi

    # Extract kernel and initramfs
    if [ ! -f "vmlinuz-virt" ] || [ ! -f "initramfs-virt" ]; then
        echo "Extracting kernel and initramfs..."
        if command -v bsdtar >/dev/null 2>&1; then
            bsdtar -xf "$alpine_iso" boot/vmlinuz-virt boot/initramfs-virt 2>/dev/null || true
            if [ -f "boot/vmlinuz-virt" ]; then
                mv boot/vmlinuz-virt vmlinuz-virt
                mv boot/initramfs-virt initramfs-virt
                rmdir boot 2>/dev/null || true
            fi
        elif command -v 7z >/dev/null 2>&1; then
            7z e "$alpine_iso" boot/vmlinuz-virt boot/initramfs-virt -o. >/dev/null 2>&1 || true
        fi
    fi

    if [ ! -f "vmlinuz-virt" ]; then
        echo "ERROR: Failed to extract kernel. Install bsdtar or 7z."
        exit 1
    fi
}

# Create data disk for a node
create_data_disk() {
    local node_name="$1"
    local disk_file="$VM_DIR/${node_name}-data.qcow2"

    if [ ! -f "$disk_file" ]; then
        echo "Creating data disk for $node_name..." >&2
        qemu-img create -f qcow2 "$disk_file" 4G >&2
    fi
    echo "$disk_file"
}

# Prepare overlay for a specific node
prepare_overlay() {
    local node_name="$1"
    local node_ip="$2"
    local role="$3"

    local apkovl_file="$PROJECT_DIR/builds/${node_name}.apkovl.tar.gz"
    local overlay_subdir="$OVERLAY_DIR/$node_name"
    local temp_dir="$VM_DIR/temp-${node_name}"

    if [ ! -f "$apkovl_file" ]; then
        echo "ERROR: Overlay not found: $apkovl_file"
        echo "Run 'make build' first to generate overlays."
        exit 1
    fi

    # Clean and recreate overlay directory
    rm -rf "$overlay_subdir" "$temp_dir"
    mkdir -p "$overlay_subdir" "$temp_dir"

    # Extract original overlay
    cd "$temp_dir"
    tar -xzf "$apkovl_file"

    # Add QEMU device setup service
    create_qemu_device_service "$temp_dir"

    # Create network config for dual NICs:
    # - eth0: cluster network (static IP, VM-to-VM communication)
    # - eth1: host access (DHCP via QEMU user mode, provides internet)
    cat > etc/network/interfaces << EOF
auto lo
iface lo inet loopback

# Cluster network (VM-to-VM, static IP)
auto eth0
iface eth0 inet static
    address $node_ip
    netmask 255.255.255.0

# Host access network (QEMU user mode, DHCP)
auto eth1
iface eth1 inet dhcp
EOF

    # Update hostname
    echo "$node_name" > etc/hostname

    # Update /etc/hosts with cluster nodes (using test subnet IPs)
    cat > etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain
$node_ip    $node_name

# Cluster nodes (test subnet)
EOF
    # yaml_get_nodes returns lines in format: name:ip:role
    # Convert each IP to test subnet
    while IFS=: read -r n nip nrole; do
        local test_ip
        test_ip=$(prod_ip_to_test_ip "$nip")
        echo "$test_ip    $n" >> etc/hosts
    done < <(yaml_get_nodes)

    # Update k3s config to use test subnet IPs and force eth0 interface
    if [ -f etc/k3s/config.yaml ]; then
        # Force k3s to use eth0 (cluster network) not eth1 (QEMU NAT)
        echo "flannel-iface: eth0" >> etc/k3s/config.yaml

        if [ "$role" = "master" ]; then
            # Update master to advertise on test subnet IP
            sed -i.bak "s|advertise-address:.*|advertise-address: ${node_ip}|" etc/k3s/config.yaml
            sed -i.bak "s|node-ip:.*|node-ip: ${node_ip}|" etc/k3s/config.yaml
            sed -i.bak "s|bind-address:.*|bind-address: ${node_ip}|" etc/k3s/config.yaml
            rm -f etc/k3s/config.yaml.bak
        else
            # Worker: update server URL and node-ip
            local master_ip
            master_ip=$(get_master_ip)
            sed -i.bak "s|server:.*|server: https://${master_ip}:6443|" etc/k3s/config.yaml
            sed -i.bak "s|node-ip:.*|node-ip: ${node_ip}|" etc/k3s/config.yaml
            rm -f etc/k3s/config.yaml.bak
        fi
    fi

    # Repack overlay with node-specific hostname
    tar -czf "$overlay_subdir/${node_name}.apkovl.tar.gz" etc usr root var 2>/dev/null || \
    tar -czf "$overlay_subdir/${node_name}.apkovl.tar.gz" etc usr root 2>/dev/null

    cd "$VM_DIR"
    rm -rf "$temp_dir"

    echo "$overlay_subdir"
}

# Create QEMU device setup service (matches single-node test script)
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

    # Install e2fsprogs for partitioning
    apk add --no-cache e2fsprogs >/dev/null 2>&1 || true

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

        # Ensure kernel recognizes partitions
        partprobe "$STORAGE_DEV" 2>/dev/null || true

        # CRITICAL: Wait for kernel to create partition device nodes
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

    # Create mmcblk0 device nodes for Pi compatibility (not symlinks - they don't work with -b test)
    if [ -b "${STORAGE_DEV}1" ] && [ -b "${STORAGE_DEV}2" ]; then
        # Get major/minor numbers and create actual device nodes
        mknod /dev/mmcblk0 b $(stat -c "%t %T" "$STORAGE_DEV") 2>/dev/null || true
        mknod /dev/mmcblk0p1 b $(stat -c "%t %T" "${STORAGE_DEV}1") 2>/dev/null || true
        mknod /dev/mmcblk0p2 b $(stat -c "%t %T" "${STORAGE_DEV}2") 2>/dev/null || true
        einfo "Created /dev/mmcblk0 device nodes"

        # Verify creation
        ls -la /dev/mmcblk0* 2>/dev/null | while read line; do
            einfo "  $line"
        done
    fi

    eend 0
}
EOF
    chmod +x "${apkovl_dir}/etc/init.d/qemu-device-setup"

    mkdir -p "${apkovl_dir}/etc/runlevels/default"
    ln -sf /etc/init.d/qemu-device-setup "${apkovl_dir}/etc/runlevels/default/qemu-device-setup"
}

# Start a VM
start_vm() {
    local node_name="$1"
    local node_ip="$2"
    local role="$3"

    local mac_addr
    mac_addr=$(generate_mac "$node_name")

    local data_disk
    data_disk=$(create_data_disk "$node_name")

    local overlay_dir
    overlay_dir=$(prepare_overlay "$node_name" "$node_ip" "$role")

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

    # Port forwarding for host access (via user netdev, separate from cluster network)
    local last_octet
    last_octet=$(echo "$node_ip" | cut -d. -f4)
    local ssh_port=$((2200 + last_octet))
    local api_fwd=""

    if [ "$role" = "master" ]; then
        api_fwd=",hostfwd=tcp::6443-:6443"
    fi

    echo "Host access (via eth1):"
    echo "  SSH: ssh root@localhost -p $ssh_port"
    if [ "$role" = "master" ]; then
        echo "  k3s API: localhost:6443"
    fi
    echo ""
    echo "Cluster network: eth0 = $node_ip (VM-to-VM)"
    echo ""

    cd "$VM_DIR"

    # Kernel command line with cgroups for k3s
    local kernel_cmd="modules=loop,squashfs,sd-mod,usb-storage quiet console=ttyS0,115200 cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset"

    # Network setup:
    # - eth0: socket network for VM-to-VM cluster (server listens, workers connect)
    # - eth1: user mode for host access with port forwarding (DHCP)
    local cluster_netdev
    if [ "$role" = "master" ]; then
        # Server listens for connections
        cluster_netdev="socket,id=cluster,listen=:${SOCKET_PORT}"
        echo "Cluster network: Server listening on port $SOCKET_PORT"
    else
        # Workers connect to server
        cluster_netdev="socket,id=cluster,connect=127.0.0.1:${SOCKET_PORT}"
        echo "Cluster network: Connecting to server on port $SOCKET_PORT"
    fi

    qemu-system-x86_64 \
        -name "$node_name" \
        -m "$RAM_SIZE" \
        -kernel vmlinuz-virt \
        -initrd initramfs-virt \
        -append "$kernel_cmd" \
        -cdrom "alpine-virt-${ALPINE_VERSION}-x86_64.iso" \
        -drive "file=$data_disk,format=qcow2" \
        -drive "file=fat:rw:$overlay_dir,format=raw" \
        -netdev "$cluster_netdev" \
        -device "virtio-net-pci,netdev=cluster,mac=$mac_addr" \
        -netdev "user,id=hostnet,hostfwd=tcp::${ssh_port}-:22${api_fwd}" \
        -device "virtio-net-pci,netdev=hostnet" \
        -display none \
        -serial mon:stdio
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
        setup_vm_environment
        master_node=$(get_master_node)
        master_ip=$(get_master_ip)
        start_vm "$master_node" "$master_ip" "master"
        ;;

    worker)
        if [ -z "${2:-}" ]; then
            echo "ERROR: Node name required for worker"
            echo "Usage: $0 worker <node-name>"
            echo ""
            echo "Available worker nodes:"
            # yaml_get_nodes returns lines in format: name:ip:role
            # Show test subnet IPs
            while IFS=: read -r node ip role; do
                if [ "$role" = "worker" ]; then
                    echo "  $node ($(prod_ip_to_test_ip "$ip"))"
                fi
            done < <(yaml_get_nodes)
            exit 1
        fi

        node_name="$2"
        node_ip=$(get_node_ip "$node_name")
        node_role=$(get_node_role "$node_name")

        if [ -z "$node_ip" ]; then
            echo "ERROR: Node '$node_name' not found in config"
            exit 1
        fi

        if [ "$node_role" = "master" ]; then
            echo "ERROR: $node_name is a master node, use '$0 server' instead"
            exit 1
        fi

        setup_vm_environment
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
