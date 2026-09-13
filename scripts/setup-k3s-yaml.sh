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

# Load template renderer
_templates_root="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$LIB_DIR/templates.sh"

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
DISABLE_SERVICES=()
while IFS= read -r _line; do
    [[ -n "$_line" ]] && DISABLE_SERVICES+=("$_line")
done < <(yaml_get_array ".k3s.disable_services[]")

KUBE_APISERVER_ARGS=()
while IFS= read -r _line; do
    [[ -n "$_line" ]] && KUBE_APISERVER_ARGS+=("$_line")
done < <(yaml_get_array ".k3s.kube_apiserver_arg[]")

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

    # Create K3s rancher directory if not exists (k3s reads from /etc/rancher/k3s/)
    mkdir -p "${NODE_NAME}-apkovl/etc/rancher/k3s"

    if [ "$NODE_ROLE" = "master" ]; then
        # Master node configuration
        # When using external datastore (PostgreSQL/MySQL), do NOT use cluster-init
        # All servers coordinate via the external datastore instead
        if [ -n "$DATASTORE_ENDPOINT" ]; then
            # HA with external datastore
            export NODE_IP CLUSTER_CIDR SERVICE_CIDR FLANNEL_BACKEND DATASTORE_ENDPOINT
            render_template "config/k3s-server-datastore.tmpl" "${NODE_NAME}-apkovl/etc/rancher/k3s/config.yaml"
            echo "# HA mode: External datastore enabled"
        else
            # Embedded database (SQLite) with cluster-init
            export NODE_IP CLUSTER_CIDR SERVICE_CIDR FLANNEL_BACKEND
            render_template "config/k3s-server-embedded.tmpl" "${NODE_NAME}-apkovl/etc/rancher/k3s/config.yaml"
            echo "# HA mode: Embedded database with cluster-init"
        fi

        # Add disable services
        if [ ${#DISABLE_SERVICES[@]} -gt 0 ]; then
            echo "disable:" >> "${NODE_NAME}-apkovl/etc/rancher/k3s/config.yaml"
            for service in "${DISABLE_SERVICES[@]}"; do
                echo "  - $service" >> "${NODE_NAME}-apkovl/etc/rancher/k3s/config.yaml"
            done
        fi

        # Add kube-apiserver args
        if [ ${#KUBE_APISERVER_ARGS[@]} -gt 0 ]; then
            echo "kube-apiserver-arg:" >> "${NODE_NAME}-apkovl/etc/rancher/k3s/config.yaml"
            for arg in "${KUBE_APISERVER_ARGS[@]}"; do
                echo "  - \"$arg\"" >> "${NODE_NAME}-apkovl/etc/rancher/k3s/config.yaml"
            done
        fi

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
        export SERVER_URL NODE_IP
        render_template "config/k3s-agent.tmpl" "${NODE_NAME}-apkovl/etc/rancher/k3s/config.yaml"

        # Note: Worker will retrieve token from master via SSH during bootstrap
        # The system-bootstrap script handles this automatically for worker nodes

        # Note: k3s init script is created by the k3s installer, not in the overlay
    fi

    # Note: k3s init script is created by the k3s installer during installation
    # The k3s service will be enabled by the k3s_bootstrap script
    

done

echo "K3s configurations created for all nodes from YAML configuration"
echo "K3s token saved to k3s-token.txt"