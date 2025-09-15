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

    # This fixes the /lib/modules directory missing when booting, in turn breaks the image
    # https://gitlab.alpinelinux.org/alpine/mkinitfs/-/issues/8
    touch "${NODE_NAME}-apkovl/etc/.default_boot_services"
    
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

    # Add SSH authorized keys if provided (overwrite any existing file)
    rm -f "${NODE_NAME}-apkovl/root/.ssh/authorized_keys"
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

# Verify that storage-init service has completed
if [ ! -f $DATA_MOUNT/.storage-init-complete ]; then
    echo "❌ Storage initialization not completed. storage-init service should run first."
    exit 1
fi
echo "✅ Disk setup verified - storage is ready"

# Check if this is first boot
FIRST_BOOT=false
if [ ! -f $DATA_MOUNT/.k3s-initialized ]; then
    FIRST_BOOT=true
    echo "🆕 First boot detected - performing full k3s initialization"
else
    FIRST_BOOT=false
    echo "🔄 Subsequent boot - performing quick k3s setup"
fi

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

# Set up bind mounts (always needed)
echo "🔗 Setting up bind mounts..."
mkdir -p /etc/k3s /var/lib/rancher/k3s

# Ensure persistent k3s directories exist
mkdir -p $DATA_MOUNT/k3s $DATA_MOUNT/var-lib-rancher-k3s

# Copy overlay config to persistent storage if it doesn't exist there
if [ -f /etc/k3s/config.yaml ] && [ ! -f $DATA_MOUNT/k3s/config.yaml ]; then
    echo "📋 Copying overlay k3s config to persistent storage..."
    cp /etc/k3s/config.yaml $DATA_MOUNT/k3s/config.yaml
    echo "✅ k3s config copied to persistent storage"
fi

# Idempotent bind mounts - only mount if not already mounted
if ! mountpoint -q /etc/k3s 2>/dev/null; then
    echo "📎 Mounting /etc/k3s..."
    mount --bind $DATA_MOUNT/k3s /etc/k3s
else
    echo "✅ /etc/k3s already mounted"
fi

if ! mountpoint -q /var/lib/rancher/k3s 2>/dev/null; then
    echo "📎 Mounting /var/lib/rancher/k3s..."
    mount --bind $DATA_MOUNT/var-lib-rancher-k3s /var/lib/rancher/k3s
else
    echo "✅ /var/lib/rancher/k3s already mounted"
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
    # Mark k3s initialization as complete
    echo "\$(date): k3s initialization completed successfully" > $DATA_MOUNT/.k3s-initialized
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
    # CRITICAL: Enable networking service for network connectivity
    ln -sf /etc/init.d/networking "${NODE_NAME}-apkovl/etc/runlevels/default/networking"
    # Enable storage-init service to run before system-bootstrap
    ln -sf /etc/init.d/storage-init "${NODE_NAME}-apkovl/etc/runlevels/default/storage-init"
    # Enable k3s-bootstrap service to run after storage-init
    ln -sf /etc/init.d/k3s-bootstrap "${NODE_NAME}-apkovl/etc/runlevels/default/k3s-bootstrap"
    
    # Note: QEMU test device setup moved to test-alpine-diskless-boot.sh
    
    # Create k3s-bootstrap OpenRC service
    cat > "${NODE_NAME}-apkovl/etc/init.d/k3s-bootstrap" << 'EOF'
#!/sbin/openrc-run

description="k3s cluster bootstrap service"
name="k3s bootstrap"

command="/usr/local/bin/k3s_bootstrap"
command_background=false
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need system-bootstrap
    after system-bootstrap
    provide k3s-bootstrap
}

start_pre() {
    # Check if bootstrap has already run successfully
    if [ -f /mnt/data/.k3s-bootstrap-complete ]; then
        einfo "k3s bootstrap already completed - skipping"
        return 1
    fi
    
    # Wait for storage-init to complete
    ebegin "Waiting for storage initialization to complete"
    local timeout=300  # 5 minutes max
    local count=0
    while [ $count -lt $timeout ]; do
        if [ -f /mnt/data/.storage-init-complete ]; then
            eend 0 "Storage initialization completed"
            break
        fi
        sleep 1
        count=$((count + 1))
    done
    
    if [ $count -ge $timeout ]; then
        eerror "Timeout waiting for disk setup to complete"
        return 1
    fi
    
    # Ensure the k3s_bootstrap script exists
    if [ ! -x /usr/local/bin/k3s_bootstrap ]; then
        eerror "k3s_bootstrap script not found at /usr/local/bin/k3s_bootstrap"
        return 1
    fi
    
    ebegin "Starting k3s bootstrap"
    return 0
}

start() {
    ebegin "Running k3s cluster bootstrap"
    
    # Run the bootstrap script and capture output
    if /usr/local/bin/k3s_bootstrap; then
        # Mark bootstrap as complete only on successful execution
        mkdir -p /mnt/data 2>/dev/null || true
        echo "$(date): k3s bootstrap completed successfully" > /mnt/data/.k3s-bootstrap-complete
        eend 0 "k3s bootstrap completed successfully"
    else
        eend 1 "k3s bootstrap failed - will retry on next boot"
        return 1
    fi
}

stop() {
    ebegin "Stopping k3s bootstrap service"
    # This service doesn't need to be stopped, it's a one-time run
    eend 0
}
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/k3s-bootstrap"
    
    # Create storage-init OpenRC service
    STORAGE_DEVICE=$(yaml_get "storage.device")
    DATA_MOUNT=$(yaml_get "storage.data_mount")
    cat > "${NODE_NAME}-apkovl/etc/init.d/storage-init" << EOF
#!/sbin/openrc-run

description="Storage initialization and persistent storage service"
name="storage init"

depend() {
    need localmount
    after localmount
    before system-bootstrap k3s-bootstrap
    provide storage-init
}

start_pre() {
    # Check if storage initialization has already been completed
    if [ -f /mnt/data/.storage-init-complete ]; then
        einfo "Storage initialization already completed - skipping"
        return 1
    fi
    
    ebegin "Preparing storage initialization"
    return 0
}

start() {
    ebegin "Setting up persistent storage"
    
    # Check for storage device
    einfo "Checking for storage device $STORAGE_DEVICE..."
    if [ ! -b "$STORAGE_DEVICE" ]; then
        eerror "Storage device $STORAGE_DEVICE not found"
        einfo "Available devices:"
        ls -la /dev/mmc* /dev/sd* 2>/dev/null || einfo "No storage devices found"
        eend 1 "Storage device not found"
        return 1
    fi
    einfo "Storage device found"
    
    # Verify data partition exists (should be created by setup-sd-card.sh)
    einfo "Verifying data partition..."
    if [ ! -b "${STORAGE_DEVICE}p2" ]; then
        eerror "Data partition ${STORAGE_DEVICE}p2 not found"
        einfo "Run setup-sd-card.sh first to create the partition layout"
        einfo "Available partitions:"
        ls -la ${STORAGE_DEVICE}* 2>/dev/null || einfo "No partitions found"
        eend 1 "Data partition not found"
        return 1
    fi
    einfo "Data partition verified"
    
    # Format if needed
    if [ -b "${STORAGE_DEVICE}p2" ] && ! blkid ${STORAGE_DEVICE}p2 | grep -q ext4; then
        einfo "Formatting data partition..."
        if mkfs.ext4 -F -L DATA ${STORAGE_DEVICE}p2; then
            einfo "Data partition formatted successfully"
        else
            eend 1 "Failed to format data partition"
            return 1
        fi
    fi
    
    # Mount data partition
    einfo "Mounting persistent storage..."
    mkdir -p $DATA_MOUNT
    if mount ${STORAGE_DEVICE}p2 $DATA_MOUNT; then
        einfo "Storage mounted at $DATA_MOUNT"
    else
        eend 1 "Failed to mount storage"
        return 1
    fi
    
    # Create directories for k3s, APK cache, LBU config, and usr/local/bin
    mkdir -p $DATA_MOUNT/k3s $DATA_MOUNT/etc-persistent $DATA_MOUNT/var-lib-k3s $DATA_MOUNT/var-cache-apk $DATA_MOUNT/etc-lbu $DATA_MOUNT/usr-local-bin
    
    # Set up APK cache bind mount to persistent storage
    if ! mountpoint -q /var/cache/apk 2>/dev/null; then
        einfo "Setting up APK cache on persistent storage"
        mount --bind $DATA_MOUNT/var-cache-apk /var/cache/apk
        eend \$? "APK cache mount"
    fi
    
    # Set up LBU config bind mount to persistent storage
    if ! mountpoint -q /etc/lbu 2>/dev/null; then
        einfo "Setting up LBU config on persistent storage"
        # Copy overlay LBU config to persistent storage if it doesn't exist
        if [ -d /etc/lbu ] && [ ! -f $DATA_MOUNT/etc-lbu/lbu.conf ]; then
            cp -a /etc/lbu/* $DATA_MOUNT/etc-lbu/ 2>/dev/null || true
        fi
        mount --bind $DATA_MOUNT/etc-lbu /etc/lbu
        eend \$? "LBU config mount"
    fi
    
    # Set up /usr/local/bin bind mount to persistent storage
    if ! mountpoint -q /usr/local/bin 2>/dev/null; then
        einfo "Setting up /usr/local/bin on persistent storage"
        # Copy overlay files from /usr/local/bin to persistent storage if they don't exist
        if [ -d /usr/local/bin ]; then
            for file in /usr/local/bin/*; do
                if [ -f "\$file" ] && [ ! -f "$DATA_MOUNT/usr-local-bin/\$(basename "\$file")" ]; then
                    cp -a "\$file" $DATA_MOUNT/usr-local-bin/
                fi
            done
        fi
        mount --bind $DATA_MOUNT/usr-local-bin /usr/local/bin
        eend \$? "/usr/local/bin mount"
    fi
    
    # Mark storage initialization as complete
    echo "\$(date): Storage initialization completed successfully" > $DATA_MOUNT/.storage-init-complete
    
    eend 0 "Persistent storage setup complete"
}

stop() {
    ebegin "Unmounting persistent storage"
    umount $DATA_MOUNT 2>/dev/null || true
    eend 0
}
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/storage-init"
    
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