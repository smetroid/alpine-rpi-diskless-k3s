#!/bin/bash

# Build complete Alpine diskless k3s setup from YAML configuration

set -e

CONFIG_FILE="${1}"

echo "=== Alpine Diskless k3s YAML Setup Builder ==="
echo "Using configuration: $CONFIG_FILE"
echo "Building into: $BUILD_DIR"
echo ""

# Export config file for all scripts
export CONFIG_FILE

# Change to build directory for output
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

# Step 4: Setup persistence (reuse existing script)
echo ""
echo "Step 4: Setting up persistence scripts..."
if [ -f "$SCRIPT_DIR/setup-persistence.sh" ]; then
    # Adapt existing script to work with YAML-generated nodes
    source "$LIB_DIR/yaml-parser.sh"
    yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
        if [ ! -d "${NODE_NAME}-apkovl" ]; then
            echo "Warning: ${NODE_NAME}-apkovl directory not found"
            continue
        fi
        
        # Add Alpine configuration backup script
        # Create OpenRC service for backing up configuration
        cat > "${NODE_NAME}-apkovl/etc/init.d/config-backup" << 'EOF'
#!/sbin/openrc-run

description="Backup Alpine configuration to persistent storage"
name="config backup"

depend() {
    need storage-init system-bootstrap
    after storage-init system-bootstrap
    provide config-backup
}

start() {
    ebegin "Backing up Alpine configuration to persistent storage"
    
    # Wait for storage to be ready
    if [ ! -d /mnt/data ]; then
        eerror "Persistent storage not available at /mnt/data"
        eend 1 "Storage not mounted"
        return 1
    fi
    
    # Create backup directories
    mkdir -p /mnt/data/alpine-backup/{etc,root}
    
    # System configuration
    einfo "Backing up system configuration..."
    cp -f /etc/hostname /mnt/data/alpine-backup/etc/ 2>/dev/null || true
    cp -f /etc/resolv.conf /mnt/data/alpine-backup/etc/ 2>/dev/null || true
    cp -rf /etc/network /mnt/data/alpine-backup/etc/ 2>/dev/null || true
    cp -rf /etc/ssh /mnt/data/alpine-backup/etc/ 2>/dev/null || true
    
    # Root user files - CRITICAL for SSH access
    einfo "Backing up SSH configuration..."
    if [ -d /root/.ssh ]; then
        cp -rf /root/.ssh /mnt/data/alpine-backup/root/ 2>/dev/null || true
        # Verify the backup was successful
        if [ -f /mnt/data/alpine-backup/root/.ssh/authorized_keys ]; then
            einfo "SSH authorized_keys backed up successfully"
        else
            ewarn "SSH authorized_keys backup may have failed"
        fi
    else
        ewarn "No /root/.ssh directory found to backup"
    fi
    
    # K3s configuration
    if [ -d /etc/k3s ]; then
        einfo "Backing up k3s configuration..."
        cp -rf /etc/k3s /mnt/data/alpine-backup/etc/ 2>/dev/null || true
    fi
    
    # Ensure backup timestamp
    echo "$(date): Configuration backup completed" > /mnt/data/alpine-backup/.backup-timestamp
    
    sync
    eend 0 "Configuration backup completed"
}

stop() {
    ebegin "Stopping config backup service"
    eend 0
}
EOF
        chmod +x "${NODE_NAME}-apkovl/etc/init.d/config-backup"
        
        
        # Create OpenRC service for restoring configuration
        cat > "${NODE_NAME}-apkovl/etc/init.d/config-restore" << 'EOF'
#!/sbin/openrc-run

description="Restore Alpine configuration from persistent storage"
name="config restore"

depend() {
    need storage-init
    after storage-init
    before system-bootstrap
    provide config-restore
}

start() {
    ebegin "Restoring Alpine configuration from persistent storage"
    
    # Wait for storage to be ready
    if [ ! -d /mnt/data ]; then
        eerror "Persistent storage not available at /mnt/data"
        eend 1 "Storage not mounted"
        return 1
    fi
    
    if [ -d /mnt/data/alpine-backup ]; then
        einfo "Found configuration backup, restoring..."
        
        # Restore system configuration
        cp -rf /mnt/data/alpine-backup/etc/* /etc/ 2>/dev/null || true
        cp -rf /mnt/data/alpine-backup/root/* /root/ 2>/dev/null || true
        
        # Set proper permissions for SSH
        if [ -f /root/.ssh/authorized_keys ]; then
            chmod 700 /root/.ssh 2>/dev/null || true
            chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
            chown root:root /root/.ssh/authorized_keys 2>/dev/null || true
            einfo "SSH authorized_keys restored and permissions set"
        fi
        
        # Set SSH host key permissions
        chmod 600 /etc/ssh/ssh_host_* 2>/dev/null || true
        
        eend 0 "Configuration restored successfully"
    else
        einfo "No configuration backup found, using overlay defaults"
        eend 0 "Using default configuration"
    fi
}

stop() {
    ebegin "Stopping config restore service"
    eend 0
}
EOF
        chmod +x "${NODE_NAME}-apkovl/etc/init.d/config-restore"
        
        
        # Create additional system configuration files
        cat > "${NODE_NAME}-apkovl/etc/modules" << 'EOF'
# Kernel modules needed for k3s
br_netfilter
overlay
nf_conntrack
xt_conntrack
xt_MASQUERADE
iptable_nat
iptable_filter
ip_tables
EOF

        cat > "${NODE_NAME}-apkovl/etc/sysctl.d/k3s.conf" << 'EOF'
# Kubernetes/k3s sysctl settings
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.overcommit_memory = 1
kernel.panic = 10
kernel.panic_on_oops = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

    done
    echo "✅ Persistence scripts configured"
else
    echo "⚠️  setup-persistence.sh not found, skipping..."
fi

# Step 5: Finalize apkovl structure
echo ""
echo "Step 5: Finalizing apkovl structure..."

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

command="/usr/local/bin/system_bootstrap"
command_background=false

depend() {
    need localmount storage-init ssh-persist
    after localmount storage-init ssh-persist
    before k3s-bootstrap
    provide system-bootstrap
}

start_pre() {
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

# Set up package repositories using version from YAML config
ALPINE_VERSION=\$(echo "$(yaml_get "alpine.version")" | cut -d. -f1,2)
cat > /etc/apk/repositories << REPOS
http://dl-cdn.alpinelinux.org/alpine/v\${ALPINE_VERSION}/main
http://dl-cdn.alpinelinux.org/alpine/v\${ALPINE_VERSION}/community
REPOS

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

# NOTE: SSH setup is handled by the ssh-persist service (runs on every boot)
# This ensures SSH persists across reboots without depending on LBU backup/restore

rc-update add savecache shutdown

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
etc/k3s
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

exit 0
SCRIPT_EOF
    chmod +x /usr/local/bin/system_bootstrap
}
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/system-bootstrap"
    
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
    
    # Wait for system-bootstrap to complete
    ebegin "Waiting for system bootstrap to complete"
    local timeout=300  # 5 minutes max
    local count=0
    while [ $count -lt $timeout ]; do
        if [ -f /usr/local/bin/.system-initialized ]; then
            eend 0 "System bootstrap completed"
            break
        fi
        sleep 1
        count=$((count + 1))
    done
    
    if [ $count -ge $timeout ]; then
        eerror "Timeout waiting for system bootstrap to complete"
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
    
    # Set up proper service dependencies and runlevels
    mkdir -p "${NODE_NAME}-apkovl/etc/runlevels/default"
    mkdir -p "${NODE_NAME}-apkovl/etc/runlevels/boot"
    
    # config-restore runs early in boot runlevel (before most services)
    ln -sf /etc/init.d/config-restore "${NODE_NAME}-apkovl/etc/runlevels/boot/config-restore"
    
    # system-bootstrap runs in default runlevel (after config-restore)
    ln -sf /etc/init.d/system-bootstrap "${NODE_NAME}-apkovl/etc/runlevels/default/system-bootstrap"
    
    # config-backup runs after system-bootstrap to backup any changes
    ln -sf /etc/init.d/config-backup "${NODE_NAME}-apkovl/etc/runlevels/default/config-backup"
    
    # k3s-bootstrap runs after config-backup
    ln -sf /etc/init.d/k3s-bootstrap "${NODE_NAME}-apkovl/etc/runlevels/default/k3s-bootstrap"
    
    # No longer need 99-start-services.start since we use proper OpenRC dependencies
    # The k3s service will start automatically after k3s-installer completes
    
    # Note: apkovl archives will be created by create-apkovl-archives.sh
done

# Step 6: Create apkovl archives
echo ""
echo "Step 6: Creating apkovl archives..."
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

yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    echo "  $NODE_ROLE: ssh root@$NODE_IP"
done

echo ""
echo "Verify deployment: kubectl get nodes -o wide"