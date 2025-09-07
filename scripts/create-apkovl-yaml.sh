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

    # Create comprehensive Alpine initialization script
    DATA_MOUNT=$(yaml_get "storage.data_mount")
    STORAGE_DEVICE=$(yaml_get "storage.device")
    
    # Create simple but comprehensive Alpine initialization script
    cat > "${NODE_NAME}-apkovl/etc/local.d/10-alpine-k3s-init.start" << EOF
#!/bin/sh

# Alpine Diskless k3s Initialization Script
# This runs via the 'local' service during boot

exec > /dev/console 2>&1
echo "=============================================="
echo "🚀 Alpine Diskless k3s Node Initialization"
echo "Node: \$(cat /etc/hostname 2>/dev/null || echo 'unknown')"
echo "Time: \$(date)"
echo "=============================================="

# Wait for system to stabilize
echo "⏳ Waiting for system to stabilize..."
sleep 10

# Install required packages
echo "📦 Installing required packages..."
apk add --no-cache e2fsprogs parted util-linux

# Check for storage device
echo "🔍 Checking for storage device $STORAGE_DEVICE..."
if [ ! -b "$STORAGE_DEVICE" ]; then
    echo "❌ Storage device $STORAGE_DEVICE not found"
    echo "Available devices:"
    ls -la /dev/mmc* /dev/sd* 2>/dev/null || echo "No storage devices found"
    exit 1
fi
echo "✅ Storage device found"

# Create data partition if needed
echo "🔧 Checking for data partition..."
if [ ! -b "${STORAGE_DEVICE}p2" ]; then
    echo "📝 Creating data partition..."
    # Get the end of partition 1 to calculate start of partition 2
    PART1_END=\$(fdisk -l $STORAGE_DEVICE | awk '/^${STORAGE_DEVICE}p1/ {print \$3}')
    if [ -n "\$PART1_END" ]; then
        PART2_START=\$((PART1_END + 1))
    else
        PART2_START=1048576  # Default: 512MB in sectors
    fi
    echo "Creating partition 2 starting at sector \$PART2_START"
    echo -e "n\\np\\n2\\n\$PART2_START\\n\\nw" | fdisk $STORAGE_DEVICE
    sleep 3
    partprobe $STORAGE_DEVICE 2>/dev/null || true
    sleep 2
    
    # Verify partition was created
    if [ ! -b "${STORAGE_DEVICE}p2" ]; then
        echo "❌ Failed to create data partition"
        exit 1
    fi
fi

# Format if needed
if [ -b "${STORAGE_DEVICE}p2" ] && ! blkid ${STORAGE_DEVICE}p2 | grep -q ext4; then
    echo "💾 Formatting data partition..."
    mkfs.ext4 -F -L DATA ${STORAGE_DEVICE}p2
fi

# Mount data partition
echo "📁 Mounting persistent storage..."
mkdir -p $DATA_MOUNT
if mount ${STORAGE_DEVICE}p2 $DATA_MOUNT; then
    echo "✅ Storage mounted at $DATA_MOUNT"
else
    echo "❌ Failed to mount storage"
    exit 1
fi

# Create directories (fix shell expansion)
echo "📂 Creating directories..."
mkdir -p $DATA_MOUNT/k3s $DATA_MOUNT/etc-persistent $DATA_MOUNT/var-lib-k3s

# Set up bind mounts
echo "🔗 Setting up bind mounts..."
mkdir -p /etc/k3s /var/lib/k3s
mount --bind $DATA_MOUNT/k3s /etc/k3s
mount --bind $DATA_MOUNT/var-lib-k3s /var/lib/k3s

echo "✅ Alpine k3s initialization complete"
echo "=============================================="
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/local.d/10-alpine-k3s-init.start"
    
    # Create console notification script (visible on HDMI)
    cat > "${NODE_NAME}-apkovl/etc/local.d/05-console-notify.start" << 'EOF'
#!/bin/sh
# Show progress on console (HDMI/Serial)
echo "" > /dev/console
echo "=====================================================" > /dev/console
echo "🚀 Alpine Diskless k3s System Starting..." > /dev/console
echo "Node: $(cat /etc/hostname 2>/dev/null || echo 'unknown')" > /dev/console
echo "Time: $(date)" > /dev/console
echo "=====================================================" > /dev/console
echo "📋 Local.d scripts execution order:" > /dev/console
echo "  05-console-notify.start  ← You are here" > /dev/console  
echo "  10-mount-storage.start   → Mounting /mnt/data" > /dev/console
echo "  20-restore-config.start  → Restoring configs" > /dev/console
echo "  30-install-k3s.start     → Installing k3s" > /dev/console
echo "  80-backup-config.start   → Backing up configs" > /dev/console
echo "  99-start-services.start  → Starting services" > /dev/console
echo "=====================================================" > /dev/console
echo "" > /dev/console

# Also log to file
echo "Console notification displayed at $(date)" >> /var/log/console-notify.log
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/local.d/05-console-notify.start"
    
    # Create diagnostic script to test local.d execution
    cat > "${NODE_NAME}-apkovl/etc/local.d/01-test-locald.start" << 'EOF'
#!/bin/sh
echo "=== 01-test-locald.start: Local.d service is working ===" | tee -a /var/log/locald-test.log
date | tee -a /var/log/locald-test.log
echo "Available storage devices:" | tee -a /var/log/locald-test.log
ls -la /dev/mmc* /dev/sd* 2>/dev/null | tee -a /var/log/locald-test.log || echo "No storage devices found" | tee -a /var/log/locald-test.log
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/local.d/01-test-locald.start"
    
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