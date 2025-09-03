#!/bin/bash

# Setup k3s manifests on master node for automatic deployment

NODE="k3s-21"

echo "Setting up k3s manifests for automatic deployment on master node..."

# Create manifests directory in apkovl
mkdir -p "apkovl-${NODE}/mnt/data/k3s-manifests"

# Copy manifest files
cp k3s-manifests/*.yaml "apkovl-${NODE}/mnt/data/k3s-manifests/"

# Create deployment script in apkovl
cp deploy-manifests.sh "apkovl-${NODE}/mnt/data/"
chmod +x "apkovl-${NODE}/mnt/data/deploy-manifests.sh"

# Create auto-deploy script for master node
cat > "apkovl-${NODE}/etc/local.d/deploy-k3s-manifests.start" << 'EOF'
#!/bin/sh

# Auto-deploy k3s manifests after cluster is ready
# This script runs on the master node only

echo "Setting up automatic k3s manifest deployment..."

# Wait for k3s to be fully ready (give it 2 minutes)
sleep 120

# Check if we're the master node and k3s is running
if [ -f /var/lib/rancher/k3s/server/node-token ]; then
    echo "Master node detected, deploying manifests..."
    
    # Run deployment in background
    (
        sleep 30
        cd /mnt/data
        ./deploy-manifests.sh > /var/log/k3s-manifest-deploy.log 2>&1
    ) &
fi
EOF
chmod +x "apkovl-${NODE}/etc/local.d/deploy-k3s-manifests.start"

echo "Master node manifest setup complete"