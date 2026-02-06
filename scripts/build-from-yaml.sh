#!/bin/bash

# Build complete Alpine diskless k3s setup from YAML configuration

set -e

# Source directory and library directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Get absolute path to config file before changing directories
CONFIG_FILE="${1}"
if [ -n "$CONFIG_FILE" ]; then
    # Convert to absolute path
    CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" 2>/dev/null && pwd)/$(basename "$CONFIG_FILE")"
fi

# Build directory - determine based on config basename
# Production configs (k3s.yaml, cluster-*.yaml) -> builds/
# Testing configs (qemu.yaml, *-test.yaml, *-qemu.yaml) -> builds-qemu/
determine_build_dir() {
    local config_basename
    config_basename="$(basename "${CONFIG_FILE}")"

    case "$config_basename" in
        qemu.yaml|*-test.yaml|*-qemu.yaml)
            echo "builds-qemu"
            ;;
        *)
            echo "builds"
            ;;
    esac
}

BUILD_DIR="${BUILD_DIR:-$(determine_build_dir)}"

echo "=== Alpine Diskless k3s YAML Setup Builder ==="
echo "Using configuration: $CONFIG_FILE"
echo "Building into: $BUILD_DIR"
echo ""

# Export config file for all scripts
export CONFIG_FILE

# Create and change to build directory for output
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Validate configuration first
echo "Step 0: Validating configuration..."
if ! "$SCRIPT_DIR/validate-config.sh" "$CONFIG_FILE"; then
    echo ""
    echo "❌ Configuration validation failed. Please fix the errors and try again."
    exit 1
fi

echo ""
echo "✅ Configuration validation passed!"
echo ""

# Make scripts executable
chmod +x "$SCRIPT_DIR"/*.sh "$LIB_DIR"/*.sh 2>/dev/null || true

# Step 1: Create apkovl structure from YAML
echo "Step 1: Creating apkovl structure from YAML configuration..."
"$SCRIPT_DIR/create-apkovl-yaml.sh"

# Step 2: Setup k3s configurations from YAML
echo ""
echo "Step 2: Setting up k3s configurations from YAML..."
"$SCRIPT_DIR/setup-k3s-yaml.sh"

# Step 3: Generate Kubernetes manifests from YAML
echo ""
echo "Step 3: Generating Kubernetes manifests from YAML..."
"$SCRIPT_DIR/generate-manifests-yaml.sh"

# Step 4: Finalize apkovl structure
echo ""
echo "Step 4: Finalizing apkovl structure..."

# Load YAML configuration
source "$LIB_DIR/yaml-parser.sh"

yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    echo "Finalizing apkovl for $NODE_NAME..."
    
    # Get Alpine packages from config
    ALPINE_PACKAGES=($(get_alpine_packages))
    
    # Create main system initialization script
    cat > "${NODE_NAME}-apkovl/etc/init.d/system-bootstrap" << EOF
#!/sbin/openrc-run

description="Alpine diskless system initialization service"
name="system bootstrap"

depend() {
    need localmount storage-init ssh-persist net
    after localmount storage-init ssh-persist net
    provide system-bootstrap
}

start() {
    # Check if already completed
    if [ -f /mnt/data/.system-initialized ]; then
        einfo "System already initialized - skipping"
        mark_service_started
        return 0
    fi

    # Create the actual system bootstrap script
    cat > /usr/local/bin/system_bootstrap << 'SCRIPT_EOF'
#!/bin/sh

# Smart package management functions
_apk() {
    local cmd="\$1"
    local pkg="\$2"
    
    case \$cmd in
        add)
            if ! apk info | grep -wq "\${pkg}"; then
                apk add "\$pkg" && printf '%s ' "\${pkg}" >>/tmp/.trash/system_installed
            fi
        ;;
    esac
}

# Robust logger function that handles missing syslog
_logger() {
    local msg="$*"
    # Try logger first, fallback to echo if syslog not available
    if logger -st "system-bootstrap" "$msg" 2>/dev/null; then
        :  # Success
    else
        echo "[system-bootstrap] $msg" >&2
    fi
}

# Get k3s version from config for installation
K3S_VERSION="$(yaml_get "cluster.k3s_version" "$CONFIG_FILE")"
# Placeholder for sed replacement below - DO NOT escape this
# We'll replace @@K3S_VERSION@@ with the actual version after heredoc creation

_logger "Starting Alpine diskless system initialization"

# Create trash directory for tracking
mkdir -p /tmp/.trash

# Check if system initialization is already complete (persistent check)
if [ -f /mnt/data/.system-initialized ]; then
    _logger "System already initialized, skipping package installation"
    echo "✅ System already initialized, skipping package installation"
    # Create RAM marker for this boot session
    touch /usr/local/bin/.system-initialized
    exit 0
fi

# Note: /etc/apk/repositories is now created in the overlay during build time
# (see create-apkovl-yaml.sh)

# Update package index
_logger "Updating package index"
apk update

# Install required packages using smart package management
_logger "Installing packages from configuration"
EOF

    # Add packages from YAML config using smart package management
    for pkg in "${ALPINE_PACKAGES[@]}"; do
        echo "_apk add $pkg" >> "${NODE_NAME}-apkovl/etc/init.d/system-bootstrap"
    done
    
    # Get timezone from config
    ALPINE_TIMEZONE=$(get_alpine_timezone)
    
    cat >> "${NODE_NAME}-apkovl/etc/init.d/system-bootstrap" << EOF

# Configure timezone if specified
EOF
    if [ -n "$ALPINE_TIMEZONE" ]; then
        cat >> "${NODE_NAME}-apkovl/etc/init.d/system-bootstrap" << EOF
_logger "Setting timezone to $ALPINE_TIMEZONE"
echo "⏰ Setting timezone to $ALPINE_TIMEZONE..."
setup-timezone -z $ALPINE_TIMEZONE

# Ensure /etc/timezone file is created
if [ ! -f /etc/timezone ]; then
    echo "$ALPINE_TIMEZONE" > /etc/timezone
    _logger "Created /etc/timezone with $ALPINE_TIMEZONE"
fi
EOF
    fi
    
    cat >> "${NODE_NAME}-apkovl/etc/init.d/system-bootstrap" << 'EOF'

# Enable services
_logger "Enabling system services"
echo "⚙️ Enabling system services..."
rc-update add networking boot
rc-update add urandom boot
rc-update add hostname boot
rc-update add sysctl boot
rc-update add modules boot
rc-update add chronyd default
rc-update add cgroups boot

# NOTE: SSH setup is handled by the ssh-persist service (runs on every boot)
# This ensures SSH persists across reboots via persistent storage

rc-update add savecache shutdown

# Mount cgroups for k3s
_logger "Mounting cgroups filesystem"
echo "🔧 Mounting cgroups filesystem..."
# Mount cgroup v2 hierarchy (unified) with backwards compatibility
if ! mountpoint -q /sys/fs/cgroup; then
    mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || {
        # Fallback to cgroup v1 if v2 not available
        mount -t tmpfs cgroup_root /sys/fs/cgroup
        mkdir -p /sys/fs/cgroup/{cpu,cpuacct,memory,devices,freezer,net_cls,blkio}
        for subsystem in cpu cpuacct memory devices freezer net_cls blkio; do
            mount -t cgroup -o ${subsystem} ${subsystem} /sys/fs/cgroup/${subsystem} 2>/dev/null || true
        done
    }
    echo "✅ Cgroups mounted"
else
    echo "✅ Cgroups already mounted"
fi

# Configure LBU (Local Backup Utility)
cat > /etc/lbu/lbu.conf << 'LBU_CONF_EOF'
LBU_BACKUPDIR=/mnt/data
LBU_CONF_EOF

# Create a wrapper script for lbu commit with custom naming
# NOTE: This is a minimal config-only backup. Large data is persisted via bind mounts:
#   - /var/lib/rancher/k3s -> /mnt/data/var-lib-rancher-k3s
#   - /etc/k3s -> /mnt/data/k3s
#   - SSH keys -> /mnt/data/ssh (via ssh-persist service)
#   - APK packages -> /mnt/data/apk-cache (via symlink)
cat > /usr/local/bin/lbu-commit-runtime << 'LBU_SCRIPT_EOF'
#!/bin/sh
# Minimal config backup script - only saves essential configuration files
# Large data (k3s, containers) is already persisted via bind mounts

HOSTNAME=$(hostname)
BACKUP_FILE="/mnt/data/runtime-${HOSTNAME}.apkovl.tar.gz"
TEMP_DIR="/tmp/runtime-snapshot"

# Ensure /mnt/data is writable
if [ ! -w "/mnt/data" ]; then
    echo "ERROR: /mnt/data is not writable, attempting remount..."
    mount -o remount,rw /mnt/data 2>/dev/null || {
        echo "ERROR: Failed to remount /mnt/data as read-write"
        exit 1
    }
fi

echo "Creating minimal config snapshot..."

# Clean up any previous temp directory
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Only capture essential configuration files (NOT large data dirs)
# These are files that may change at runtime and aren't covered by bind mounts

# /etc - selective capture (skip large/transient dirs)
mkdir -p "$TEMP_DIR/etc"
echo "  📋 Capturing essential /etc configs..."
# Core system config
cp -a /etc/hostname "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/hosts "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/resolv.conf "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/passwd "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/shadow "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/group "$TEMP_DIR/etc/" 2>/dev/null || true
# Network config
cp -a /etc/network "$TEMP_DIR/etc/" 2>/dev/null || true
# SSH config (keys are in /mnt/data/ssh via ssh-persist)
cp -a /etc/ssh "$TEMP_DIR/etc/" 2>/dev/null || true
# APK config
cp -a /etc/apk "$TEMP_DIR/etc/" 2>/dev/null || true
# Init scripts and runlevels
cp -a /etc/init.d "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/runlevels "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/local.d "$TEMP_DIR/etc/" 2>/dev/null || true
# LBU config
cp -a /etc/lbu "$TEMP_DIR/etc/" 2>/dev/null || true
# Timezone
cp -a /etc/timezone "$TEMP_DIR/etc/" 2>/dev/null || true
cp -a /etc/localtime "$TEMP_DIR/etc/" 2>/dev/null || true
# Machine ID (required for k3s/containerd node identification)
cp -a /etc/machine-id "$TEMP_DIR/etc/" 2>/dev/null || true

# /root/.ssh - authorized keys
if [ -d /root/.ssh ]; then
    echo "  🔑 Capturing /root/.ssh..."
    mkdir -p "$TEMP_DIR/root"
    cp -a /root/.ssh "$TEMP_DIR/root/" 2>/dev/null || true
fi

# Create the runtime snapshot tarball
cd "$TEMP_DIR"
if tar -czf "$BACKUP_FILE" . 2>/dev/null; then
    echo "✅ Runtime config saved: $BACKUP_FILE"
    # Verify the archive
    if tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
        ARCHIVE_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        FILE_COUNT=$(tar -tzf "$BACKUP_FILE" | wc -l)
        echo "   Size: $ARCHIVE_SIZE ($FILE_COUNT files)"
        sync
    else
        echo "⚠️  Warning: Archive verification failed, removing corrupted file"
        rm -f "$BACKUP_FILE"
    fi
else
    echo "❌ ERROR: Failed to create config backup"
    cd /
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Cleanup
cd /
rm -rf "$TEMP_DIR"

echo "Config snapshot complete"
LBU_SCRIPT_EOF
chmod +x /usr/local/bin/lbu-commit-runtime

# Configure what files LBU should include in backups
cat > /etc/lbu/include << 'LBU_EOF'
etc/hostname
etc/hosts
etc/resolv.conf
etc/network/interfaces
etc/ssh
etc/apk/repositories
etc/modules
etc/sysctl.d/*
etc/timezone
etc/localtime
etc/machine-id
etc/k3s
etc/init.d/k3s
etc/runlevels/default/k3s
etc/lbu/lbu.conf
etc/init.d/qemu-device-setup
etc/runlevels/default/qemu-device-setup
etc/init.d/usb-device-setup
etc/runlevels/default/usb-device-setup
etc/init.d/dynamic-network
etc/runlevels/default/dynamic-network
etc/init.d/lbu-restore
etc/runlevels/default/lbu-restore
etc/init.d/lbu-persist
etc/runlevels/default/lbu-persist
root/.ssh/authorized_keys
LBU_EOF

# NOTE: SSH authorized_keys persistence is handled by ssh-persist service

# Mark system initialization as complete (both RAM and persistent storage)
touch /usr/local/bin/.system-initialized
touch /mnt/data/.system-initialized

_logger "System initialization complete"
echo "✅ System: Packages and timezone configured" > /dev/console

# Commit the overlay to save installed packages with runtime prefix
lbu-commit-runtime

# === k3s Startup ===
echo "=============================================="
echo "🚀 k3s Startup"
echo "=============================================="

# Wait briefly for system to stabilize
echo "⏳ Waiting for system to stabilize..."
sleep 2

# Verify that storage-init service has completed
if [ ! -f /mnt/data/.storage-init-complete ]; then
    echo "❌ Storage initialization not completed. storage-init service should run first."
    _logger "Storage initialization not complete, cannot start k3s"
    exit 1
fi
echo "✅ Disk setup verified - storage is ready"

# Verify k3s binary exists (should be in apkovl)
if [ ! -x /usr/local/bin/k3s ]; then
    echo "❌ k3s binary not found at /usr/local/bin/k3s"
    _logger "k3s binary not found - was it included in apkovl?"
    exit 1
fi
echo "✅ k3s binary found"

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

# Note: k3s bind mounts (/etc/rancher/k3s, /var/lib/rancher/k3s) are set up by storage-init service

# Start chronyd for time synchronization (SSL certificates require correct time)
echo "⏰ Starting chronyd for time synchronization..."
rc-service chronyd start 2>/dev/null || {
    echo "⚠️  Failed to start chronyd"
    _logger "Failed to start chronyd"
}

# Wait briefly for time sync (don't block boot if chrony is slow)
echo "⏳ Waiting briefly for time sync..."
sleep 3
chronyc makestep 2>/dev/null || true
echo "📅 Current time: $(date)"

# Start k3s service
echo "🔄 Starting k3s service..."
if [ -f /etc/rancher/k3s/config.yaml ]; then
    _logger "Starting k3s with configuration"

    # Check if this is a worker node (config has server: URL)
    if grep -q "^server:" /etc/rancher/k3s/config.yaml 2>/dev/null; then
        echo "🔧 Worker node detected - k3s will run in agent mode"
    fi

    # Start k3s if not already running
    if ! rc-service k3s status 2>/dev/null | grep -q "started"; then
        rc-service k3s start
        rc-update add k3s default
        echo "✅ k3s service started and enabled"
    else
        echo "✅ k3s service already running"
    fi
else
    echo "⚠️ No k3s configuration found - k3s not started"
fi

_logger "Alpine k3s setup complete"
echo "✅ Alpine k3s setup complete"
echo "=============================================="

exit 0
SCRIPT_EOF
    chmod +x /usr/local/bin/system_bootstrap

    # Run the bootstrap script
    ebegin "Running system bootstrap"
    if /usr/local/bin/system_bootstrap; then
        eend 0 "System bootstrap completed"
        return 0
    else
        eend 1 "System bootstrap failed"
        return 1
    fi
}
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/system-bootstrap"

    # Set up proper service dependencies and runlevels
    mkdir -p "${NODE_NAME}-apkovl/etc/runlevels/default"
    mkdir -p "${NODE_NAME}-apkovl/etc/runlevels/boot"

    # config-restore runs early in boot runlevel (before most services)
    ln -sf /etc/init.d/config-restore "${NODE_NAME}-apkovl/etc/runlevels/boot/config-restore"

    # system-bootstrap runs in default runlevel (after config-restore)
    ln -sf /etc/init.d/system-bootstrap "${NODE_NAME}-apkovl/etc/runlevels/default/system-bootstrap"

    # config-backup runs after system-bootstrap to backup any changes
    ln -sf /etc/init.d/config-backup "${NODE_NAME}-apkovl/etc/runlevels/default/config-backup"
    
    # No longer need 99-start-services.start since we use proper OpenRC dependencies
    # The k3s service will start automatically after k3s-installer completes
    
    # Note: apkovl archives will be created by create-apkovl-archives.sh
done

# Step 5: Create apkovl archives
echo ""
echo "Step 5: Creating apkovl archives..."
"$SCRIPT_DIR/create-apkovl-archives.sh" "$CONFIG_FILE"

# Create summary information
echo ""
echo "=== Setup Complete! ==="
echo ""

cluster_name=$(yaml_get "cluster.name")
echo "Cluster: $cluster_name"

echo ""
echo "Files created:"
yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    echo "  - ${NODE_NAME}.apkovl.tar.gz ($NODE_ROLE node - $NODE_IP)"
done

if [ -f "k3s-token.txt" ]; then
    echo "  - k3s-token.txt (Cluster join token)"
fi

echo "  - k3s-manifests/ (Kubernetes manifests)"
echo ""

echo "Configuration Summary:"
echo "  Network: $(yaml_get "network.subnet"), Gateway: $(yaml_get "network.gateway")"
echo "  DNS: $(get_dns_servers | tr '\n' ' ')"

if [ "$(yaml_get "services.metallb.enabled")" = "true" ]; then
    echo "  MetalLB: $(get_metallb_start) - $(get_metallb_end)"
fi

if [ "$(yaml_get "services.nginx_ingress.enabled")" = "true" ]; then
    echo "  NGINX Ingress: Enabled"
fi

echo ""
echo "Next steps:"
echo "1. Prepare SD cards using: sudo ./setup-sd-card.sh /dev/sdX"
echo "2. Copy each .apkovl.tar.gz file to the corresponding SD card boot partition"
echo "3. Insert SD cards and power on nodes (master first, then workers)"
echo "4. Wait 5-10 minutes for complete cluster initialization"
echo ""
echo "Access your cluster:"

# Determine if this is a QEMU test config
CONFIG_BASENAME="$(basename "$CONFIG_FILE")"
case "$CONFIG_BASENAME" in
    qemu.yaml|*-test.yaml|*-qemu.yaml)
        # QEMU testing - show localhost:port access
        yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
            # Calculate SSH port from IP last octet (10.99.0.15 -> 2215)
            port=$(echo "$NODE_IP" | cut -d. -f4)
            ssh_port=$((2200 + port))
            echo "  $NODE_ROLE: ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost -p $ssh_port"
        done
        ;;
    *)
        # Production - show direct IP access
        yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
            echo "  $NODE_ROLE: ssh root@$NODE_IP"
        done
        ;;
esac

echo ""
echo "Verify deployment: kubectl get nodes -o wide"