#!/bin/bash

# Wrapper script for setup-sd-card.sh

set -e

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <sd_card_device> [config_file]"
    echo "Example: $0 /dev/sdb"
    echo "Example: $0 /dev/sdb my-cluster.yaml"
    exit 1
fi

SD_DEVICE=$1
CONFIG_FILE="${2:-cluster-config.yaml}"

# Set up environment
export CONFIG_FILE="$(pwd)/$CONFIG_FILE"
export BUILD_DIR="$(pwd)/builds"
export SCRIPT_DIR="$(pwd)/scripts"
export LIB_DIR="$(pwd)/lib"

# Call the actual script
"$SCRIPT_DIR/setup-sd-card.sh" "$SD_DEVICE" "$CONFIG_FILE"