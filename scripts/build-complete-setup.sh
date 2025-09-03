#!/bin/bash

# Complete Alpine diskless k3s setup builder
# This script runs all setup steps in the correct order

set -e

echo "=== Alpine Diskless k3s Setup Builder ==="
echo "Building complete 3-node k3s cluster setup..."
echo ""

# Step 1: Create apkovl structure
echo "Step 1: Creating apkovl structure..."
./create-apkovl.sh

# Step 2: Setup k3s configurations
echo ""
echo "Step 2: Setting up k3s configurations..."
./setup-k3s-configs.sh

# Step 3: Setup persistence
echo ""
echo "Step 3: Setting up persistence scripts..."
./setup-persistence.sh

# Step 4: Setup master node manifests
echo ""
echo "Step 4: Setting up master node manifests..."
./setup-master-manifests.sh

# Step 5: Finalize apkovl
echo ""
echo "Step 5: Finalizing apkovl structure..."
./finalize-apkovl.sh

# Step 6: Create apkovl archives
echo ""
echo "Step 6: Creating apkovl archives..."
./create-k3s-21-apkovl.sh
./create-k3s-22-apkovl.sh
./create-k3s-23-apkovl.sh

echo ""
echo "=== Setup Complete! ==="
echo ""
echo "Files created:"
echo "  - k3s-21.apkovl.tar.gz (Master node)"
echo "  - k3s-22.apkovl.tar.gz (Worker node 1)"
echo "  - k3s-23.apkovl.tar.gz (Worker node 2)"
echo "  - k3s-token.txt (Cluster join token)"
echo ""
echo "Next steps:"
echo "1. Prepare 3 SD cards using: sudo ./setup-sd-card.sh /dev/sdX"
echo "2. Copy each .apkovl.tar.gz file to the corresponding SD card boot partition"
echo "3. Insert SD cards and power on nodes (master first, then workers)"
echo "4. Wait 5-10 minutes for complete cluster initialization"
echo ""
echo "Access your cluster:"
echo "  Master node: ssh root@192.168.1.21"
echo "  Worker nodes: ssh root@192.168.1.22, ssh root@192.168.1.23"
echo ""
echo "Verify deployment: kubectl get nodes -o wide"