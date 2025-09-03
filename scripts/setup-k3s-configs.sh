#!/bin/bash

# K3s configuration setup for Alpine diskless

NODES=("k3s-21" "k3s-22" "k3s-23")
MASTER_NODE="k3s-21"
MASTER_IP="192.168.1.21"

# Generate random k3s token
K3S_TOKEN=$(openssl rand -hex 32)
echo "Generated K3S_TOKEN: $K3S_TOKEN"
echo "$K3S_TOKEN" > k3s-token.txt

for i in "${!NODES[@]}"; do
    NODE="${NODES[$i]}"
    
    echo "Setting up K3s configuration for $NODE..."
    
    # Create K3s directory if not exists
    mkdir -p "apkovl-${NODE}/etc/k3s"
    
    if [ "$NODE" = "$MASTER_NODE" ]; then
        # Master node configuration
        cat > "apkovl-${NODE}/etc/k3s/config.yaml" << EOF
write-kubeconfig-mode: "0644"
cluster-init: true
disable:
  - servicelb
  - traefik
node-taint:
  - "CriticalAddonsOnly=true:NoExecute"
bind-address: 0.0.0.0
advertise-address: $MASTER_IP
node-ip: $MASTER_IP
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
flannel-backend: "vxlan"
EOF

        # Master startup script
        cat > "apkovl-${NODE}/etc/init.d/k3s" << EOF
#!/sbin/openrc-run

name="k3s"
description="Lightweight Kubernetes"
command="/usr/local/bin/k3s"
command_args="server --config /etc/k3s/config.yaml --token $K3S_TOKEN"
command_background="yes"
pidfile="/var/run/k3s.pid"
command_user="root"
start_stop_daemon_args="--make-pidfile"

depend() {
    need net
    after local
    provide k3s
}

start_pre() {
    # Ensure cgroups are properly set up
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        # cgroup v2
        echo "+cpu +memory +pids" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    fi
    
    # Load required kernel modules
    modprobe br_netfilter 2>/dev/null || true
    modprobe overlay 2>/dev/null || true
    
    # Set kernel parameters
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    
    return 0
}
EOF

    else
        # Agent node configuration
        cat > "apkovl-${NODE}/etc/k3s/config.yaml" << EOF
server: https://$MASTER_IP:6443
node-ip: ${IPS[$i]}
EOF

        # Agent startup script
        cat > "apkovl-${NODE}/etc/init.d/k3s" << EOF
#!/sbin/openrc-run

name="k3s"
description="Lightweight Kubernetes Agent"
command="/usr/local/bin/k3s"
command_args="agent --config /etc/k3s/config.yaml --token $K3S_TOKEN"
command_background="yes"
pidfile="/var/run/k3s.pid"
command_user="root"
start_stop_daemon_args="--make-pidfile"

depend() {
    need net
    after local
    provide k3s
}

start_pre() {
    # Wait for master to be ready
    timeout=300
    while [ \$timeout -gt 0 ]; do
        if nc -z $MASTER_IP 6443; then
            break
        fi
        sleep 5
        timeout=\$((timeout - 5))
    done
    
    # Load required kernel modules
    modprobe br_netfilter 2>/dev/null || true
    modprobe overlay 2>/dev/null || true
    
    # Set kernel parameters
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    
    return 0
}
EOF
    fi
    
    chmod +x "apkovl-${NODE}/etc/init.d/k3s"
    
    # Add k3s to default runlevel
    ln -sf /etc/init.d/k3s "apkovl-${NODE}/etc/runlevels/default/k3s"
    
    # Install k3s script
    cat > "apkovl-${NODE}/etc/local.d/install-k3s.start" << 'EOF'
#!/bin/sh

# Install k3s if not present
if [ ! -f /usr/local/bin/k3s ]; then
    echo "Installing k3s..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true sh -
    
    # Enable required services
    rc-update add cgroups boot
    rc-update add local default
fi
EOF
    chmod +x "apkovl-${NODE}/etc/local.d/install-k3s.start"

done

echo "K3s configurations created for all nodes"
echo "K3s token saved to k3s-token.txt"