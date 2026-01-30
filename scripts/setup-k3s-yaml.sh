#!/bin/bash

# K3s configuration setup using YAML configuration

set -e

# Source and library directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(cd "$SCRIPT_DIR/../lib" && pwd)}"

# Use config file from environment if available
CONFIG_FILE="${CONFIG_FILE:-cluster-config.yaml}"
export CONFIG_FILE

# Load YAML parser
source "$LIB_DIR/yaml-parser.sh"

echo "Setting up K3s configuration from YAML..."

# Validate configuration
if ! validate_config; then
    exit 1
fi

# Generate or get k3s token
K3S_TOKEN=$(yaml_get "cluster.token")
if [ -z "$K3S_TOKEN" ]; then
    K3S_TOKEN=$(openssl rand -hex 32)
    echo "Generated K3S_TOKEN: $K3S_TOKEN"
    echo "$K3S_TOKEN" > k3s-token.txt
else
    echo "Using provided K3S_TOKEN from configuration"
    echo "$K3S_TOKEN" > k3s-token.txt
fi

# Get configuration values
CLUSTER_CIDR=$(get_k3s_cluster_cidr)
SERVICE_CIDR=$(get_k3s_service_cidr)
FLANNEL_BACKEND=$(yaml_get "k3s.flannel_backend")
DISABLE_SERVICES=($(yaml_get_array ".k3s.disable_services[]"))

# Get external datastore configuration (optional)
DATASTORE_ENDPOINT=""
if get_datastore_endpoint; then
    DATASTORE_ENDPOINT=$(get_datastore_endpoint)
    DATASTORE_TYPE=$(get_datastore_type)
    echo "Using external datastore (${DATASTORE_TYPE}): $(yaml_get "k3s.datastore.host")"
fi

# Process each node
yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    echo "Setting up K3s configuration for $NODE_NAME ($NODE_ROLE)..."
    
    # Create K3s directory if not exists
    mkdir -p "${NODE_NAME}-apkovl/etc/k3s"
    
    if [ "$NODE_ROLE" = "master" ]; then
        # Master node configuration
        # When using external datastore (PostgreSQL/MySQL), do NOT use cluster-init
        # All servers coordinate via the external datastore instead
        if [ -n "$DATASTORE_ENDPOINT" ]; then
            # HA with external datastore
            cat > "${NODE_NAME}-apkovl/etc/k3s/config.yaml" << EOF
write-kubeconfig-mode: "0644"
bind-address: 0.0.0.0
advertise-address: $NODE_IP
node-ip: $NODE_IP
cluster-cidr: "$CLUSTER_CIDR"
service-cidr: "$SERVICE_CIDR"
flannel-backend: "$FLANNEL_BACKEND"
datastore-endpoint: "$DATASTORE_ENDPOINT"
EOF
            echo "# HA mode: External datastore enabled"
        else
            # Embedded database (SQLite) with cluster-init
            cat > "${NODE_NAME}-apkovl/etc/k3s/config.yaml" << EOF
write-kubeconfig-mode: "0644"
cluster-init: true
bind-address: 0.0.0.0
advertise-address: $NODE_IP
node-ip: $NODE_IP
cluster-cidr: "$CLUSTER_CIDR"
service-cidr: "$SERVICE_CIDR"
flannel-backend: "$FLANNEL_BACKEND"
EOF
            echo "# HA mode: Embedded database with cluster-init"
        fi

        # Add disable services
        if [ ${#DISABLE_SERVICES[@]} -gt 0 ]; then
            echo "disable:" >> "${NODE_NAME}-apkovl/etc/k3s/config.yaml"
            for service in "${DISABLE_SERVICES[@]}"; do
                echo "  - $service" >> "${NODE_NAME}-apkovl/etc/k3s/config.yaml"
            done
        fi

        # Add node taints if specified
        yaml_get_array "nodes" | while read -r node_line; do
            node_info=($(echo "$node_line" | tr ':' ' '))
            if [ "${node_info[0]}" = "$NODE_NAME" ] && [ "${node_info[2]}" = "master" ]; then
                # Check for taints in the YAML (this would need more complex parsing)
                echo "node-taint:" >> "${NODE_NAME}-apkovl/etc/k3s/config.yaml"
                echo "  - \"CriticalAddonsOnly=true:NoExecute\"" >> "${NODE_NAME}-apkovl/etc/k3s/config.yaml"
                break
            fi
        done

        # Note: k3s init script is created by the k3s installer, not in the overlay

    else
        # Find master node IP for agent configuration
        # In HA mode with external datastore, consider using a VIP or load balancer
        MASTER_IP=$(yaml_get_nodes | grep ":master" | head -1 | cut -d':' -f2)

        # Check if a HA load balancer VIP is configured
        LB_VIP=$(yaml_get "k3s.loadbalancer_vip" 2>/dev/null || echo "")
        if [ -n "$LB_VIP" ]; then
            SERVER_URL="https://$LB_VIP:6443"
            echo "# Worker using load balancer VIP: $LB_VIP"
        else
            SERVER_URL="https://$MASTER_IP:6443"
            echo "# Worker using master IP: $MASTER_IP"
            if [ -n "$DATASTORE_ENDPOINT" ]; then
                echo "# WARNING: For true HA, configure k3s.loadbalancer_vip or use multiple server URLs"
            fi
        fi

        # Agent node configuration
        cat > "${NODE_NAME}-apkovl/etc/k3s/config.yaml" << EOF
server: $SERVER_URL
node-ip: $NODE_IP
EOF

        # Note: Worker will retrieve token from master via SSH during bootstrap
        # The system-bootstrap script handles this automatically for worker nodes

        # Note: k3s init script is created by the k3s installer, not in the overlay
    fi

    # Note: k3s init script is created by the k3s installer during installation
    # The k3s service will be enabled by the k3s_bootstrap script
    
    # Install k3s script
    K3S_VERSION=$(yaml_get "cluster.k3s_version")
    VERSION_FLAG=""
    if [ "$K3S_VERSION" != "latest" ] && [ -n "$K3S_VERSION" ]; then
        VERSION_FLAG="INSTALL_K3S_VERSION=$K3S_VERSION"
    fi
    
    # Disabled - using local.d approach instead
    : << 'DISABLED_OPENRC_SERVICE'
    cat > "${NODE_NAME}-apkovl/etc/init.d/k3s-installer" << EOF
#!/sbin/openrc-run

description="k3s installation service"
name="k3s installer"

command="/usr/local/bin/k3s_installer"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net k3s-bootstrap
    after k3s-bootstrap
    before k3s
    provide k3s-installer
}

start_pre() {
    # Create the k3s installer script
    cat > /usr/local/bin/k3s_installer << 'SCRIPT_EOF'
#!/bin/sh

# Robust logger function that handles missing syslog
_logger() {
    local msg="$*"
    # Try logger first, fallback to echo if syslog not available
    if logger -st "k3s-installer" "$msg" 2>/dev/null; then
        :  # Success
    else
        echo "[k3s-installer] $msg" >&2
    fi
}

_logger "Starting k3s installation"

# Install k3s if not present
if [ ! -f /usr/local/bin/k3s ]; then
    _logger "Downloading and installing k3s"
    echo "📦 Installing k3s..."
    curl -sfL https://get.k3s.io | $VERSION_FLAG INSTALL_K3S_SKIP_START=true sh -
    
    # Enable required services
    rc-update add cgroups boot
    
    _logger "k3s installation complete"
    echo "✅ k3s installation complete"
else
    _logger "k3s already installed"
    echo "✅ k3s already installed"
fi

exit 0
SCRIPT_EOF
    chmod +x /usr/local/bin/k3s_installer
}
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/k3s-installer"
    
    # Add service to default runlevel
    mkdir -p "${NODE_NAME}-apkovl/etc/runlevels/default"
    ln -sf /etc/init.d/k3s-installer "${NODE_NAME}-apkovl/etc/runlevels/default/k3s-installer"
DISABLED_OPENRC_SERVICE

done

echo "K3s configurations created for all nodes from YAML configuration"
echo "K3s token saved to k3s-token.txt"