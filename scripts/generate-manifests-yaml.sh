#!/bin/bash

# Generate Kubernetes manifests from YAML configuration

set -e

# Source and library directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(cd "$SCRIPT_DIR/../lib" && pwd)}"

# Config file
CONFIG_FILE="${CONFIG_FILE:-cluster-config.yaml}"
export CONFIG_FILE

# Load template renderer
_templates_root="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$LIB_DIR/templates.sh"

echo "Generating Kubernetes manifests from YAML configuration..."

# Validate configuration
if ! "$SCRIPT_DIR/validate-config.sh" "$CONFIG_FILE"; then
    exit 1
fi

mkdir -p k3s-manifests

# Generate MetalLB configuration
if [ "$(yq e '.services.metallb.enabled // "false"' "$CONFIG_FILE")" = "true" ]; then
    echo "Generating MetalLB configuration..."
    
    METALLB_VERSION=$(yq e '.services.metallb.version // ""' "$CONFIG_FILE")
    LB_START=$(yq e '.network.loadbalancer_pool.start // ""' "$CONFIG_FILE")
    LB_END=$(yq e '.network.loadbalancer_pool.end // ""' "$CONFIG_FILE")
    
    export LB_START LB_END METALLB_VERSION
    render_template "manifests/metallb-config.tmpl" k3s-manifests/metallb-config.yaml
    echo "✓ MetalLB configuration generated"
fi

# Generate NGINX Ingress configuration
if [ "$(yq e '.services.nginx_ingress.enabled // "false"' "$CONFIG_FILE")" = "true" ]; then
    echo "Generating NGINX Ingress configuration..."
    
    NGINX_VERSION=$(yq e '.services.nginx_ingress.version // ""' "$CONFIG_FILE")
    NGINX_REPLICAS=$(yq e '.services.nginx_ingress.replicas // ""' "$CONFIG_FILE")
    
    # Generate basic NGINX Ingress manifest with dynamic values
    export NGINX_VERSION NGINX_REPLICAS
    render_template "manifests/nginx-proxy.tmpl" k3s-manifests/nginx-proxy.yaml
    echo "✓ NGINX Ingress configuration generated"
fi

# Generate OpenWrt DaemonSet configuration
if [ "$(yq e '.services.openwrt.enabled // "false"' "$CONFIG_FILE")" = "true" ]; then
    echo "Generating OpenWrt DaemonSet configuration..."

    OPENWRT_IMAGE=$(yq e '.services.openwrt.image' "$CONFIG_FILE")

    export OPENWRT_IMAGE
    render_template "manifests/openwrt-daemonset.tmpl" k3s-manifests/openwrt-daemonset.yaml
    echo "✓ OpenWrt DaemonSet configuration generated"
fi

echo "All Kubernetes manifests generated successfully!"
echo "Files created in k3s-manifests/ directory"