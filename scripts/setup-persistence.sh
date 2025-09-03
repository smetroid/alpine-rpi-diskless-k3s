#!/bin/bash

# Setup persistence and boot scripts for Alpine diskless k3s

NODES=("k3s-21" "k3s-22" "k3s-23")

for NODE in "${NODES[@]}"; do
    echo "Setting up persistence for $NODE..."
    
    # Create Alpine configuration backup script
    cat > "apkovl-${NODE}/etc/local.d/backup-config.start" << 'EOF'
#!/bin/sh

# Create persistent backup of Alpine configuration
echo "Backing up Alpine configuration..."

# Wait for storage to be mounted
sleep 10

# Backup important system files
mkdir -p /mnt/data/alpine-backup/{etc,root}

# System configuration
cp -f /etc/hostname /mnt/data/alpine-backup/etc/ 2>/dev/null || true
cp -f /etc/resolv.conf /mnt/data/alpine-backup/etc/ 2>/dev/null || true
cp -rf /etc/network /mnt/data/alpine-backup/etc/ 2>/dev/null || true
cp -rf /etc/ssh /mnt/data/alpine-backup/etc/ 2>/dev/null || true

# Root user files
cp -rf /root/.ssh /mnt/data/alpine-backup/root/ 2>/dev/null || true

# K3s configuration
cp -rf /etc/k3s /mnt/data/alpine-backup/etc/ 2>/dev/null || true

sync
EOF
    chmod +x "apkovl-${NODE}/etc/local.d/backup-config.start"
    
    # Create restoration script
    cat > "apkovl-${NODE}/etc/local.d/restore-config.start" << 'EOF'
#!/bin/sh

# Restore Alpine configuration from persistent storage
echo "Restoring Alpine configuration..."

if [ -d /mnt/data/alpine-backup ]; then
    # Restore system configuration
    cp -rf /mnt/data/alpine-backup/etc/* /etc/ 2>/dev/null || true
    cp -rf /mnt/data/alpine-backup/root/* /root/ 2>/dev/null || true
    
    # Set proper permissions
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
    chmod 700 /root/.ssh 2>/dev/null || true
    chmod 600 /etc/ssh/ssh_host_* 2>/dev/null || true
fi
EOF
    chmod +x "apkovl-${NODE}/etc/local.d/restore-config.start"
    
    # Create cgroups configuration for k3s
    cat > "apkovl-${NODE}/etc/cgconfig.conf" << 'EOF'
# cgroup configuration for k3s
mount {
    cpuacct = /sys/fs/cgroup/cpuacct;
    memory = /sys/fs/cgroup/memory;
    devices = /sys/fs/cgroup/devices;
    freezer = /sys/fs/cgroup/freezer;
    net_cls = /sys/fs/cgroup/net_cls;
    blkio = /sys/fs/cgroup/blkio;
    cpuset = /sys/fs/cgroup/cpuset;
    cpu = /sys/fs/cgroup/cpu;
}
EOF

    # Kernel modules for k3s
    cat > "apkovl-${NODE}/etc/modules" << 'EOF'
# Kernel modules needed for k3s
br_netfilter
overlay
nf_conntrack
xt_conntrack
xt_MASQUERADE
iptable_nat
iptable_filter
ip_tables
EOF

    # Sysctl configuration for k3s
    cat > "apkovl-${NODE}/etc/sysctl.d/k3s.conf" << 'EOF'
# Kubernetes/k3s sysctl settings
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.overcommit_memory = 1
kernel.panic = 10
kernel.panic_on_oops = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

    # Create apkovl save script
    cat > "apkovl-${NODE}/etc/local.d/save-apkovl.stop" << EOF
#!/bin/sh

# Save current configuration to apkovl
echo "Saving configuration to apkovl..."

# Create apkovl on persistent storage
lbu_media=/mnt/data
lbu commit

sync
EOF
    chmod +x "apkovl-${NODE}/etc/local.d/save-apkovl.stop"

done

echo "Persistence scripts created for all nodes"