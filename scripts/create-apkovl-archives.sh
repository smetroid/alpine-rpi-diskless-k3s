#!/bin/bash

# Create apkovl archives from YAML configuration
# This script reads the cluster config and generates .apkovl.tar.gz files for all nodes

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

CONFIG_FILE="${CONFIG_FILE:-${1:-cluster-config.yaml}}"

log_info "=== Creating apkovl archives from YAML configuration ==="
log_info "Using configuration file: $CONFIG_FILE"
echo ""

# Check if configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file '$CONFIG_FILE' not found"
    echo ""
    echo "Usage: $0 [config_file]"
    echo "Example: $0 my-cluster.yaml"
    echo "Default: $0  (uses cluster-config.yaml)"
    exit 1
fi

# Export config file for yaml-parser
export CONFIG_FILE

# Load YAML parser
if [ ! -f "$LIB_DIR/yaml-parser.sh" ]; then
    log_error "$LIB_DIR/yaml-parser.sh not found"
    log_error "Make sure LIB_DIR environment variable is set correctly"
    exit 1
fi

source "$LIB_DIR/yaml-parser.sh"

# Get cluster information
CLUSTER_NAME=$(get_cluster_name)
log_info "Cluster: $CLUSTER_NAME"
echo ""

# Check if any apkovl directories exist
FOUND_DIRS=false
while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    if [ -d "${NODE_NAME}-apkovl" ]; then
        FOUND_DIRS=true
        break
    fi
done < <(yaml_get_nodes)

if [ "$FOUND_DIRS" != "true" ]; then
    log_warn "No apkovl directories found. You may need to run:"
    echo "   ./build-from-yaml.sh $CONFIG_FILE"
    echo "   or ./create-apkovl-yaml.sh $CONFIG_FILE"
    echo ""
fi

# Process each node
CREATED_COUNT=0
FAILED_COUNT=0

while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    log_info "Processing $NODE_NAME ($NODE_ROLE - $NODE_IP)..."

    # Check if apkovl directory exists
    if [ ! -d "${NODE_NAME}-apkovl" ]; then
        log_error "Directory ${NODE_NAME}-apkovl/ not found - skipping"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Check if directory has content
    if [ -z "$(ls -A "${NODE_NAME}-apkovl" 2>/dev/null)" ]; then
        log_warn "Directory ${NODE_NAME}-apkovl/ is empty - skipping"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Create the archive
    log_info "Creating ${NODE_NAME}.apkovl.tar.gz..."

    # Change to apkovl directory and create archive
    if (cd "${NODE_NAME}-apkovl" && tar -czf "../${NODE_NAME}.apkovl.tar.gz" .); then
        # Verify the archive was created and has content
        if [ -f "${NODE_NAME}.apkovl.tar.gz" ] && [ -s "${NODE_NAME}.apkovl.tar.gz" ]; then
            ARCHIVE_SIZE=$(du -h "${NODE_NAME}.apkovl.tar.gz" | cut -f1)
            log_success "Created ${NODE_NAME}.apkovl.tar.gz (${ARCHIVE_SIZE})"
            CREATED_COUNT=$((CREATED_COUNT + 1))
        else
            log_error "Failed to create valid archive for ${NODE_NAME}"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    else
        log_error "Failed to create archive for ${NODE_NAME}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi

done < <(yaml_get_nodes)

# Summary
echo ""
log_info "=== Summary ==="
TOTAL_NODES=$(yaml_get_nodes | wc -l)

log_info "Total nodes in config: $TOTAL_NODES"
log_info "Archives created: $CREATED_COUNT"
log_info "Failed/skipped: $FAILED_COUNT"

if [ "$CREATED_COUNT" -gt 0 ]; then
    echo ""
    log_info "Created apkovl archives:"
    yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
        if [ -f "${NODE_NAME}.apkovl.tar.gz" ]; then
            ARCHIVE_SIZE=$(du -h "${NODE_NAME}.apkovl.tar.gz" | cut -f1)
            echo "  • ${NODE_NAME}.apkovl.tar.gz (${ARCHIVE_SIZE}) - ${NODE_ROLE} node"
        fi
    done

    echo ""
    log_info "Next steps:"
    echo "1. Setup SD cards: sudo ./setup-sd-card.sh /dev/diskN $CONFIG_FILE"
    echo "2. Copy apkovl files to SD card boot partitions:"

    yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
        if [ -f "${NODE_NAME}.apkovl.tar.gz" ]; then
            echo "   cp ${NODE_NAME}.apkovl.tar.gz /Volumes/BOOT/"
        fi
    done

    echo "3. Insert SD cards and boot your cluster!"
fi

if [ "$FAILED_COUNT" -gt 0 ]; then
    echo ""
    log_warn "Some archives failed to create. Check the apkovl directories exist and have content."
fi

# Cleanup temp files
# No temporary files to clean up anymore

echo ""
if [ "$CREATED_COUNT" -eq "$TOTAL_NODES" ]; then
    log_success "All apkovl archives created successfully!"
    exit 0
elif [ "$CREATED_COUNT" -gt 0 ]; then
    log_warn "Partial success: $CREATED_COUNT of $TOTAL_NODES archives created"
    exit 0
else
    log_error "No archives were created"
    exit 1
fi