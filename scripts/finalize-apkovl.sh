#!/bin/bash

# Finalize apkovl creation with startup initialization

NODES=("k3s-21" "k3s-22" "k3s-23")

for NODE in "${NODES[@]}"; do
    echo "Finalizing apkovl for $NODE..."
    
    # Create main system initialization script
    cat > "apkovl-${NODE}/etc/local.d/00-system-init.start" << 'EOF'
#!/bin/sh

echo "Starting Alpine diskless k3s initialization..."

# Set up package repositories
cat > /etc/apk/repositories << 'REPOS'
http://dl-cdn.alpinelinux.org/alpine/v3.18/main
http://dl-cdn.alpinelinux.org/alpine/v3.18/community
REPOS

# Update package index
apk update

# Install required packages
apk add --no-cache \
    curl \
    ca-certificates \
    iptables \
    ip6tables \
    util-linux \
    coreutils \
    findutils \
    netcat-openbsd \
    cgroup-tools

# Enable services
rc-update add networking boot
rc-update add urandom boot
rc-update add hostname boot
rc-update add sysctl boot
rc-update add modules boot
rc-update add sshd default
rc-update add local default
rc-update add savecache shutdown

# Configure LBU (Local Backup Utility)
lbu_media=/mnt/data
echo "$lbu_media" > /etc/lbu/lbu.conf

echo "System initialization complete"
EOF
    chmod +x "apkovl-${NODE}/etc/local.d/00-system-init.start"
    
    # Create service dependencies
    cat > "apkovl-${NODE}/etc/local.d/99-start-services.start" << 'EOF'
#!/bin/sh

echo "Starting final services..."

# Ensure all required services are running
rc-service networking start 2>/dev/null || true
rc-service sshd start 2>/dev/null || true

# Start k3s after a delay to ensure system is ready
(sleep 30 && rc-service k3s start) &

echo "All services initialization complete"
EOF
    chmod +x "apkovl-${NODE}/etc/local.d/99-start-services.start"
    
    # Create apkovl package script
    cat > "create-${NODE}-apkovl.sh" << EOF
#!/bin/bash

# Create apkovl for $NODE

echo "Creating apkovl for $NODE..."

cd apkovl-${NODE}

# Create the apkovl archive
tar -czf ../${NODE}.apkovl.tar.gz .

echo "Created ${NODE}.apkovl.tar.gz"
echo "Copy this file to the boot partition of your SD card"
EOF
    chmod +x "create-${NODE}-apkovl.sh"
    
done

echo "Apkovl finalization complete for all nodes"