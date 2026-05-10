#!/bin/bash

# Generate Kubernetes manifests from YAML configuration

set -e

# Source and library directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(cd "$SCRIPT_DIR/../lib" && pwd)}"

# Load YAML parser
source "$LIB_DIR/yaml-parser.sh"

# Load template renderer
_templates_root="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$LIB_DIR/templates.sh"

echo "Generating Kubernetes manifests from YAML configuration..."

# Validate configuration
if ! validate_config; then
    exit 1
fi

mkdir -p k3s-manifests

# Generate MetalLB configuration
if [ "$(get_service_enabled metallb)" = "true" ]; then
    echo "Generating MetalLB configuration..."
    
    METALLB_VERSION=$(get_service_version metallb)
    LB_START=$(get_metallb_start)
    LB_END=$(get_metallb_end)
    
    export LB_START LB_END METALLB_VERSION
    render_template "manifests/metallb-config.tmpl" k3s-manifests/metallb-config.yaml
    echo "✓ MetalLB configuration generated"
fi

# Generate NGINX Ingress configuration
if [ "$(get_service_enabled nginx_ingress)" = "true" ]; then
    echo "Generating NGINX Ingress configuration..."
    
    NGINX_VERSION=$(get_service_version nginx_ingress)
    NGINX_REPLICAS=$(get_service_replicas nginx_ingress)
    
    # Generate basic NGINX Ingress manifest with dynamic values
    export NGINX_VERSION NGINX_REPLICAS
    render_template "manifests/nginx-proxy.tmpl" k3s-manifests/nginx-proxy.yaml
    echo "✓ NGINX Ingress configuration generated"
fi

echo "All Kubernetes manifests generated successfully!"
echo "Files created in k3s-manifests/ directory"