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
# Production configs (k3s.yaml.example, cluster-*.yaml) -> builds/
# Testing configs (qemu.yaml.example, *-test.yaml, *-qemu.yaml) -> builds-qemu/
determine_build_dir() {
    local config_basename
    config_basename="$(basename "${CONFIG_FILE}")"

    case "$config_basename" in
        qemu.yaml|qemu.yaml.example|*-test.yaml|*-qemu.yaml|*-test.yaml.example|*-qemu.yaml.example)
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

# Step 3: Generate Kubernetes manifests from YAML (including OpenWrt if gateway)
echo ""
echo "Step 3: Generating Kubernetes manifests from YAML..."
"$SCRIPT_DIR/generate-manifests-yaml.sh"

# Step 4: Finalize apkovl structure
echo ""
echo "Step 4: Finalizing apkovl structure..."

# Load template renderer
_templates_root="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$LIB_DIR/templates.sh"

yq e '.nodes[] | .name + ":" + (.ip // (.interfaces.lan.ip // "" | split("/")[0])) + ":" + .role' "$CONFIG_FILE" | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    echo "Finalizing apkovl for $NODE_NAME..."
    
    # Get Alpine packages from config
    ALPINE_PACKAGES=()
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && ALPINE_PACKAGES+=("$_line")
    done < <(yq e '.alpine.packages[]' "$CONFIG_FILE" 2>/dev/null)
    
    # Build APK install block for template
    APK_INSTALL_BLOCK=""
    for pkg in "${ALPINE_PACKAGES[@]}"; do
        APK_INSTALL_BLOCK="${APK_INSTALL_BLOCK}_apk add ${pkg}
"
    done

    # Get timezone from config
    ALPINE_TIMEZONE=$(yq e '.alpine.timezone // ""' "$CONFIG_FILE")

    # Export vars for template rendering
    export APK_INSTALL_BLOCK ALPINE_TIMEZONE

    # Generate thin OpenRC wrapper (calls /usr/local/bin/system_bootstrap)
    render_template "openrc/system-bootstrap.tmpl" "${NODE_NAME}-apkovl/etc/init.d/system-bootstrap"
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/system-bootstrap"

    # Generate inner bootstrap script placed in overlay at build time
    mkdir -p "${NODE_NAME}-apkovl/usr/local/bin"
    render_template "scripts/system-bootstrap-inner.tmpl" "${NODE_NAME}-apkovl/usr/local/bin/system_bootstrap"
    chmod +x "${NODE_NAME}-apkovl/usr/local/bin/system_bootstrap"

    # Generate LBU commit runtime script
    render_template "scripts/lbu-commit-runtime.sh" "${NODE_NAME}-apkovl/usr/local/bin/lbu-commit-runtime"
    chmod +x "${NODE_NAME}-apkovl/usr/local/bin/lbu-commit-runtime"

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

cluster_name=$(yq e '.cluster.name // ""' "$CONFIG_FILE")
echo "Cluster: $cluster_name"

echo ""
echo "Files created:"
NODE_COUNT=$(yq e '.nodes | length' "$CONFIG_FILE")
for (( NODE_IDX=0; NODE_IDX<NODE_COUNT; NODE_IDX++ )); do
    NODE_NAME=$(yq e ".nodes[$NODE_IDX].name" "$CONFIG_FILE")
    NODE_ROLE=$(yq e ".nodes[$NODE_IDX].role" "$CONFIG_FILE")
    if yq e ".nodes[$NODE_IDX].interfaces" "$CONFIG_FILE" 2>/dev/null | grep -qv null; then
        NODE_IP=$(yq e ".nodes[$NODE_IDX].interfaces.lan.ip" "$CONFIG_FILE")
    else
        NODE_IP=$(yq e ".nodes[$NODE_IDX].ip" "$CONFIG_FILE")
    fi
    echo "  - ${NODE_NAME}.apkovl.tar.gz ($NODE_ROLE node - $NODE_IP)"
done

if [ -f "k3s-token.txt" ]; then
    echo "  - k3s-token.txt (Cluster join token)"
fi

echo "  - k3s-manifests/ (Kubernetes manifests)"
echo ""

NET_SUBNET=$(yq e '.network.subnet // ""' "$CONFIG_FILE")
NET_VIP=$(yq e '.network.vip // ""' "$CONFIG_FILE" 2>/dev/null || true)
if [ -n "$NET_VIP" ]; then
    echo "  VIP: $NET_VIP (gateway mode — cluster IS the gateway)"
    echo "  LAN Subnet: $(yq e '.network.lan_subnet' "$CONFIG_FILE")"
else
    echo "  Network: $NET_SUBNET, Gateway: $(yq e '.network.gateway // ""' "$CONFIG_FILE")"
fi
DNS_UPSTREAM=$(yq e '.network.dns_upstream[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' ' ')
if [ -n "$DNS_UPSTREAM" ]; then
    echo "  DNS Upstream: $DNS_UPSTREAM"
else
    echo "  DNS: $(yq e '.network.dns_servers[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' ' ')"
fi

if [ "$(yq e '.services.metallb.enabled // "false"' "$CONFIG_FILE")" = "true" ]; then
    echo "  MetalLB: $(yq e '.network.loadbalancer_pool.start // ""' "$CONFIG_FILE") - $(yq e '.network.loadbalancer_pool.end // ""' "$CONFIG_FILE")"
fi

if [ "$(yq e '.services.nginx_ingress.enabled // "false"' "$CONFIG_FILE")" = "true" ]; then
    echo "  NGINX Ingress: Enabled"
fi

if [ "$(yq e '.services.openwrt.enabled // "false"' "$CONFIG_FILE")" = "true" ]; then
    echo "  OpenWrt: $(yq e '.services.openwrt.image' "$CONFIG_FILE")"
fi

echo ""
echo "Next steps:"
echo "1. Prepare SD cards using: sudo ./scripts/setup-bootable-device.sh /dev/sdX"
echo "2. Copy each .apkovl.tar.gz file to the corresponding SD card boot partition"
echo "3. Insert SD cards and power on nodes (master first, then workers)"
echo "4. Wait 5-10 minutes for complete cluster initialization"
echo ""
echo "Access your cluster:"

# Helper to get node display IP (handles both flat and enriched schemas)
_get_node_display_ip() {
    local idx=$1
    if yq e ".nodes[$idx].interfaces" "$CONFIG_FILE" 2>/dev/null | grep -qv null; then
        yq e ".nodes[$idx].interfaces.lan.ip" "$CONFIG_FILE"
    else
        yq e ".nodes[$idx].ip" "$CONFIG_FILE"
    fi
}

# Determine if this is a QEMU test config
CONFIG_BASENAME="$(basename "$CONFIG_FILE")"
case "$CONFIG_BASENAME" in
    qemu.yaml|qemu.yaml.example|*-test.yaml|*-qemu.yaml|*-test.yaml.example|*-qemu.yaml.example)
        # QEMU testing - show localhost:port access
        for (( NODE_IDX=0; NODE_IDX<NODE_COUNT; NODE_IDX++ )); do
            NODE_NAME=$(yq e ".nodes[$NODE_IDX].name" "$CONFIG_FILE")
            NODE_ROLE=$(yq e ".nodes[$NODE_IDX].role" "$CONFIG_FILE")
            NODE_IP=$(_get_node_display_ip $NODE_IDX)
            NODE_BARE_IP=$(echo "$NODE_IP" | cut -d'/' -f1)
            # Calculate SSH port from IP last octet
            port=$(echo "$NODE_BARE_IP" | cut -d. -f4)
            ssh_port=$((2200 + port))
            echo "  $NODE_ROLE: ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost -p $ssh_port"
        done
        ;;
    *)
        # Production - show direct IP access
        for (( NODE_IDX=0; NODE_IDX<NODE_COUNT; NODE_IDX++ )); do
            NODE_NAME=$(yq e ".nodes[$NODE_IDX].name" "$CONFIG_FILE")
            NODE_ROLE=$(yq e ".nodes[$NODE_IDX].role" "$CONFIG_FILE")
            NODE_IP=$(_get_node_display_ip $NODE_IDX)
            NODE_BARE_IP=$(echo "$NODE_IP" | cut -d'/' -f1)
            echo "  $NODE_ROLE: ssh root@$NODE_BARE_IP"
        done
        ;;
esac

echo ""
echo "Verify deployment: kubectl get nodes -o wide"