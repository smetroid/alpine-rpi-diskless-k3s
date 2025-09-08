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
    mkdir -p "${NODE_NAME}-apkovl"/{etc/{network,ssh,runlevels/{default,boot,sysinit},init.d,k3s,local.d,sysctl.d},root/.ssh,var/lib/k3s,usr/local/bin}
    
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
# NOTE: Using noauto to prevent mount failures during initial boot
# Devices are created by 00-test-execution.start script during local.d execution
# k3s_bootstrap will manually mount these as needed
${STORAGE_DEVICE}p1 /media/mmcblk0p1 vfat defaults,noauto 0 0
${STORAGE_DEVICE}p2 $DATA_MOUNT ext4 defaults,noauto 0 0
EOF

    # Create comprehensive Alpine initialization script
    DATA_MOUNT=$(yaml_get "storage.data_mount")
    STORAGE_DEVICE=$(yaml_get "storage.device")
    
    # Create the bootstrap script first
    cat > "${NODE_NAME}-apkovl/usr/local/bin/k3s_bootstrap" << SCRIPT_EOF
#!/bin/sh

# Smart package management functions
_apk() {
    local cmd="\$1"
    local pkg="\$2"
    
    case \$cmd in
        add)
            if ! apk info | grep -wq "\${pkg}"; then
                apk add "\$pkg" && printf '%s ' "\${pkg}" >>/tmp/.trash/k3s_installed
            fi
        ;;
        del)
            if grep -wq "\$pkg" /tmp/.trash/k3s_installed >/dev/null 2>&1; then
                apk del "\$pkg" && sed -i 's/\\b'"\${pkg}"'\\b//' /tmp/.trash/k3s_installed
            fi
        ;;
    esac
}

# File preservation functions
_preserve() {
    [ -z "\${1}" ] && return 1
    [ -e "\${1}" ] && cp -a "\${1}" "\${1}".orig
}

_restore() {
    [ -z "\${1}" ] && return 1
    rm -rf "\${1}"
    [ -e "\${1}".orig ] && mv -f "\${1}".orig "\${1}"
}

# Robust logger function that handles missing syslog
_logger() {
    local msg="$*"
    # Try logger first, fallback to echo if syslog not available
    if logger -st "k3s-bootstrap" "$msg" 2>/dev/null; then
        :  # Success
    else
        echo "[k3s-bootstrap] $msg" >&2
    fi
}

_logger "Alpine diskless k3s initialization starting"
echo "=============================================="
echo "🚀 Alpine Diskless k3s Node Initialization"
echo "Node: \$(cat /etc/hostname 2>/dev/null || echo 'unknown')"
echo "Time: \$(date)"
echo "=============================================="

# Create trash directory for tracking
mkdir -p /tmp/.trash

# Wait for system to stabilize
echo "⏳ Waiting for system to stabilize..."
sleep 10

# Check if this is first boot or if we need to do full initialization
FIRST_BOOT=false
if [ ! -f $DATA_MOUNT/.k3s-initialized ]; then
    FIRST_BOOT=true
fi

# Install required packages using smart package management
echo "📦 Installing required packages..."
_apk add e2fsprogs

# Load required kernel modules for k3s networking
echo "🔧 Loading kernel modules for k3s..."
modprobe bridge 2>/dev/null || echo "⚠️  Bridge module not available"
modprobe br_netfilter 2>/dev/null || echo "⚠️  br_netfilter module not available"

# Ensure bridge netfilter proc entries exist
if [ -d /proc/sys/net/bridge ]; then
    echo "✅ Bridge networking configured"
else
    echo "⚠️  Bridge networking not available - k3s may have limited functionality"
fi

# Check for storage device
echo "🔍 Checking for storage device $STORAGE_DEVICE..."
if [ ! -b "$STORAGE_DEVICE" ]; then
    echo "❌ Storage device $STORAGE_DEVICE not found"
    echo "Available devices:"
    ls -la /dev/mmc* /dev/sd* 2>/dev/null || echo "No storage devices found"
    exit 1
fi
echo "✅ Storage device found"

# Verify data partition exists (should be created by setup-sd-card.sh)
echo "🔧 Verifying data partition..."
if [ ! -b "${STORAGE_DEVICE}p2" ]; then
    echo "❌ Data partition ${STORAGE_DEVICE}p2 not found"
    echo "💡 Run setup-sd-card.sh first to create the partition layout"
    echo "Available partitions:"
    ls -la ${STORAGE_DEVICE}* 2>/dev/null || echo "No partitions found"
    exit 1
fi
echo "✅ Data partition verified"

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

# Check if this is first boot (now that storage is mounted)
if [ ! -f $DATA_MOUNT/.k3s-initialized ]; then
    FIRST_BOOT=true
    echo "🆕 First boot detected - performing full initialization"
else
    FIRST_BOOT=false
    echo "🔄 Subsequent boot - performing quick setup"
fi

# Create directories only on first boot
if [ "\$FIRST_BOOT" = "true" ]; then
    echo "📂 Creating directories..."
    mkdir -p $DATA_MOUNT/k3s $DATA_MOUNT/etc-persistent $DATA_MOUNT/var-lib-k3s
    
    # Mark initialization as complete
    echo "✅ First boot initialization complete at \$(date)" > $DATA_MOUNT/.k3s-initialized
else
    echo "📂 Directories already exist"
fi

# Set up bind mounts (always needed)
echo "🔗 Setting up bind mounts..."
mkdir -p /etc/k3s /var/lib/k3s

# Idempotent bind mounts - only mount if not already mounted
if ! mountpoint -q /etc/k3s 2>/dev/null; then
    echo "📎 Mounting /etc/k3s..."
    mount --bind $DATA_MOUNT/k3s /etc/k3s
else
    echo "✅ /etc/k3s already mounted"
fi

if ! mountpoint -q /var/lib/k3s 2>/dev/null; then
    echo "📎 Mounting /var/lib/k3s..."
    mount --bind $DATA_MOUNT/var-lib-k3s /var/lib/k3s
else
    echo "✅ /var/lib/k3s already mounted"
fi

# Install k3s if not present
echo "🚀 Installing k3s..."
if [ ! -f /usr/local/bin/k3s ]; then
    _logger "Downloading and installing k3s"
    echo "📥 Downloading k3s..."
    wget -qO- https://get.k3s.io | sh -
    if [ \$? -eq 0 ]; then
        echo "✅ k3s installed successfully"
        _logger "k3s installation completed successfully"
    else
        echo "❌ k3s installation failed"
        _logger "k3s installation failed"
        exit 1
    fi
else
    echo "✅ k3s already installed"
fi

# Start k3s service
echo "🔄 Starting k3s service..."
if [ -f /etc/k3s/config.yaml ]; then
    _logger "Starting k3s with configuration"
    rc-service k3s start
    rc-update add k3s default
    echo "✅ k3s service started and enabled"
else
    echo "⚠️ No k3s configuration found - k3s not started"
fi

if [ "\$FIRST_BOOT" = "true" ]; then
    _logger "Alpine k3s first boot initialization complete"
    echo "✅ Alpine k3s first boot initialization complete"
else
    _logger "Alpine k3s subsequent boot setup complete"
    echo "✅ Alpine k3s subsequent boot setup complete"
fi
echo "=============================================="

# Create cleanup script for service removal
cat > /tmp/.trash/k3s_cleanup << 'CLEANUP_EOF'
#!/bin/sh
_logger() { logger -st "k3s-cleanup"; }

_logger "Starting k3s bootstrap cleanup..."

# Remove installed packages
if [ -f /tmp/.trash/k3s_installed ]; then
    while read -r pkg; do
        [ -n "\$pkg" ] && apk del "\$pkg"
    done < /tmp/.trash/k3s_installed
fi

# Remove bootstrap files
rm -f /usr/local/bin/k3s_bootstrap
rm -f /etc/init.d/k3s-bootstrap
rm -f /etc/runlevels/default/k3s-bootstrap

_logger "k3s bootstrap cleanup complete"
CLEANUP_EOF
chmod +x /tmp/.trash/k3s_cleanup

exit 0
SCRIPT_EOF
    chmod +x "${NODE_NAME}-apkovl/usr/local/bin/k3s_bootstrap"
    
    # Add services to default runlevel
    mkdir -p "${NODE_NAME}-apkovl/etc/runlevels/default"
    # CRITICAL: Enable local service so that local.d scripts execute
    ln -sf /etc/init.d/local "${NODE_NAME}-apkovl/etc/runlevels/default/local"
    
    # Create diagnostic script and fallback local.d bootstrap
    cat > "${NODE_NAME}-apkovl/etc/local.d/00-test-execution.start" << 'EOF'
#!/bin/sh
# Test execution and QEMU device simulation script

# Enhanced logger functions
_log() { echo "$*" | tee -a /var/log/messages 2>/dev/null || echo "$*"; }
_success() { echo "✅ $*" | tee -a /var/log/messages 2>/dev/null || echo "✅ $*"; }
_error() { echo "❌ $*" | tee -a /var/log/messages 2>/dev/null || echo "❌ $*"; }

_log "=== DIAGNOSTIC: local.d scripts ARE executing ==="
_log "=== DIAGNOSTIC: Time: $(date) ==="
_log "=== DIAGNOSTIC: Hostname: $(hostname) ==="
_log "=== DIAGNOSTIC: Available services: $(rc-status -a 2>/dev/null | wc -l) ==="

# QEMU Detection and Device Simulation
_log "=== QEMU DETECTION AND DEVICE SETUP ==="

# Check if we're running in QEMU (look for QEMU-specific devices)
QEMU_DETECTED=false
if [ -b /dev/sda ] || [ -b /dev/vda ] || grep -q "QEMU" /proc/cpuinfo 2>/dev/null; then
    QEMU_DETECTED=true
    _log "🖥️  QEMU environment detected - setting up device simulation"
fi

if [ "$QEMU_DETECTED" = "true" ]; then
    # Determine which storage device is available
    STORAGE_DEV=""
    if [ -b /dev/sda ]; then
        STORAGE_DEV="/dev/sda"
        _log "Using /dev/sda for storage simulation"
    elif [ -b /dev/vda ]; then
        STORAGE_DEV="/dev/vda" 
        _log "Using /dev/vda for storage simulation"
    fi
    
    if [ -n "$STORAGE_DEV" ]; then
        _success "Storage device: $STORAGE_DEV detected"
        
        # Check for reboot detection - look for system initialization marker
        SYSTEM_INITIALIZED=false
        mkdir -p /tmp/mnt_check 2>/dev/null || true
        
        # Try to mount data partition to check for initialization marker
        if mount -t ext4 "${STORAGE_DEV}2" /tmp/mnt_check 2>/dev/null; then
            if [ -f "/tmp/mnt_check/.system-initialized" ]; then
                SYSTEM_INITIALIZED=true
                _log "🔄 System reboot detected - initialization marker found"
            fi
            umount /tmp/mnt_check 2>/dev/null || true
        fi
        
        if [ "$SYSTEM_INITIALIZED" = "false" ]; then
            # First boot - partition the storage device to simulate SD card
            _log "🆕 First boot detected - setting up storage partitions (simulating Pi SD card)..."
            (echo n; echo p; echo 1; echo; echo +256M; echo n; echo p; echo 2; echo; echo; echo t; echo 1; echo c; echo w) | fdisk "$STORAGE_DEV" >/dev/null 2>&1 || true
            sleep 2
            
            # Ensure kernel recognizes partitions
            partprobe "$STORAGE_DEV" 2>/dev/null || true
            sleep 1
            
            # Format the data partition
            _log "Formatting data partition..."
            mkfs.ext4 -F "${STORAGE_DEV}2" >/dev/null 2>&1 || true
            
            # Mount and create initialization marker
            if mount -t ext4 "${STORAGE_DEV}2" /tmp/mnt_check 2>/dev/null; then
                echo "$(date): System initialized on first boot" > /tmp/mnt_check/.system-initialized
                umount /tmp/mnt_check 2>/dev/null || true
                _success "System initialization marker created"
            fi
        else
            _log "🔄 Reboot detected - skipping partitioning, ensuring device nodes exist"
        fi
        
        # Always ensure device nodes exist (needed for both first boot and reboots)
        _log "Creating/ensuring Raspberry Pi device simulation..."
        if [ -b "${STORAGE_DEV}1" ] && [ -b "${STORAGE_DEV}2" ]; then
            mknod /dev/mmcblk0 b $(stat -c "%t %T" "$STORAGE_DEV") 2>/dev/null || true
            mknod /dev/mmcblk0p1 b $(stat -c "%t %T" "${STORAGE_DEV}1") 2>/dev/null || true
            mknod /dev/mmcblk0p2 b $(stat -c "%t %T" "${STORAGE_DEV}2") 2>/dev/null || true
            _success "Raspberry Pi SD card simulation: /dev/mmcblk0 (/dev/mmcblk0p1, /dev/mmcblk0p2)"
        else
            # Fallback device creation with fixed major/minor numbers
            _log "Partitions not detected, using fallback device creation..."
            mknod /dev/mmcblk0 b $(stat -c "%t %T" "$STORAGE_DEV") 2>/dev/null || true
            mknod /dev/mmcblk0p1 b 8 1 2>/dev/null || true
            mknod /dev/mmcblk0p2 b 8 2 2>/dev/null || true
            _success "SD card devices created (fallback method)"
        fi
        
        # Verify device creation
        _log "Verifying created devices:"
        ls -la /dev/mmcblk0* 2>/dev/null | while IFS= read -r line; do
            _log "  $line"
        done
        
        # Cleanup temporary mount point
        rmdir /tmp/mnt_check 2>/dev/null || true
    else
        _error "No suitable storage device found for QEMU simulation"
    fi
else
    _log "🥧 Real Raspberry Pi environment detected - using native mmcblk0 devices"
fi

_log "=== DEVICE SETUP COMPLETE ==="
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/local.d/00-test-execution.start"
    
    # Create k3s bootstrap using local.d (simplified approach)
    cat > "${NODE_NAME}-apkovl/etc/local.d/10-k3s-bootstrap.start" << 'EOF'
#!/bin/sh

# Simple logger function
_log() { echo "$*" | tee -a /var/log/messages 2>/dev/null || echo "$*"; }

# k3s bootstrap using local.d
_log "=== Starting k3s bootstrap via local.d ==="

# Check if bootstrap has already run successfully
if [ -f /mnt/data/.k3s-bootstrap-complete ]; then
    _log "k3s bootstrap already completed - skipping"
    exit 0
fi

# Run the bootstrap script
if [ -x /usr/local/bin/k3s_bootstrap ]; then
    _log "Running k3s bootstrap for the first time..."
    # Pipe bootstrap output to both stdout and syslog
    if /usr/local/bin/k3s_bootstrap 2>&1 | while IFS= read -r line; do
        _log "$line"
    done; then
        # Mark bootstrap as complete only on successful execution
        mkdir -p /mnt/data 2>/dev/null || true
        echo "$(date): k3s bootstrap completed successfully" > /mnt/data/.k3s-bootstrap-complete
        _log "k3s bootstrap completed successfully - marked as complete"
    else
        _log "k3s bootstrap failed - will retry on next boot"
        exit 1
    fi
else
    _log "=== ERROR: k3s_bootstrap script not found ==="
    exit 1
fi
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/local.d/10-k3s-bootstrap.start"
    
    # Create simple console notification (no longer needed with proper OpenRC service)
    # The k3s-bootstrap service handles all console output
    
    # Create periodic save script for additional persistent data
    cat > "${NODE_NAME}-apkovl/etc/local.d/20-save-persistent.start" << EOF
#!/bin/sh

# Simple logger function
_log() { echo "\$*" | tee -a /var/log/messages 2>/dev/null || echo "\$*"; }

_log "=== Setting up persistent data saves ==="

# Save additional persistent etc files (k3s data is already bind-mounted)
mkdir -p $DATA_MOUNT/etc-persistent
cp /etc/hostname $DATA_MOUNT/etc-persistent/ 2>/dev/null || true
cp /etc/resolv.conf $DATA_MOUNT/etc-persistent/ 2>/dev/null || true

# Create a cron job for periodic saves (every 5 minutes)
echo "*/5 * * * * cp /etc/hostname /etc/resolv.conf $DATA_MOUNT/etc-persistent/ 2>/dev/null && sync" | crontab - 2>/dev/null || true

# Initial sync
sync

_log "=== Persistent data save setup complete ==="
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/local.d/20-save-persistent.start"

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