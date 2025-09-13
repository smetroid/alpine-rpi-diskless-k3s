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
        cat > "${NODE_NAME}-apkovl/etc/local.d/80-backup-config.start" << 'EOF'
#!/bin/sh

# Create persistent backup of Alpine configuration
echo "Backing up Alpine configuration..."

# Wait for storage to be mounted
sleep 10

# Backup important system files
mkdir -p /mnt/data/alpine-backup/{etc,root}

# System configuration
cp -f /etc/hostname /mnt/data/alpine-backup/etc/ 2>/dev/null || true
cp -f /etc/resolv.conf /mnt/data/alpine-backup/etc/ 2>/dev/null || true
cp -rf /etc/network /mnt/data/alpine-backup/etc/ 2>/dev/null || true
cp -rf /etc/ssh /mnt/data/alpine-backup/etc/ 2>/dev/null || true

# Root user files
cp -rf /root/.ssh /mnt/data/alpine-backup/root/ 2>/dev/null || true

# K3s configuration
cp -rf /etc/k3s /mnt/data/alpine-backup/etc/ 2>/dev/null || true

sync
EOF
        chmod +x "${NODE_NAME}-apkovl/etc/local.d/80-backup-config.start"
        
        # Add other persistence scripts...
        cat > "${NODE_NAME}-apkovl/etc/local.d/20-restore-config.start" << 'EOF'
#!/bin/sh

# Restore Alpine configuration from persistent storage
echo "Restoring Alpine configuration..."

if [ -d /mnt/data/alpine-backup ]; then
    # Restore system configuration
    cp -rf /mnt/data/alpine-backup/etc/* /etc/ 2>/dev/null || true
    cp -rf /mnt/data/alpine-backup/root/* /root/ 2>/dev/null || true
    
    # Set proper permissions
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
    chmod 700 /root/.ssh 2>/dev/null || true
    chmod 600 /etc/ssh/ssh_host_* 2>/dev/null || true
fi
EOF
        chmod +x "${NODE_NAME}-apkovl/etc/local.d/20-restore-config.start"
        
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
    need localmount
    after localmount
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

# Check if system initialization is already complete
if [ -f /usr/local/bin/.system-initialized ]; then
    _logger "System already initialized, skipping package installation"
    echo "✅ System already initialized, skipping package installation"
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

log "=== Setting up SSH access ==="

# Install and enable SSH
if ! rc-service sshd status >/dev/null 2>&1; then
    log "Installing OpenSSH..."
    if apk add --no-cache openssh; then
        log "OpenSSH installed successfully"
        
        log "Generating SSH host keys..."
        if ssh-keygen -A; then
            log "SSH host keys generated"
        else
            log "WARNING: Failed to generate SSH host keys"
        fi
        
        log "Enabling SSH service..."
        if rc-update add sshd default && rc-service sshd start; then
            log "SSH service enabled and started"
        else
            log "ERROR: Failed to enable SSH service"
            exit 1
        fi
    else
        log "ERROR: Failed to install OpenSSH"
        exit 1
    fi
else
    log "SSH service is already running"
fi

# Fix SSH OpenSSL version mismatch by ensuring fresh installation
_logger "Setting up SSH with fresh OpenSSL"
echo "🔑 Setting up SSH with fresh OpenSSL..."
apk del openssh-server openssh 2>/dev/null || true
_apk add openssh-server
_apk add openssh

# Generate fresh SSH host keys to avoid OpenSSL version issues
rm -f /etc/ssh/ssh_host_*_key*
# Generate only the key types we use (skip deprecated DSA)
ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N "" -q
ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key -N "" -q  
ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q

# Fix ownership of SSH files (critical for SSH security)
_logger "Fixing SSH file ownership and permissions"
echo "🔐 Setting proper SSH file ownership..."
chown -R root:root /root /etc/ssh
chmod 700 /root/.ssh 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
chmod 600 /etc/ssh/ssh_host_* 2>/dev/null || true

rc-update add sshd default
rc-update add savecache shutdown

# Configure LBU (Local Backup Utility)
lbu_media=/mnt/data
echo "\$lbu_media" > /etc/lbu/lbu.conf

# Mark system initialization as complete
touch /usr/local/bin/.system-initialized

_logger "System initialization complete"
echo "✅ System: Packages and timezone configured" > /dev/console

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
    
    # Add service to default runlevel  
    mkdir -p "${NODE_NAME}-apkovl/etc/runlevels/default"
    ln -sf /etc/init.d/system-bootstrap "${NODE_NAME}-apkovl/etc/runlevels/default/system-bootstrap"
    
    # Enable k3s-bootstrap service to run after system-bootstrap
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