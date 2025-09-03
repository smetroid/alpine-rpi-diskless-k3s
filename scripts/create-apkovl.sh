#!/bin/bash

# Alpine diskless k3s setup script
# Creates apkovl files for 3-node k3s cluster

NODES=("k3s-21" "k3s-22" "k3s-23")
IPS=("192.168.1.21" "192.168.1.22" "192.168.1.23")
MASTER_NODE="k3s-21"
MASTER_IP="192.168.1.21"

# Create apkovl directories for each node
for i in "${!NODES[@]}"; do
    NODE="${NODES[$i]}"
    IP="${IPS[$i]}"
    
    echo "Creating apkovl for $NODE ($IP)..."
    
    # Create directory structure
    mkdir -p "apkovl-${NODE}"/{etc/{hostname,network,ssh,runlevels/{default,boot,sysinit},init.d,k3s,local.d},root/.ssh,var/lib/k3s}
    
    # Set hostname
    echo "$NODE" > "apkovl-${NODE}/etc/hostname"
    
    # Network configuration
    cat > "apkovl-${NODE}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address $IP
    netmask 255.255.255.0
    gateway 192.168.1.254
    dns-nameservers 192.168.1.254
    dns-domain local
EOF
    
    # Resolve configuration
    cat > "apkovl-${NODE}/etc/resolv.conf" << EOF
nameserver 192.168.1.254
domain local
search local
EOF
    
    # SSH daemon configuration
    cat > "apkovl-${NODE}/etc/ssh/sshd_config" << EOF
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_dsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePrivilegeSeparation yes
KeyRegenerationInterval 3600
ServerKeyBits 1024
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime 120
PermitRootLogin yes
StrictModes yes
RSAAuthentication yes
PubkeyAuthentication yes
IgnoreRhosts yes
RhostsRSAAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
PasswordAuthentication yes
X11Forwarding no
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
EOF

    # Create mount script for persistent storage
    cat > "apkovl-${NODE}/etc/local.d/mount-storage.start" << 'EOF'
#!/bin/sh

# Wait for SD card to be available
sleep 5

# Create data partition if it doesn't exist
if ! blkid /dev/mmcblk0p2 > /dev/null 2>&1; then
    echo "Creating data partition..."
    echo -e "n\np\n2\n\n\nw" | fdisk /dev/mmcblk0
    sleep 2
    mkfs.ext4 -F /dev/mmcblk0p2
fi

# Mount persistent storage
mkdir -p /mnt/data
mount /dev/mmcblk0p2 /mnt/data

# Create necessary directories
mkdir -p /mnt/data/{k3s,etc-persistent,var-lib-k3s}

# Bind mount persistent directories
mkdir -p /etc/k3s
mount --bind /mnt/data/k3s /etc/k3s

mkdir -p /var/lib/k3s
mount --bind /mnt/data/var-lib-k3s /var/lib/k3s

# Restore persistent etc files
if [ -d /mnt/data/etc-persistent ]; then
    cp -r /mnt/data/etc-persistent/* /etc/ 2>/dev/null || true
fi
EOF
    chmod +x "apkovl-${NODE}/etc/local.d/mount-storage.start"
    
    # Create save script for persistent data
    cat > "apkovl-${NODE}/etc/local.d/save-persistent.stop" << 'EOF'
#!/bin/sh

# Save persistent etc files
mkdir -p /mnt/data/etc-persistent
cp -r /etc/k3s /mnt/data/etc-persistent/ 2>/dev/null || true
cp /etc/hostname /mnt/data/etc-persistent/ 2>/dev/null || true
cp /etc/resolv.conf /mnt/data/etc-persistent/ 2>/dev/null || true

# Sync data
sync
EOF
    chmod +x "apkovl-${NODE}/etc/local.d/save-persistent.stop"

done

echo "Base apkovl structure created for all nodes"