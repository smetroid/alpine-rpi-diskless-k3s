#!/bin/bash

# Wrapper script to maintain backward compatibility
# Calls the actual build script in the scripts directory

set -e

CONFIG_FILE="${1:-cluster-config.yaml}"

echo "🚀 Alpine Diskless k3s Build System"
echo "📂 Project structure: scripts/ builds/ lib/"
echo ""

# Check if configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: Configuration file '$CONFIG_FILE' not found"
    echo ""
    echo "Please create cluster-config.yaml or specify a different file:"
    echo "  $0 your-config.yaml"
    exit 1
fi

# Create builds directory if it doesn't exist
mkdir -p builds

# Get absolute paths before changing directories  
# Handle both relative and absolute config file paths
if [[ "$CONFIG_FILE" = /* ]]; then
    ABSOLUTE_CONFIG="$CONFIG_FILE"
else
    ABSOLUTE_CONFIG="$(pwd)/$CONFIG_FILE"
fi
ABSOLUTE_BUILD="$(pwd)/builds"
ABSOLUTE_SCRIPT="$(pwd)/scripts"
ABSOLUTE_LIB="$(pwd)/lib"

# Export absolute paths for scripts to use
export CONFIG_FILE="$ABSOLUTE_CONFIG"
export BUILD_DIR="$ABSOLUTE_BUILD"
export SCRIPT_DIR="$ABSOLUTE_SCRIPT"
export LIB_DIR="$ABSOLUTE_LIB"

# Call the actual build script
cd scripts
./build-from-yaml.sh "$ABSOLUTE_CONFIG"
cd ..

echo ""
echo "✅ Build complete!"
echo "📦 Generated files in builds/ directory"
echo "🔍 Check builds/ for apkovl directories and .tar.gz files"