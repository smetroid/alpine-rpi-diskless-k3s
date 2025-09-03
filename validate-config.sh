#!/bin/bash

# Wrapper script for validate-config.sh

set -e

CONFIG_FILE="${1:-cluster-config.yaml}"

# Set up environment
export CONFIG_FILE="$(pwd)/$CONFIG_FILE"
export BUILD_DIR="$(pwd)/builds"
export SCRIPT_DIR="$(pwd)/scripts"
export LIB_DIR="$(pwd)/lib"

# Call the actual script
"$SCRIPT_DIR/validate-config.sh" "$CONFIG_FILE"