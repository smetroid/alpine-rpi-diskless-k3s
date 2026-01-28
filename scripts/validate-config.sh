#!/bin/bash

# Configuration validation script for Alpine diskless k3s setup

set -e

# Source logging library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(cd "$SCRIPT_DIR/../lib" && pwd)}"

if [ -f "$LIB_DIR/logging.sh" ]; then
    . "$LIB_DIR/logging.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

# Load YAML parser
source "$LIB_DIR/yaml-parser.sh"

CONFIG_FILE="${CONFIG_FILE:-${1:-cluster-config.yaml}}"

log_info "=== Alpine k3s Configuration Validator ==="
log_info "Validating: $CONFIG_FILE"
echo ""

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file '$CONFIG_FILE' not found"
    echo "Please create cluster-config.yaml or specify a different file"
    exit 1
fi

# Export config file for yaml-parser
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
if ! yaml_get "cluster.name" >/dev/null 2>&1; then
    report_error "cluster.name is required"
else
    cluster_name=$(yaml_get "cluster.name")
    if [ -n "$cluster_name" ]; then
        report_ok "Cluster name: $cluster_name"
    else
        report_error "cluster.name cannot be empty"
    fi
fi

# Network validation
echo ""
log_info "Validating network configuration..."

gateway=$(yaml_get "network.gateway")
if [ -n "$gateway" ]; then
    # Basic IP validation
    if echo "$gateway" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        report_ok "Network gateway: $gateway"
    else
        report_error "Invalid gateway IP format: $gateway"
    fi
else
    report_error "network.gateway is required"
fi

subnet=$(yaml_get "network.subnet")
if [ -n "$subnet" ]; then
    if echo "$subnet" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
        report_ok "Network subnet: $subnet"
    else
        report_error "Invalid subnet format: $subnet (expected CIDR notation like 192.168.1.0/24)"
    fi
else
    report_error "network.subnet is required"
fi

# DNS servers validation
dns_servers=($(yaml_get_array ".network.dns_servers[]"))
if [ ${#dns_servers[@]} -gt 0 ]; then
    report_ok "DNS servers: ${dns_servers[*]}"
    for dns in "${dns_servers[@]}"; do
        if ! echo "$dns" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            report_error "Invalid DNS server IP format: $dns"
        fi
    done
else
    report_error "At least one DNS server is required in network.dns_servers"
fi

# LoadBalancer pool validation
lb_start=$(get_metallb_start)
lb_end=$(get_metallb_end)
if [ -n "$lb_start" ] && [ -n "$lb_end" ]; then
    report_ok "LoadBalancer pool: $lb_start - $lb_end"
else
    report_warning "LoadBalancer pool not configured (required if MetalLB is enabled)"
fi

# Node validation
echo ""
log_info "Validating node configuration..."

node_count=0
master_count=0
worker_count=0
node_ips=()
node_names=()

yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    node_count=$((node_count + 1))
    
    # Validate node name
    if [ -n "$NODE_NAME" ]; then
        node_names+=("$NODE_NAME")
        report_ok "Node: $NODE_NAME ($NODE_IP) - $NODE_ROLE"
    else
        report_error "Node name cannot be empty"
    fi
    
    # Validate IP address
    if echo "$NODE_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        node_ips+=("$NODE_IP")
        
        # Check if IP is in the same subnet as gateway
        if [ -n "$gateway" ] && [ -n "$subnet" ]; then
            subnet_base=$(echo "$subnet" | cut -d'/' -f1 | cut -d'.' -f1-3)
            ip_base=$(echo "$NODE_IP" | cut -d'.' -f1-3)
            gateway_base=$(echo "$gateway" | cut -d'.' -f1-3)
            
            if [ "$ip_base" != "$subnet_base" ] && [ "$ip_base" != "$gateway_base" ]; then
                report_warning "Node IP $NODE_IP may not be in the same subnet as gateway $gateway"
            fi
        fi
    else
        report_error "Invalid node IP format: $NODE_IP"
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

# Use subshell results
total_nodes=$(yaml_get_nodes | wc -l)
masters=$(yaml_get_nodes | grep -c ":master" || true)
workers=$(yaml_get_nodes | grep -c ":worker" || true)

if [ "$total_nodes" -eq 0 ]; then
    report_error "No nodes defined"
elif [ "$total_nodes" -lt 3 ]; then
    report_warning "Less than 3 nodes defined (recommended minimum for HA)"
else
    report_ok "Total nodes: $total_nodes"
fi

if [ "$masters" -eq 0 ]; then
    report_error "At least one master node is required"
elif [ "$masters" -gt 1 ]; then
    report_warning "Multiple master nodes detected - ensure proper HA configuration"
else
    report_ok "Master nodes: $masters"
fi

if [ "$workers" -eq 0 ]; then
    report_warning "No worker nodes defined - workloads will run on master nodes"
else
    report_ok "Worker nodes: $workers"
fi

# Check for duplicate IPs or names
yaml_get_nodes | cut -d':' -f2 | sort | uniq -d | while read -r dup_ip; do
    if [ -n "$dup_ip" ]; then
        report_error "Duplicate IP address found: $dup_ip"
    fi
done

yaml_get_nodes | cut -d':' -f1 | sort | uniq -d | while read -r dup_name; do
    if [ -n "$dup_name" ]; then
        report_error "Duplicate node name found: $dup_name"
    fi
done

# k3s configuration validation
echo ""
log_info "Validating k3s configuration..."

cluster_cidr=$(get_k3s_cluster_cidr)
service_cidr=$(get_k3s_service_cidr)

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

if [ "$(get_service_enabled metallb)" = "true" ]; then
    metallb_version=$(get_service_version metallb)
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

if [ "$(get_service_enabled nginx_ingress)" = "true" ]; then
    nginx_version=$(get_service_version nginx_ingress)
    if [ -n "$nginx_version" ]; then
        report_ok "NGINX Ingress enabled: $nginx_version"
    else
        report_warning "NGINX Ingress enabled but version not specified"
    fi
else
    report_ok "NGINX Ingress disabled"
fi

# SSH configuration validation
echo ""
log_info "Validating SSH configuration..."

ssh_port=$(yaml_get "ssh.port")
if [ -n "$ssh_port" ] && [ "$ssh_port" -gt 0 ] && [ "$ssh_port" -lt 65536 ]; then
    report_ok "SSH port: $ssh_port"
else
    report_warning "Invalid SSH port: $ssh_port (using default 22)"
fi

auth_keys=($(yaml_get_array ".ssh.authorized_keys[]"))
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