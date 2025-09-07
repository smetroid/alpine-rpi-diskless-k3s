#!/bin/bash

# K3s configuration setup using YAML configuration

set -e

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
DISABLE_SERVICES=($(yaml_get_array "k3s.disable_services"))

# Process each node
yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    echo "Setting up K3s configuration for $NODE_NAME ($NODE_ROLE)..."
    
    # Create K3s directory if not exists
    mkdir -p "${NODE_NAME}-apkovl/etc/k3s"
    
    if [ "$NODE_ROLE" = "master" ]; then
        # Master node configuration
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

        # Master startup script
        cat > "${NODE_NAME}-apkovl/etc/init.d/k3s" << EOF
#!/sbin/openrc-run

name="k3s"
description="Lightweight Kubernetes"
command="/usr/local/bin/k3s"
command_args="server --config /etc/k3s/config.yaml --token $K3S_TOKEN"
command_background="yes"
pidfile="/var/run/k3s.pid"
command_user="root"
start_stop_daemon_args="--make-pidfile"

depend() {
    need net
    after local
    provide k3s
}

start_pre() {
    # Ensure cgroups are properly set up
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        # cgroup v2
        echo "+cpu +memory +pids" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    fi
    
    # Load required kernel modules
    modprobe br_netfilter 2>/dev/null || true
    modprobe overlay 2>/dev/null || true
    
    # Set kernel parameters
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    
    return 0
}
EOF

    else
        # Find master node IP for agent configuration
        MASTER_IP=$(yaml_get_nodes | grep ":master" | head -1 | cut -d':' -f2)
        
        # Agent node configuration
        cat > "${NODE_NAME}-apkovl/etc/k3s/config.yaml" << EOF
server: https://$MASTER_IP:6443
node-ip: $NODE_IP
EOF

        # Agent startup script
        cat > "${NODE_NAME}-apkovl/etc/init.d/k3s" << EOF
#!/sbin/openrc-run

name="k3s"
description="Lightweight Kubernetes Agent"
command="/usr/local/bin/k3s"
command_args="agent --config /etc/k3s/config.yaml --token $K3S_TOKEN"
command_background="yes"
pidfile="/var/run/k3s.pid"
command_user="root"
start_stop_daemon_args="--make-pidfile"

depend() {
    need net
    after local
    provide k3s
}

start_pre() {
    # Wait for master to be ready
    timeout=300
    while [ \$timeout -gt 0 ]; do
        if nc -z $MASTER_IP 6443; then
            break
        fi
        sleep 5
        timeout=\$((timeout - 5))
    done
    
    # Load required kernel modules
    modprobe br_netfilter 2>/dev/null || true
    modprobe overlay 2>/dev/null || true
    
    # Set kernel parameters
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    
    return 0
}
EOF
    fi
    
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/k3s"
    
    # Add k3s to default runlevel
    ln -sf /etc/init.d/k3s "${NODE_NAME}-apkovl/etc/runlevels/default/k3s"
    
    # Install k3s script
    K3S_VERSION=$(yaml_get "cluster.k3s_version")
    VERSION_FLAG=""
    if [ "$K3S_VERSION" != "latest" ] && [ -n "$K3S_VERSION" ]; then
        VERSION_FLAG="INSTALL_K3S_VERSION=$K3S_VERSION"
    fi
    
    cat > "${NODE_NAME}-apkovl/etc/local.d/30-install-k3s.start" << EOF
#!/bin/sh

# Install k3s if not present
if [ ! -f /usr/local/bin/k3s ]; then
    echo "Installing k3s..."
    curl -sfL https://get.k3s.io | $VERSION_FLAG INSTALL_K3S_SKIP_START=true sh -
    
    # Enable required services
    rc-update add cgroups boot
    rc-update add local default
fi
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/local.d/30-install-k3s.start"

done

echo "K3s configurations created for all nodes from YAML configuration"
echo "K3s token saved to k3s-token.txt"