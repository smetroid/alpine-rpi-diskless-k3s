#!/bin/bash

# Alpine diskless k3s setup script using YAML configuration
# Creates apkovl files for all nodes defined in cluster-config.yaml

set -e

# Use the config file from environment, or from parameter, or default
CONFIG_FILE="${CONFIG_FILE:-${1:-cluster-config.yaml}}"

echo "Creating apkovl structure from YAML configuration..."
echo "Using configuration file: $CONFIG_FILE"

# Check if configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: Configuration file '$CONFIG_FILE' not found"
    echo ""
    echo "Usage: $0 [config_file]"
    echo "Example: $0 my-cluster.yaml"
    echo "Default: $0  (uses cluster-config.yaml)"
    exit 1
fi

# Export config file for yaml-parser
export CONFIG_FILE

# Load YAML parser
source "$LIB_DIR/yaml-parser.sh"

# Validate configuration
echo "Validating configuration..."
if ! validate_config; then
    exit 1
fi

# Get configuration values
CLUSTER_NAME=$(get_cluster_name)
GATEWAY=$(get_network_gateway)
DNS_SERVERS=($(get_dns_servers))
DOMAIN=$(yaml_get "network.domain")

echo "Cluster: $CLUSTER_NAME"
echo "Gateway: $GATEWAY"
echo "DNS: ${DNS_SERVERS[*]}"
echo ""

# Process each node
yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    echo "Creating apkovl for $NODE_NAME ($NODE_IP) - $NODE_ROLE..."
    
    # Create directory structure
    mkdir -p "${NODE_NAME}-apkovl"/{etc/{network,ssh,runlevels/{default,boot,sysinit},init.d,k3s,local.d,sysctl.d},root/.ssh,var/lib/k3s}
    
    # Set hostname
    echo "$NODE_NAME" > "${NODE_NAME}-apkovl/etc/hostname"
    
    # Network configuration - convert CIDR to netmask
    SUBNET=$(yaml_get "network.subnet")
    CIDR_BITS=$(echo "$SUBNET" | cut -d'/' -f2)
    
    # Convert CIDR to netmask (common cases)
    case "$CIDR_BITS" in
        24) NETMASK="255.255.255.0" ;;
        16) NETMASK="255.255.0.0" ;;
        8)  NETMASK="255.0.0.0" ;;
        25) NETMASK="255.255.255.128" ;;
        26) NETMASK="255.255.255.192" ;;
        27) NETMASK="255.255.255.224" ;;
        28) NETMASK="255.255.255.240" ;;
        *)  NETMASK="255.255.255.0" ;; # Default to /24
    esac
    
    cat > "${NODE_NAME}-apkovl/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address $NODE_IP
    netmask $NETMASK
    gateway $GATEWAY
    dns-nameservers ${DNS_SERVERS[0]}
    dns-domain $DOMAIN
EOF
    
    # Resolve configuration
    cat > "${NODE_NAME}-apkovl/etc/resolv.conf" << EOF
nameserver ${DNS_SERVERS[0]}
domain $DOMAIN
search $DOMAIN
EOF
    
    # SSH daemon configuration
    SSH_PORT=$(yaml_get "ssh.port")
    PERMIT_ROOT=$(yaml_get "ssh.permit_root_login")
    PASS_AUTH=$(yaml_get "ssh.password_authentication")
    
    cat > "${NODE_NAME}-apkovl/etc/ssh/sshd_config" << EOF
Port $SSH_PORT
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_dsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePrivilegeSeparation yes
KeyRegenerationInterval 3600
ServerKeyBits 1024
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime 120
PermitRootLogin $([ "$PERMIT_ROOT" = "true" ] && echo "yes" || echo "no")
StrictModes yes
RSAAuthentication yes
PubkeyAuthentication yes
IgnoreRhosts yes
RhostsRSAAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
PasswordAuthentication $([ "$PASS_AUTH" = "true" ] && echo "yes" || echo "no")
X11Forwarding no
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
EOF

    # Add SSH authorized keys if provided
    yaml_get_array "ssh.authorized_keys" | while read -r key; do
        if [ -n "$key" ]; then
            echo "$key" >> "${NODE_NAME}-apkovl/root/.ssh/authorized_keys"
        fi
    done
    
    if [ -f "${NODE_NAME}-apkovl/root/.ssh/authorized_keys" ]; then
        chmod 600 "${NODE_NAME}-apkovl/root/.ssh/authorized_keys"
    fi

    # Create fstab for persistent mounts (use storage device from config)
    STORAGE_DEVICE=$(yaml_get "storage.device" 2>/dev/null || echo "/dev/mmcblk0")
    DATA_MOUNT=$(yaml_get "storage.data_mount" 2>/dev/null || echo "/mnt/data")
    
    cat > "${NODE_NAME}-apkovl/etc/fstab" << EOF
${STORAGE_DEVICE}p1 /media/mmcblk0p1 vfat defaults 0 0
${STORAGE_DEVICE}p2 $DATA_MOUNT ext4 defaults 0 0
EOF

    # Create mount script for persistent storage
    DATA_MOUNT=$(yaml_get "storage.data_mount")
    STORAGE_DEVICE=$(yaml_get "storage.device")
    
    cat > "${NODE_NAME}-apkovl/etc/local.d/mount-storage.start" << EOF
#!/bin/sh

# Wait for SD card to be available and kernel to settle
echo "Waiting for storage device to be ready..."
sleep 5

# Ensure the main device exists
if [ ! -b "$STORAGE_DEVICE" ]; then
    echo "Error: Storage device $STORAGE_DEVICE not found"
    exit 1
fi

# Check if data partition exists and create if needed
if ! blkid ${STORAGE_DEVICE}p2 >/dev/null 2>&1; then
    echo "Data partition not found, creating..."
    
    # Use parted for more reliable partition creation
    if command -v parted >/dev/null 2>&1; then
        # Get the end of partition 1 to start partition 2 after it
        PART1_END=\$(parted -s $STORAGE_DEVICE print | awk '/^ 1/ {print \$4}' | sed 's/[^0-9.]//g')
        if [ -n "\$PART1_END" ]; then
            PART2_START="\${PART1_END}MiB"
        else
            PART2_START="513MiB"
        fi
        
        echo "Creating data partition starting at \$PART2_START..."
        parted -s $STORAGE_DEVICE mkpart primary ext4 "\$PART2_START" 100%
    else
        # Fallback to fdisk if parted not available
        echo "Using fdisk for partition creation..."
        echo -e "n\\np\\n2\\n\\n\\nw" | fdisk $STORAGE_DEVICE
    fi
    
    # Wait for kernel to recognize the new partition
    sleep 3
    
    # Re-read partition table
    partprobe $STORAGE_DEVICE 2>/dev/null || true
    sleep 2
fi

# Format data partition if it's not formatted
if ! blkid ${STORAGE_DEVICE}p2 | grep -q ext4; then
    echo "Formatting data partition as ext4..."
    if ! mkfs.ext4 -F -L DATA ${STORAGE_DEVICE}p2; then
        echo "Error: Failed to format data partition"
        exit 1
    fi
    echo "Data partition formatted successfully"
fi

# Create mount point and mount data partition
mkdir -p $DATA_MOUNT
if ! mount ${STORAGE_DEVICE}p2 $DATA_MOUNT; then
    echo "Error: Failed to mount data partition"
    exit 1
fi

echo "Data partition mounted at $DATA_MOUNT"

# Create necessary directories on data partition
mkdir -p $DATA_MOUNT/{k3s,etc-persistent,var-lib-k3s}

# Create bind mount directories and mount persistent directories
mkdir -p /etc/k3s
if mount --bind $DATA_MOUNT/k3s /etc/k3s; then
    echo "Bind mounted k3s configuration directory"
else
    echo "Warning: Failed to bind mount k3s configuration"
fi

mkdir -p /var/lib/k3s
if mount --bind $DATA_MOUNT/var-lib-k3s /var/lib/k3s; then
    echo "Bind mounted k3s data directory"
else
    echo "Warning: Failed to bind mount k3s data"
fi

# Restore persistent etc files if they exist
if [ -d $DATA_MOUNT/etc-persistent ]; then
    echo "Restoring persistent configuration files..."
    cp -r $DATA_MOUNT/etc-persistent/* /etc/ 2>/dev/null || true
fi

echo "Persistent storage setup complete"
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/local.d/mount-storage.start"
    
    # Create save script for persistent data
    cat > "${NODE_NAME}-apkovl/etc/local.d/save-persistent.stop" << EOF
#!/bin/sh

# Save persistent etc files
mkdir -p $DATA_MOUNT/etc-persistent
cp -r /etc/k3s $DATA_MOUNT/etc-persistent/ 2>/dev/null || true
cp /etc/hostname $DATA_MOUNT/etc-persistent/ 2>/dev/null || true
cp /etc/resolv.conf $DATA_MOUNT/etc-persistent/ 2>/dev/null || true

# Sync data
sync
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/local.d/save-persistent.stop"

done

echo ""
echo "✅ Base apkovl structure created for all nodes from YAML configuration"
echo ""
echo "Created apkovl directories:"
yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    if [ -d "${NODE_NAME}-apkovl" ]; then
        echo "  ✅ ${NODE_NAME}-apkovl/ (${NODE_ROLE} - ${NODE_IP})"
    else
        echo "  ❌ ${NODE_NAME}-apkovl/ (failed to create)"
    fi
done

echo ""
echo "Next steps:"
echo "1. Run setup-k3s-yaml.sh $CONFIG_FILE"
echo "2. Run generate-manifests-yaml.sh $CONFIG_FILE"  
echo "3. Run build-from-yaml.sh $CONFIG_FILE (or use individual scripts)"