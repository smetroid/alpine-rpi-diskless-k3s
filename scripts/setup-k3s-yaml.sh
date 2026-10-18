#!/bin/bash

# K3s configuration setup using YAML configuration

set -e

# Source and library directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(cd "$SCRIPT_DIR/../lib" && pwd)}"

# Use config file from environment if available
CONFIG_FILE="${CONFIG_FILE:-cluster-config.yaml}"
export CONFIG_FILE

# Load template renderer
_templates_root="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$LIB_DIR/templates.sh"

echo "Setting up K3s configuration from YAML..."

# Validate configuration
if ! "$SCRIPT_DIR/validate-config.sh" "$CONFIG_FILE"; then
    exit 1
fi

# Generate or get k3s token
K3S_TOKEN=$(yq e '.cluster.token // ""' "$CONFIG_FILE")
if [ -z "$K3S_TOKEN" ]; then
    K3S_TOKEN=$(openssl rand -hex 32)
    echo "Generated K3S_TOKEN: $K3S_TOKEN"
    echo "$K3S_TOKEN" > k3s-token.txt
else
    echo "Using provided K3S_TOKEN from configuration"
    echo "$K3S_TOKEN" > k3s-token.txt
fi

# Get configuration values
CLUSTER_CIDR=$(yq e '.k3s.cluster_cidr // ""' "$CONFIG_FILE")
SERVICE_CIDR=$(yq e '.k3s.service_cidr // ""' "$CONFIG_FILE")
FLANNEL_BACKEND=$(yq e '.k3s.flannel_backend // ""' "$CONFIG_FILE")
DISABLE_SERVICES=()
while IFS= read -r _line; do
    [[ -n "$_line" ]] && DISABLE_SERVICES+=("$_line")
done < <(yq e '.k3s.disable_services[]' "$CONFIG_FILE" 2>/dev/null)

# Get external datastore configuration (optional)
DATASTORE_ENDPOINT=""
DATASTORE_TYPE=$(yq e '.k3s.datastore.type // ""' "$CONFIG_FILE")
if [ -n "$DATASTORE_TYPE" ]; then
    DATASTORE_HOST=$(yq e '.k3s.datastore.host // ""' "$CONFIG_FILE")
    DATASTORE_PORT=$(yq e '.k3s.datastore.port // "5432"' "$CONFIG_FILE")
    DATASTORE_DATABASE=$(yq e '.k3s.datastore.database // ""' "$CONFIG_FILE")
    DATASTORE_USER=$(yq e '.k3s.datastore.user // ""' "$CONFIG_FILE")
    DATASTORE_PASSWORD=$(yq e '.k3s.datastore.password // ""' "$CONFIG_FILE")
    DATASTORE_SSLMODE=$(yq e '.k3s.datastore.sslmode // "disable"' "$CONFIG_FILE")

    if [ "$DATASTORE_TYPE" = "postgres" ]; then
        DATASTORE_ENDPOINT="postgres://${DATASTORE_USER}:${DATASTORE_PASSWORD}@${DATASTORE_HOST}:${DATASTORE_PORT}/${DATASTORE_DATABASE}?sslmode=${DATASTORE_SSLMODE}"
    elif [ "$DATASTORE_TYPE" = "mysql" ]; then
        DATASTORE_ENDPOINT="mysql://${DATASTORE_USER}:${DATASTORE_PASSWORD}@tcp(${DATASTORE_HOST}:${DATASTORE_PORT})/${DATASTORE_DATABASE}"
    fi

    echo "Using external datastore (${DATASTORE_TYPE}): ${DATASTORE_HOST}"
fi

# Helper to get node LAN IP (handles both flat and enriched schemas)
_get_node_lan_ip() {
    local idx=$1
    if yq e ".nodes[$idx].interfaces" "$CONFIG_FILE" 2>/dev/null | grep -qv null; then
        local cidr; cidr=$(yq e ".nodes[$idx].interfaces.lan.ip" "$CONFIG_FILE")
        echo "$cidr" | cut -d'/' -f1
    else
        yq e ".nodes[$idx].ip" "$CONFIG_FILE"
    fi
}

# Process each node using indexed access
NODE_COUNT=$(yq e '.nodes | length' "$CONFIG_FILE")
for (( NODE_IDX=0; NODE_IDX<NODE_COUNT; NODE_IDX++ )); do
    NODE_NAME=$(yq e ".nodes[$NODE_IDX].name" "$CONFIG_FILE")
    NODE_ROLE=$(yq e ".nodes[$NODE_IDX].role" "$CONFIG_FILE")
    NODE_IP=$(_get_node_lan_ip $NODE_IDX)
    echo "Setting up K3s configuration for $NODE_NAME ($NODE_ROLE)..."
    echo "  Node IP: $NODE_IP"

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

        # Pin flannel to LAN interface for gateway nodes
        if yq e ".nodes[$NODE_IDX].interfaces" "$CONFIG_FILE" 2>/dev/null | grep -qv null; then
            LAN_DEVICE=$(yq e ".nodes[$NODE_IDX].interfaces.lan.device" "$CONFIG_FILE")
            echo "flannel-iface: $LAN_DEVICE" >> "${NODE_NAME}-apkovl/etc/rancher/k3s/config.yaml"
        fi

        # Note: k3s init script is created by the k3s installer, not in the overlay

    else
        # Find master node IP for agent configuration
        # Use the first master node's LAN IP
        MASTER_IP=""
        for (( m=0; m<NODE_COUNT; m++ )); do
            if [ "$(yq e ".nodes[$m].role" "$CONFIG_FILE")" = "master" ]; then
                MASTER_IP=$(_get_node_lan_ip $m)
                break
            fi
        done

        # Check if a HA load balancer VIP is configured
        LB_VIP=$(yq e '.k3s.loadbalancer_vip // ""' "$CONFIG_FILE")
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