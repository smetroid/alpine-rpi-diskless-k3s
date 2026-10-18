#!/bin/bash

# Configuration validation script for Alpine diskless k3s setup

set -e

# Source logging library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(cd "$SCRIPT_DIR/../lib" && pwd)}"

CONFIG_FILE="${CONFIG_FILE:-${1:-cluster-config.yaml}}"

if [ -f "$LIB_DIR/logging.sh" ]; then
    . "$LIB_DIR/logging.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

log_info "=== Alpine k3s Configuration Validator ==="
log_info "Validating: $CONFIG_FILE"
echo ""

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file '$CONFIG_FILE' not found"
    echo "Please create cluster-config.yaml or specify a different file"
    exit 1
fi

export CONFIG_FILE

errors=0
warnings=0

# Function to report error
report_error() {
    log_error "$1"
    errors=$((errors + 1))
}

# Function to report warning
report_warning() {
    log_warn "$1"
    warnings=$((warnings + 1))
}

# Function to report success
report_ok() {
    log_success "$1"
}

log_info "Checking basic configuration structure..."

# Basic structure validation
    if ! yq e '.cluster.name // ""' "$CONFIG_FILE" >/dev/null 2>&1; then
    report_error "cluster.name is required"
else
    cluster_name=$(yq e '.cluster.name // ""' "$CONFIG_FILE")
    if [ -n "$cluster_name" ]; then
        report_ok "Cluster name: $cluster_name"
    else
        report_error "cluster.name cannot be empty"
    fi
fi

# Detect gateway mode
vip=$(yq e '.network.vip // ""' "$CONFIG_FILE" 2>/dev/null || true)
is_gateway=false
[ -n "$vip" ] && is_gateway=true

if $is_gateway; then
    log_info "Gateway cluster mode detected (network.vip: $vip)"
fi

# Network validation
echo ""
log_info "Validating network configuration..."

gateway=$(yq e '.network.gateway // ""' "$CONFIG_FILE")
if [ -n "$gateway" ]; then
    # Standard cluster - gateway is required
    if echo "$gateway" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        report_ok "Network gateway: $gateway"
    else
        report_error "Invalid gateway IP format: $gateway"
    fi
elif $is_gateway; then
    report_ok "No upstream gateway (cluster IS the gateway via VIP $vip)"
else
    report_error "network.gateway is required (or set network.vip for gateway mode)"
fi

subnet=$(yq e '.network.subnet // ""' "$CONFIG_FILE")
lan_subnet=$(yq e '.network.lan_subnet' "$CONFIG_FILE")
if [ -n "$subnet" ]; then
    # Standard cluster uses network.subnet
    if echo "$subnet" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
        report_ok "Network subnet: $subnet"
    else
        report_error "Invalid subnet format: $subnet (expected CIDR notation like 192.168.1.0/24)"
    fi
elif [ -n "$lan_subnet" ]; then
    # Gateway cluster uses network.lan_subnet
    if echo "$lan_subnet" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
        report_ok "LAN subnet: $lan_subnet"
    else
        report_error "Invalid lan_subnet format: $lan_subnet (expected CIDR notation)"
    fi
else
    report_error "network.subnet or network.lan_subnet is required"
fi

# Determine which subnet to use for validation
USE_SUBNET="${subnet:-$lan_subnet}"

# DNS servers validation
dns_servers=()
while IFS= read -r _line; do
    [[ -n "$_line" ]] && dns_servers+=("$_line")
done < <(yq e '.network.dns_servers[]' "$CONFIG_FILE" 2>/dev/null)
dns_upstream=()
while IFS= read -r _line; do
    [[ -n "$_line" ]] && dns_upstream+=("$_line")
done < <(yq e '.network.dns_upstream[]' "$CONFIG_FILE" 2>/dev/null)

if [ ${#dns_servers[@]} -gt 0 ]; then
    report_ok "DNS servers: ${dns_servers[*]}"
    for dns in "${dns_servers[@]}"; do
        if ! echo "$dns" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            report_error "Invalid DNS server IP format: $dns"
        fi
    done
elif [ ${#dns_upstream[@]} -gt 0 ]; then
    report_ok "DNS upstream: ${dns_upstream[*]}"
    for dns in "${dns_upstream[@]}"; do
        if ! echo "$dns" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            report_error "Invalid DNS upstream IP format: $dns"
        fi
    done
else
    report_error "At least one DNS server is required in network.dns_servers or network.dns_upstream"
fi

# LoadBalancer pool validation
lb_start=$(yq e '.network.loadbalancer_pool.start // ""' "$CONFIG_FILE")
lb_end=$(yq e '.network.loadbalancer_pool.end // ""' "$CONFIG_FILE")
if [ -n "$lb_start" ] && [ -n "$lb_end" ]; then
    report_ok "LoadBalancer pool: $lb_start - $lb_end"
else
    report_warning "LoadBalancer pool not configured (required if MetalLB is enabled)"
fi

# Node validation
echo ""
log_info "Validating node configuration..."

total_nodes=$(yq e '.nodes | length' "$CONFIG_FILE")
master_count=0
worker_count=0
declare -a node_ips=()
declare -a node_names=()
declare -a vrrp_priorities=()

if [ "$total_nodes" -eq 0 ]; then
    report_error "No nodes defined"
else
    report_ok "Total nodes: $total_nodes"
fi

for (( i=0; i<total_nodes; i++ )); do
    NODE_NAME=$(yq e ".nodes[$i].name" "$CONFIG_FILE")
    NODE_ROLE=$(yq e ".nodes[$i].role" "$CONFIG_FILE")

    if [ -z "$NODE_NAME" ]; then
        report_error "Node at index $i has no name"
        continue
    fi
    node_names+=("$NODE_NAME")

    # Check if this node uses enriched (interfaces:) or flat (ip:) schema
    if yq e ".nodes[$i].interfaces" "$CONFIG_FILE" 2>/dev/null | grep -qv null; then
        LAN_IP=$(yq e ".nodes[$i].interfaces.lan.ip" "$CONFIG_FILE")
        LAN_DEVICE=$(yq e ".nodes[$i].interfaces.lan.device" "$CONFIG_FILE")
        WAN_DEVICE=$(yq e ".nodes[$i].interfaces.wan.device" "$CONFIG_FILE")
        WAN_PROTO=$(yq e ".nodes[$i].interfaces.wan.proto" "$CONFIG_FILE")

        # Extract bare IP from CIDR notation
        NODE_IP=$(echo "$LAN_IP" | cut -d'/' -f1)

        report_ok "Node: $NODE_NAME ($NODE_IP) - $NODE_ROLE"
        report_ok "  LAN: $LAN_DEVICE $LAN_IP"
        report_ok "  WAN: $WAN_DEVICE ($WAN_PROTO)"

        # Validate LAN IP
        if ! echo "$NODE_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            report_error "Invalid LAN IP format for $NODE_NAME: $LAN_IP"
        else
            node_ips+=("$NODE_IP")
        fi

        # Validate WAN device
        if [ -z "$WAN_DEVICE" ]; then
            report_error "Node $NODE_NAME: wan.device is required"
        fi

        # Validate WAN proto
        if [ -n "$WAN_PROTO" ] && [ "$WAN_PROTO" != "dhcp" ] && [ "$WAN_PROTO" != "static" ]; then
            report_error "Node $NODE_NAME: wan.proto must be 'dhcp' or 'static' (got: $WAN_PROTO)"
        fi

        # Validate VRRP config for gateway mode
        VRRP_STATE=$(yq e ".nodes[$i].vrrp.state" "$CONFIG_FILE")
        VRRP_PRIORITY=$(yq e ".nodes[$i].vrrp.priority" "$CONFIG_FILE")

        if $is_gateway; then
            if [ -z "$VRRP_STATE" ]; then
                report_error "Node $NODE_NAME: vrrp.state is required in gateway mode"
            elif [ "$VRRP_STATE" != "MASTER" ] && [ "$VRRP_STATE" != "BACKUP" ]; then
                report_error "Node $NODE_NAME: vrrp.state must be 'MASTER' or 'BACKUP'"
            fi

            if [ -n "$VRRP_PRIORITY" ]; then
                if [ "$VRRP_PRIORITY" -lt 1 ] || [ "$VRRP_PRIORITY" -gt 255 ]; then
                    report_error "Node $NODE_NAME: vrrp.priority must be 1-255 (got: $VRRP_PRIORITY)"
                fi
                vrrp_priorities+=("$VRRP_PRIORITY")
            else
                report_error "Node $NODE_NAME: vrrp.priority is required in gateway mode"
            fi
        fi
    else
        # Flat schema (backward compat)
        NODE_IP=$(yq e ".nodes[$i].ip" "$CONFIG_FILE")

        if [ -n "$NODE_NAME" ]; then
            report_ok "Node: $NODE_NAME ($NODE_IP) - $NODE_ROLE"
        else
            report_error "Node name cannot be empty"
        fi

        # Validate IP address
        if echo "$NODE_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            node_ips+=("$NODE_IP")
            if [ -n "$USE_SUBNET" ]; then
                subnet_base=$(echo "$USE_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)
                ip_base=$(echo "$NODE_IP" | cut -d'.' -f1-3)
                if [ "$ip_base" != "$subnet_base" ]; then
                    report_warning "Node IP $NODE_IP may not be in subnet $USE_SUBNET"
                fi
            fi
        else
            report_error "Invalid node IP format for $NODE_NAME: $NODE_IP"
        fi
    fi

    # Count roles
    case "$NODE_ROLE" in
        master)
            master_count=$((master_count + 1))
            ;;
        worker)
            worker_count=$((worker_count + 1))
            ;;
        *)
            report_error "Invalid node role: $NODE_ROLE (must be 'master' or 'worker')"
            ;;
    esac
done

# Check VRRP priority uniqueness
if $is_gateway; then
    dup_prio=$(printf '%s\n' "${vrrp_priorities[@]}" | sort | uniq -d)
    if [ -n "$dup_prio" ]; then
        report_error "Duplicate VRRP priority found: $dup_prio (must be unique per node)"
    fi
fi

if [ "$master_count" -eq 0 ]; then
    report_error "At least one master node is required"
elif [ "$master_count" -gt 1 ]; then
    report_warning "Multiple master nodes detected - ensure proper HA configuration"
else
    report_ok "Master nodes: $master_count"
fi

if [ "$worker_count" -eq 0 ]; then
    report_warning "No worker nodes defined - workloads will run on master nodes"
else
    report_ok "Worker nodes: $worker_count"
fi

# Check for duplicate IPs or names
for ip in "${node_ips[@]}"; do
    count=$(printf '%s\n' "${node_ips[@]}" | grep -c "^$ip$" || true)
    if [ "$count" -gt 1 ]; then
        report_error "Duplicate IP address found: $ip"
    fi
done

for name in "${node_names[@]}"; do
    count=$(printf '%s\n' "${node_names[@]}" | grep -c "^$name$" || true)
    if [ "$count" -gt 1 ]; then
        report_error "Duplicate node name found: $name"
    fi
done

# VIP validation for gateway mode
if $is_gateway; then
    if ! echo "$vip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        report_error "Invalid VIP format: $vip"
    fi

    # Check VIP doesn't collide with any node IP
    for node_ip in "${node_ips[@]}"; do
        if [ "$vip" = "$node_ip" ]; then
            report_error "VIP $vip collides with node IP $node_ip"
        fi
    done

    # Check VIP is in lan_subnet if set
    if [ -n "$lan_subnet" ]; then
        vip_base=$(echo "$vip" | cut -d'.' -f1-3)
        subnet_base=$(echo "$lan_subnet" | cut -d'/' -f1 | cut -d'.' -f1-3)
        if [ "$vip_base" != "$subnet_base" ]; then
            report_error "VIP $vip is not in lan_subnet $lan_subnet"
        fi
    fi
fi

# k3s configuration validation
echo ""
log_info "Validating k3s configuration..."

cluster_cidr=$(yq e '.k3s.cluster_cidr // ""' "$CONFIG_FILE")
service_cidr=$(yq e '.k3s.service_cidr // ""' "$CONFIG_FILE")

if [ -n "$cluster_cidr" ]; then
    report_ok "Cluster CIDR: $cluster_cidr"
else
    report_warning "k3s.cluster_cidr not set (will use k3s default)"
fi

if [ -n "$service_cidr" ]; then
    report_ok "Service CIDR: $service_cidr"
else
    report_warning "k3s.service_cidr not set (will use k3s default)"
fi

# Services validation
echo ""
log_info "Validating services configuration..."

if [ "$(yq e '.services.metallb.enabled // "false"' "$CONFIG_FILE")" = "true" ]; then
    metallb_version=$(yq e '.services.metallb.version // ""' "$CONFIG_FILE")
    if [ -n "$metallb_version" ]; then
        report_ok "MetalLB enabled: $metallb_version"
    else
        report_warning "MetalLB enabled but version not specified"
    fi
    
    if [ -z "$lb_start" ] || [ -z "$lb_end" ]; then
        report_error "MetalLB enabled but LoadBalancer IP pool not configured"
    fi
else
    report_ok "MetalLB disabled"
fi

if [ "$(yq e '.services.nginx_ingress.enabled // "false"' "$CONFIG_FILE")" = "true" ]; then
    nginx_version=$(yq e '.services.nginx_ingress.version // ""' "$CONFIG_FILE")
    if [ -n "$nginx_version" ]; then
        report_ok "NGINX Ingress enabled: $nginx_version"
    else
        report_warning "NGINX Ingress enabled but version not specified"
    fi
else
    report_ok "NGINX Ingress disabled"
fi

if [ "$(yq e '.services.openwrt.enabled // "false"' "$CONFIG_FILE")" = "true" ]; then
    openwrt_image=$(yq e '.services.openwrt.image' "$CONFIG_FILE")
    if [ -n "$openwrt_image" ]; then
        report_ok "OpenWrt enabled: $openwrt_image"
    else
        report_warning "OpenWrt enabled but image not specified"
    fi
else
    if $is_gateway; then
        report_warning "Gateway mode but services.openwrt.enabled is not 'true'"
    fi
fi

# SSH configuration validation
echo ""
log_info "Validating SSH configuration..."

ssh_port=$(yq e '.ssh.port // ""' "$CONFIG_FILE")
if [ -n "$ssh_port" ] && [ "$ssh_port" -gt 0 ] && [ "$ssh_port" -lt 65536 ]; then
    report_ok "SSH port: $ssh_port"
else
    report_warning "Invalid SSH port: $ssh_port (using default 22)"
fi

auth_keys=()
while IFS= read -r _line; do
    [[ -n "$_line" ]] && auth_keys+=("$_line")
done < <(yq e '.ssh.authorized_keys[]' "$CONFIG_FILE" 2>/dev/null)
if [ ${#auth_keys[@]} -gt 0 ]; then
    report_ok "SSH authorized keys: ${#auth_keys[@]} key(s) configured"
else
    report_warning "No SSH authorized keys configured (password auth only)"
fi

# Final summary
echo ""
log_info "=== Validation Summary ==="
log_info "Errors: $errors"
log_info "Warnings: $warnings"

if [ "$errors" -eq 0 ]; then
    echo ""
    log_success "Configuration validation passed!"
    log_info "Your cluster configuration is ready for deployment."
    exit 0
else
    echo ""
    log_error "Configuration validation failed!"
    log_error "Please fix the errors above before proceeding."
    exit 1
fi