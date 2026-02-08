#!/bin/bash

# Alpine diskless k3s setup script using YAML configuration
# Creates apkovl files for all nodes defined in cluster-config.yaml

set -e

# Source and library directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(cd "$SCRIPT_DIR/../lib" && pwd)}"

# Load cache library
source "$LIB_DIR/cache.sh"

# Function to discover package version from APKINDEX
# Returns the version string for the given package name
discover_package_version() {
    local package_name="$1"
    local apkindex_dir="$2"

    # The APKINDEX file has format: C:package_name\nV:version\nA:architecture...
    # We need to find the package and extract its version
    awk -v pkg="$package_name" '
        BEGIN { found=0 }
        /^P:/ {
            if ($0 == "P:" pkg) {
                found=1
            } else {
                found=0
            }
        }
        /^V:/ && found {
            print substr($0, 3)
            found=0
            exit
        }
    ' "$apkindex_dir/APKINDEX"
}

# Process overlay packages from YAML config
# Downloads and extracts packages to overlay for early boot availability
process_overlay_packages() {
    local apkovl_dir="$1"
    local config_file="$2"
    local arch=$(yaml_get "alpine.architecture" "$config_file")
    local alpine_version=$(yaml_get "alpine.version" "$config_file")
    local alpine_major=$(echo "$alpine_version" | cut -d'.' -f1-2)
    local base_url="http://dl-cdn.alpinelinux.org/alpine/v${alpine_major}/main/${arch}"

    local packages=$(yaml_get_array ".overlay_packages[].name" "$config_file")

    if [ -z "$packages" ]; then
        echo "No overlay packages specified"
        return 0
    fi

    echo "Processing overlay packages..."

    # Use temporary directory for APKINDEX (not cached, it's small and changes frequently)
    local tmp_dir="/tmp/overlay-packages-cache-$$_"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    if ! curl -sL "${base_url}/APKINDEX.tar.gz" -o "$tmp_dir/APKINDEX.tar.gz"; then
        echo "Error: Failed to download APKINDEX"
        rm -rf "$tmp_dir"
        return 1
    fi

    tar -xzf "$tmp_dir/APKINDEX.tar.gz" -C "$tmp_dir"

    # Process each package
    while IFS= read -r pkg_name; do
        [ -z "$pkg_name" ] && continue
        echo "Processing overlay package: $pkg_name"

        # Discover version using discover_package_version function
        local version=$(discover_package_version "$pkg_name" "$tmp_dir")
        if [ -z "$version" ]; then
            echo "Error: Package $pkg_name not found in APKINDEX"
            rm -rf "$tmp_dir"
            return 1
        fi

        echo "Found $pkg_name version: $version"

        # Generate cache key for this package
        local cache_key=$(cache_key_apk "$arch" "$pkg_name" "$version")
        local apk_file="${tmp_dir}/${pkg_name}.apk"

        # Try to get from cache first
        if cache_get "apk" "$cache_key" "$apk_file"; then
            # Cache hit - use cached file
            :
        else
            # Cache miss - download from internet
            if ! curl -sL "${base_url}/${pkg_name}-${version}.apk" -o "$apk_file"; then
                echo "Error: Failed to download $pkg_name"
                rm -rf "$tmp_dir"
                return 1
            fi
            # Store in cache for next time
            cache_put "apk" "$cache_key" "$apk_file"
        fi

        # Extract entire package to overlay
        # This includes: binaries, libraries, config files, documentation
        tar -xzf "$apk_file" -C "$apkovl_dir"

        echo "Added $pkg_name to overlay"
    done <<< "$packages"

    # Clean up temp directory
    rm -rf "$tmp_dir"
    echo "Overlay packages processing complete"
}

# Generate auto-start service configuration
# Creates a service that installs packages and starts services at boot
generate_auto_start_services() {
    local apkovl_dir="$1"
    local config_file="$2"

    local packages=$(yaml_get_array ".auto_start_services[]" "$config_file")

    if [ -z "$packages" ]; then
        echo "No auto-start services configured"
        return 0
    fi

    echo "Generating auto-start services configuration..."

    # Build packages list for the service script
    local pkg_list=""
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        pkg_list="$pkg_list $pkg"
    done <<< "$packages"

    # Trim leading space
    pkg_list=$(echo "$pkg_list" | sed 's/^ //')

    if [ -z "$pkg_list" ]; then
        echo "  No packages to configure"
        return 0
    fi

    echo "  Configuring: $pkg_list"

    # Create the auto-start service script
    cat > "${apkovl_dir}/etc/init.d/auto-start-services" <<'SERVICE_SCRIPT'
#!/sbin/openrc-run

# Auto-start services - installs packages and starts services at boot
# Generated from cluster-config.yaml auto_start_services section

description="Install and start configured services"

depend() {
    need net
    after firewall storage-init
    before k3s-bootstrap
}

start() {
    ebegin "Installing and starting auto-start services"

    local failed=0
    # Packages to install (injected during build)
    PACKAGES="__PACKAGES__"

    for pkg in $PACKAGES; do
        # Skip empty entries
        [ -z "$pkg" ] && continue

        # Package already installed? Skip installation
        if apk info -e "$pkg" >/dev/null 2>&1; then
            einfo "$pkg already installed"
        else
            # Try installation, but don't fail hard
            einfo "Installing $pkg..."
            if ! apk add -q "$pkg"; then
                ewarn "Failed to install $pkg (will retry next boot)"
                failed=1
                continue
            fi
        fi

        # Derive service name from package name
        svc=$(derive_service_name "$pkg")

        # Service exists? Enable and start it
        if [ -f "/etc/init.d/$svc" ]; then
            # Enable service in default runlevel (ensures proper dependency tracking)
            if ! rc-update show default | grep -q "$svc"; then
                einfo "Enabling $svc in default runlevel..."
                rc-update add "$svc" default >/dev/null 2>&1
            fi

            if rc-service "$svc" status >/dev/null 2>&1; then
                einfo "$svc already running"
            else
                einfo "Starting $svc..."
                if ! rc-service "$svc" start; then
                    ewarn "Failed to start $svc"
                fi
            fi
        else
            einfo "No service found for $pkg (package-only)"
        fi
    done

    # Always return success - boot should continue even if one service fails
    eend 0
}

derive_service_name() {
    local pkg="$1"
    case "$pkg" in
        nfs-utils)      echo "nfs" ;;
        chrony)         echo "chronyd" ;;
        rpcbind)        echo "rpcbind" ;;
        acpid)          echo "acpid" ;;
        syslog)         echo "syslog" ;;
        cron)           echo "crond" ;;
        sshd)           echo "sshd" ;;
        *)
            # Fallback: strip common suffixes
            echo "$pkg" | sed 's/-utils$//' | sed 's/-openrc$//'
            ;;
    esac
}
SERVICE_SCRIPT

    # Replace placeholder with actual packages list
    # Use portable sed syntax (works on both Linux and macOS)
    sed "s/__PACKAGES__/$pkg_list/g" "${apkovl_dir}/etc/init.d/auto-start-services" > "${apkovl_dir}/etc/init.d/auto-start-services.tmp" && \
    mv "${apkovl_dir}/etc/init.d/auto-start-services.tmp" "${apkovl_dir}/etc/init.d/auto-start-services"

    chmod +x "${apkovl_dir}/etc/init.d/auto-start-services"

    # Enable in default runlevel
    ln -sf /etc/init.d/auto-start-services "${apkovl_dir}/etc/runlevels/default/auto-start-services"

    echo "  ✓ auto-start-services service created and enabled"
}

# Download k3s binary for target architecture
# Downloads from GitHub releases and places in apkovl /usr/local/bin/k3s
download_k3s_binary() {
    local apkovl_dir="$1"
    local config_file="$2"
    local arch=$(yaml_get "alpine.architecture" "$config_file")
    local version=$(yaml_get "cluster.k3s_version" "$config_file")

    # Map Alpine architecture names to k3s/GitHub release architecture names
    case "$arch" in
        aarch64) k3s_arch="arm64" ;;
        armv7|armhf) k3s_arch="arm" ;;
        armv6) k3s_arch="arm" ;;
        x86_64) k3s_arch="amd64" ;;
        x86) k3s_arch="386" ;;
        *) k3s_arch="$arch" ;;
    esac

    # Build URL - k3s uses architecture suffix in filenames
    # amd64 (x86_64) uses just "k3s", other arches use suffix
    if [ "$k3s_arch" = "amd64" ]; then
        local url="https://github.com/k3s-io/k3s/releases/download/${version}/k3s"
    else
        local url="https://github.com/k3s-io/k3s/releases/download/${version}/k3s-${k3s_arch}"
    fi
    local dest="${apkovl_dir}/usr/local/bin/k3s"

    # Generate cache key
    local cache_key=$(cache_key_k3s "$version" "$k3s_arch")
    local tmp_file="/tmp/k3s-download-$$_${cache_key}"

    # Try to get from cache first
    if cache_get "k3s" "$cache_key" "$tmp_file"; then
        # Cache hit - verify and use cached binary
        if ! file "$tmp_file" | grep -q "ELF"; then
            echo "⚠️  Cached k3s binary is corrupted, re-downloading"
            rm -f "$tmp_file"
        else
            # Valid cached file
            mv "$tmp_file" "$dest"
            echo "Using cached k3s ${version} (${k3s_arch})"
        fi
    fi

    # Download if not in cache or cache was corrupted
    if [ ! -f "$dest" ]; then
        echo "Downloading k3s ${version} (${k3s_arch})..."

        # Download with error handling
        if ! curl -fL --progress-bar "${url}" -o "$tmp_file"; then
            echo "❌ Error: Failed to download k3s binary"
            echo "   URL: ${url}"
            echo "   Check version at: https://github.com/k3s-io/k3s/releases"
            rm -f "$tmp_file"
            return 1
        fi

        # Verify it's a valid ELF binary (Linux executable)
        if ! file "$tmp_file" | grep -q "ELF"; then
            echo "❌ Error: Downloaded file is not a valid ELF binary"
            file "$tmp_file"
            rm -f "$tmp_file"
            return 1
        fi

        # Verify file size (k3s is ~50MB+, warn if too small)
        local size=$(stat -f%z "$tmp_file" 2>/dev/null || stat -c%s "$tmp_file" 2>/dev/null || echo "0")
        if [ "$size" -lt 10000000 ]; then
            echo "⚠️  Warning: Downloaded binary seems too small (${size} bytes)"
            echo "   Expected k3s binary to be ~50MB+"
            echo "   This may indicate a partial download or wrong architecture"
            rm -f "$tmp_file"
            return 1
        fi

        # Store in cache for next time (before moving to destination)
        cache_put "k3s" "$cache_key" "$tmp_file"

        # Move to destination
        mv "$tmp_file" "$dest"
    fi

    # Make executable
    chmod +x "$dest"

    # Create symlinks for k3s embedded commands
    # The k3s binary provides kubectl, crictl, and ctr functionality
    # when invoked via these symlinks (same as official install script)
    echo "Creating k3s utility symlinks..."
    for cmd in kubectl crictl ctr; do
        ln -sf k3s "${apkovl_dir}/usr/local/bin/${cmd}"
        echo "  ✓ ${cmd} -> k3s"
    done

    echo "✅ k3s ${version} downloaded ($(du -h "$dest" | cut -f1))"
}

# Use the config file from environment, or from parameter, or default
CONFIG_FILE="${CONFIG_FILE:-${1:-cluster-config.yaml}}"

echo "Creating apkovl structure from YAML configuration..."
echo "Using configuration file: $CONFIG_FILE"

# Check if configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: Configuration file '$CONFIG_FILE' not found"
    echo ""
    echo "Usage: $0 [config_file]"
    echo "Example: $0 my-cluster.yaml"
    echo "Default: $0  (uses cluster-config.yaml)"
    exit 1
fi

# Export config file for yaml-parser
export CONFIG_FILE

# Load YAML parser
source "$LIB_DIR/yaml-parser.sh"

# Validate configuration
echo "Validating configuration..."
if ! validate_config; then
    exit 1
fi

# Get configuration values
CLUSTER_NAME=$(get_cluster_name)
GATEWAY=$(get_network_gateway)
DNS_SERVERS=($(get_dns_servers))
DOMAIN=$(yaml_get "network.domain")

echo "Cluster: $CLUSTER_NAME"
echo "Gateway: $GATEWAY"
echo "DNS: ${DNS_SERVERS[*]}"
echo ""

# Generate cluster-wide SSH key pair for inter-node communication
# This allows workers to SSH into masters to retrieve k3s join tokens
echo "Generating cluster SSH key pair for inter-node communication..."
CLUSTER_KEY_DIR=".cluster_ssh_keys"
mkdir -p "$CLUSTER_KEY_DIR"

if [ ! -f "$CLUSTER_KEY_DIR/cluster_id_rsa" ]; then
    ssh-keygen -t rsa -f "$CLUSTER_KEY_DIR/cluster_id_rsa" -N "" -q
    echo "✅ Cluster SSH key pair generated"
else
    echo "✅ Using existing cluster SSH key pair"
fi

# Read the public key
CLUSTER_PUBLIC_KEY=$(cat "$CLUSTER_KEY_DIR/cluster_id_rsa.pub")

# Process each node
yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    echo "Creating apkovl for $NODE_NAME ($NODE_IP) - $NODE_ROLE..."
    
    # Create directory structure
    mkdir -p "${NODE_NAME}-apkovl"/{etc/{apk,network,ssh,runlevels/{default,boot,sysinit},init.d,local.d,sysctl.d},root/.ssh,var/lib/k3s,usr/local/bin}

    # Process overlay packages from YAML config
    process_overlay_packages "${NODE_NAME}-apkovl" "$CONFIG_FILE"

    # Generate auto-start services configuration
    generate_auto_start_services "${NODE_NAME}-apkovl" "$CONFIG_FILE"

    # Download k3s binary for target architecture
    download_k3s_binary "${NODE_NAME}-apkovl" "$CONFIG_FILE"

    # Set hostname
    echo "$NODE_NAME" > "${NODE_NAME}-apkovl/etc/hostname"

    # Generate machine-id for k3s/containerd node identification
    # This prevents k3s warnings about missing /etc/machine-id and ensures
    # consistent node identification across reboots
    # https://gitlab.alpinelinux.org/alpine/aports/-/issues/8761
    if command -v uuidgen >/dev/null 2>&1; then
        # macOS and most systems have uuidgen
        uuidgen | tr '[:upper:]' '[:lower:]' > "${NODE_NAME}-apkovl/etc/machine-id"
    else
        # Fallback: generate a random UUID
        # Uses node name + timestamp + random for uniqueness
        echo "$(hostname)-$(date +%s)-$RANDOM" | md5sum | awk '{print $1}' > "${NODE_NAME}-apkovl/etc/machine-id" 2>/dev/null || \
        echo "${NODE_NAME}-$(date +%s%N)" | md5sum | awk '{print $1}' > "${NODE_NAME}-apkovl/etc/machine-id" 2>/dev/null || \
        echo "${NODE_NAME}-$(date +%s)" > "${NODE_NAME}-apkovl/etc/machine-id"
    fi

    # This fixes the /lib/modules directory missing when booting, in turn breaks the image
    # https://gitlab.alpinelinux.org/alpine/mkinitfs/-/issues/8
    touch "${NODE_NAME}-apkovl/etc/.default_boot_services"
    
    # Network configuration - convert CIDR to netmask
    SUBNET=$(yaml_get "network.subnet")
    CIDR_BITS=$(echo "$SUBNET" | cut -d'/' -f2)
    
    # Convert CIDR to netmask (common cases)
    case "$CIDR_BITS" in
        24) NETMASK="255.255.255.0" ;;
        16) NETMASK="255.255.0.0" ;;
        8)  NETMASK="255.0.0.0" ;;
        25) NETMASK="255.255.255.128" ;;
        26) NETMASK="255.255.255.192" ;;
        27) NETMASK="255.255.255.224" ;;
        28) NETMASK="255.255.255.240" ;;
        *)  NETMASK="255.255.255.0" ;; # Default to /24
    esac
    
    cat > "${NODE_NAME}-apkovl/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address $NODE_IP
    netmask $NETMASK
    gateway $GATEWAY
    dns-nameservers ${DNS_SERVERS[0]}
    dns-domain $DOMAIN
EOF
    
    # Resolve configuration
    cat > "${NODE_NAME}-apkovl/etc/resolv.conf" << EOF
nameserver ${DNS_SERVERS[0]}
domain $DOMAIN
search $DOMAIN
EOF

    # APK repositories configuration
    ALPINE_VERSION=$(yaml_get "alpine.version" "$CONFIG_FILE")
    ALPINE_MAJOR=$(echo "$ALPINE_VERSION" | cut -d'.' -f1,2)
    cat > "${NODE_NAME}-apkovl/etc/apk/repositories" << EOF
http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MAJOR}/main
http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MAJOR}/community
EOF

    # SSH daemon configuration
    SSH_PORT=$(yaml_get "ssh.port")
    PERMIT_ROOT=$(yaml_get "ssh.permit_root_login")
    PASS_AUTH=$(yaml_get "ssh.password_authentication")
    
    cat > "${NODE_NAME}-apkovl/etc/ssh/sshd_config" << EOF
Port $SSH_PORT
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePrivilegeSeparation yes
KeyRegenerationInterval 3600
ServerKeyBits 1024
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime 120
PermitRootLogin $([ "$PERMIT_ROOT" = "true" ] && echo "yes" || echo "no")
StrictModes yes
RSAAuthentication yes
PubkeyAuthentication yes
IgnoreRhosts yes
RhostsRSAAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
PasswordAuthentication $([ "$PASS_AUTH" = "true" ] && echo "yes" || echo "no")
X11Forwarding no
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
EOF

    # Add SSH authorized keys if provided (overwrite any existing file)
    rm -f "${NODE_NAME}-apkovl/root/.ssh/authorized_keys"
    yaml_get_array ".ssh.authorized_keys[]" | while read -r key; do
        if [ -n "$key" ]; then
            echo "$key" >> "${NODE_NAME}-apkovl/root/.ssh/authorized_keys"
        fi
    done

    # Add cluster SSH key for inter-node communication
    # This allows workers to SSH into masters to retrieve k3s tokens
    echo "$CLUSTER_PUBLIC_KEY" >> "${NODE_NAME}-apkovl/root/.ssh/authorized_keys"

    # Add cluster private key to each node
    cp -a "$CLUSTER_KEY_DIR/cluster_id_rsa" "${NODE_NAME}-apkovl/root/.ssh/cluster_id_rsa"
    cp -a "$CLUSTER_KEY_DIR/cluster_id_rsa.pub" "${NODE_NAME}-apkovl/root/.ssh/cluster_id_rsa.pub"
    chmod 600 "${NODE_NAME}-apkovl/root/.ssh/cluster_id_rsa"
    chmod 644 "${NODE_NAME}-apkovl/root/.ssh/cluster_id_rsa.pub"

    if [ -f "${NODE_NAME}-apkovl/root/.ssh/authorized_keys" ]; then
        chmod 600 "${NODE_NAME}-apkovl/root/.ssh/authorized_keys"
    fi

    # Configure chrony for NTP time synchronization
    mkdir -p "${NODE_NAME}-apkovl/etc/chrony"
    cat > "${NODE_NAME}-apkovl/etc/chrony/chrony.conf" << EOF
# Use public NTP servers from pool.ntp.org
pool 2.pool.ntp.org iburst

# Record the rate at which the system clock gains/losses time
driftfile /var/lib/chrony/chrony.drift

# Allow the system clock to be stepped in the first three updates
# This is important for diskless systems that may have significant time drift on boot
makestep 1.0 3

# Enable kernel synchronization of the real-time clock (RTC)
rtcsync

# Allow NTP client access from local network
# This allows worker nodes to optionally sync from master node
allow 192.168.0.0/16
allow 10.0.0.0/8

# Serve time even if not synchronized to a time source
local stratum 10

# Log measurements and statistics
logdir /var/log/chrony
EOF

    # Create persistent chrony directory structure
    mkdir -p "${NODE_NAME}-apkovl/var/lib/chrony"

    # Create k3s init script based on node role
    # Matches the official k3s OpenRC init script installed by the package
    if [ "$NODE_ROLE" = "master" ]; then
        cat > "${NODE_NAME}-apkovl/etc/init.d/k3s" << 'K3S_INIT_EOF'
#!/sbin/openrc-run

description="k3s Kubernetes server (master)"
name=k3s
command="/usr/local/bin/k3s"
command_args="server \
    >>/var/log/k3s.log 2>&1"

supervisor=supervise-daemon
output_log=/var/log/k3s.log
error_log=/var/log/k3s.log
pidfile="/var/run/k3s.pid"
respawn_delay=5
respawn_max=0

depend() {
    after network-online
    want cgroups
}

start_pre() {
    rm -f /tmp/k3s.*
}

set -o allexport
if [ -f /etc/environment ]; then . /etc/environment; fi
if [ -f /etc/rancher/k3s/k3s.env ]; then . /etc/rancher/k3s/k3s.env; fi
set +o allexport
K3S_INIT_EOF
        chmod +x "${NODE_NAME}-apkovl/etc/init.d/k3s"
        # Enable k3s in default runlevel for master nodes
        ln -sf /etc/init.d/k3s "${NODE_NAME}-apkovl/etc/runlevels/default/k3s"
    else
        cat > "${NODE_NAME}-apkovl/etc/init.d/k3s" << 'K3S_INIT_EOF'
#!/sbin/openrc-run

description="k3s Kubernetes agent (worker)"
name=k3s
command="/usr/local/bin/k3s"
command_args="agent \
    >>/var/log/k3s.log 2>&1"

supervisor=supervise-daemon
output_log=/var/log/k3s.log
error_log=/var/log/k3s.log
pidfile="/var/run/k3s.pid"
respawn_delay=5
respawn_max=0

depend() {
    after network-online
    want cgroups
}

start_pre() {
    rm -f /tmp/k3s.*
}

set -o allexport
if [ -f /etc/environment ]; then . /etc/environment; fi
if [ -f /etc/rancher/k3s/k3s.env ]; then . /etc/rancher/k3s/k3s.env; fi
set +o allexport
K3S_INIT_EOF
        chmod +x "${NODE_NAME}-apkovl/etc/init.d/k3s"
        # Enable k3s in default runlevel for worker nodes
        ln -sf /etc/init.d/k3s "${NODE_NAME}-apkovl/etc/runlevels/default/k3s"
    fi

    # Create minimal fstab with basic entries to satisfy fstabinfo
    # storage-init handles actual data partition mounting dynamically
    cat > "${NODE_NAME}-apkovl/etc/fstab" << EOF
# Alpine diskless k3s cluster
# Data partition mounting is handled dynamically by storage-init service

# Standard pseudo-filesystems (required for clean boot)
proc            /proc           proc    defaults        0 0
sysfs           /sys            sysfs   defaults        0 0
devpts          /dev/pts        devpts  defaults        0 0
tmpfs           /tmp            tmpfs   nosuid,nodev    0 0
tmpfs           /run            tmpfs   nosuid,nodev    0 0
EOF
    
    # Add services to default runlevel
    mkdir -p "${NODE_NAME}-apkovl/etc/runlevels/default"
    # CRITICAL: Enable local service so that local.d scripts execute
    ln -sf /etc/init.d/local "${NODE_NAME}-apkovl/etc/runlevels/default/local"
    # CRITICAL: Enable networking service for network connectivity
    ln -sf /etc/init.d/networking "${NODE_NAME}-apkovl/etc/runlevels/default/networking"
    # Note: chronyd is enabled at runtime by system-bootstrap after chrony package is installed
    # Enable storage-init service to run before system-bootstrap
    ln -sf /etc/init.d/storage-init "${NODE_NAME}-apkovl/etc/runlevels/default/storage-init"
    # Enable ssh-persist service to run after storage-init (idempotent SSH on every boot)
    ln -sf /etc/init.d/ssh-persist "${NODE_NAME}-apkovl/etc/runlevels/default/ssh-persist"
    # Enable k3s-worker-token service to retrieve join token from master (worker nodes only)
    ln -sf /etc/init.d/k3s-worker-token "${NODE_NAME}-apkovl/etc/runlevels/default/k3s-worker-token"

    # Note: QEMU test device setup moved to test-alpine-diskless-boot.sh

    # Create storage-init OpenRC service
    cat > "${NODE_NAME}-apkovl/etc/init.d/storage-init" << 'EOF'
#!/sbin/openrc-run

description="Storage initialization and persistent storage service"
name="storage init"

depend() {
    need localmount
    after localmount
    before system-bootstrap
    provide storage-init
}

start() {
    ebegin "Setting up persistent storage"

    # Ensure ext4 module is loaded (needed for mkfs.ext4 and mount)
    modprobe ext4 2>/dev/null || true

    # Auto-detect storage device - supports SD card, USB, and virtio
    einfo "Auto-detecting storage device..."
    STORAGE_DEVICE=""
    DATA_PARTITION=""

    # Check for SD card device (Raspberry Pi SD card)
    if [ -b "/dev/mmcblk0" ]; then
        STORAGE_DEVICE="/dev/mmcblk0"
        DATA_PARTITION="/dev/mmcblk0p2"
        einfo "Detected SD card device: $STORAGE_DEVICE"
    # Check for SCSI/USB storage (first device)
    elif [ -b "/dev/sda" ]; then
        STORAGE_DEVICE="/dev/sda"
        DATA_PARTITION="/dev/sda2"
        einfo "Detected SCSI/USB device: $STORAGE_DEVICE"
    # Check for virtio storage
    elif [ -b "/dev/vda" ]; then
        STORAGE_DEVICE="/dev/vda"
        DATA_PARTITION="/dev/vda2"
        einfo "Detected virtio device: $STORAGE_DEVICE"
    # Check for second SCSI/USB device
    elif [ -b "/dev/sdb" ]; then
        STORAGE_DEVICE="/dev/sdb"
        DATA_PARTITION="/dev/sdb2"
        einfo "Detected SCSI/USB device: $STORAGE_DEVICE"
    else
        eerror "No storage device found"
        einfo "Available devices:"
        ls -la /dev/mmc* /dev/sd* /dev/vd* 2>/dev/null || einfo "No storage devices found"
        eend 1 "Storage device not found"
        return 1
    fi

    # Verify data partition exists
    einfo "Verifying data partition $DATA_PARTITION..."
    if [ ! -b "$DATA_PARTITION" ]; then
        eerror "Data partition $DATA_PARTITION not found"
        einfo "Run setup-sd-card.sh first to create the partition layout"
        einfo "Available partitions:"
        ls -la ${STORAGE_DEVICE}* 2>/dev/null || einfo "No partitions found"
        eend 1 "Data partition not found"
        return 1
    fi
    einfo "Data partition verified"

    # Format if needed
    if [ -b "$DATA_PARTITION" ] && ! blkid $DATA_PARTITION | grep -q ext4; then
        einfo "Formatting data partition..."
        if /sbin/mkfs.ext4 -F -L DATA $DATA_PARTITION; then
            einfo "Data partition formatted successfully"

            # CRITICAL: Aggressive sync - wait for kernel to recognize filesystem
            # After mkfs, the kernel needs time to update metadata before mounting
            einfo "Syncing filesystem buffers (this may take a few seconds)..."

            # Step 1: Flush all kernel buffers to disk
            sync
            blockdev --flushbufs $DATA_PARTITION 2>/dev/null || true

            # Step 2: Wait for I/O to complete
            sleep 3

            # Step 3: Force kernel to re-read device metadata
            blockdev --rereadpt $STORAGE_DEVICE 2>/dev/null || true
            partprobe $DATA_PARTITION 2>/dev/null || true

            # Step 4: Trigger udev to recognize filesystem (if available)
            if command -v udevadm >/dev/null 2>&1; then
                einfo "Triggering udev device recognition..."
                udevadm trigger --subsystem-match=block >/dev/null 2>&1 || true
                udevadm settle --timeout=5 2>/dev/null || true
            fi

            # Step 5: Final sync and wait
            sync
            sleep 2

            # Step 6: Verify filesystem is recognized
            if blkid $DATA_PARTITION | grep -q ext4; then
                einfo "Filesystem verified and ready for mounting"
            else
                ewarn "Filesystem created but not yet recognized by kernel"
                ewarn "Mount may fail - this is expected on first boot"
            fi
        else
            eend 1 "Failed to format data partition"
            return 1
        fi
    fi

    # Check if Alpine already mounted the data partition (common during boot)
    # Alpine mounts partitions to /media/<partition-name>
    # Note: In QEMU testing, we create /dev/mmcblk0p2 as a block device with same
    # major:minor as /dev/sda2, but Alpine mounts the real device at /media/sda2
    PARTITION_NAME=$(basename "$DATA_PARTITION")
    ALPINE_MOUNT_POINT=""

    # First, check if mounted by our partition name (e.g., mmcblk0p2)
    if mountpoint -q "/media/$PARTITION_NAME" 2>/dev/null; then
        ALPINE_MOUNT_POINT="/media/$PARTITION_NAME"
        einfo "Data partition already mounted by Alpine at /media/$PARTITION_NAME"
    else
        # Check if the same device (by major:minor) is mounted elsewhere in /media
        # This handles QEMU simulation where mmcblk0p2 and sda2 share the same major:minor
        if [ -b "$DATA_PARTITION" ]; then
            DATA_MAJOR_MINOR=$(stat -c "%t:%T" "$DATA_PARTITION" 2>/dev/null)
            for media_mount in /media/*; do
                if [ -d "$media_mount" ] && mountpoint -q "$media_mount" 2>/dev/null; then
                    # Get the device mounted here
                    MOUNTED_DEV=$(mount | grep " $media_mount " | awk '{print $1}')
                    if [ -b "$MOUNTED_DEV" ]; then
                        MOUNTED_MAJOR_MINOR=$(stat -c "%t:%T" "$MOUNTED_DEV" 2>/dev/null)
                        if [ "$DATA_MAJOR_MINOR" = "$MOUNTED_MAJOR_MINOR" ]; then
                            ALPINE_MOUNT_POINT="$media_mount"
                            einfo "Data partition already mounted by Alpine at $media_mount (same device)"
                            break
                        fi
                    fi
                fi
            done
        fi
    fi

    # Mount data partition
    mkdir -p /mnt/data
    if [ -n "$ALPINE_MOUNT_POINT" ]; then
        # Alpine already mounted it - remount read-write if needed, then bind mount
        # Alpine often mounts partitions read-only during boot
        if mount | grep " $ALPINE_MOUNT_POINT " | grep -q "[ (]ro[,)]"; then
            einfo "Remounting $ALPINE_MOUNT_POINT as read-write..."
            mount -o remount,rw "$ALPINE_MOUNT_POINT" || {
                ewarn "Could not remount as read-write, trying to continue..."
            }
        fi

        einfo "Creating bind mount from $ALPINE_MOUNT_POINT to /mnt/data..."
        if mount --bind "$ALPINE_MOUNT_POINT" /mnt/data; then
            einfo "Storage bind-mounted at /mnt/data (source: $ALPINE_MOUNT_POINT)"
        else
            eend 1 "Failed to bind mount storage"
            return 1
        fi
    else
        # Alpine hasn't mounted it yet - mount directly to /mnt/data
        einfo "Mounting persistent storage directly to /mnt/data..."

        # Try mounting with retry logic (filesystem may not be immediately recognized)
        local mount_attempts=3
        local mount_success=false
        local attempt=1

        while [ $attempt -le $mount_attempts ]; do
            if [ $attempt -gt 1 ]; then
                einfo "Mount attempt $attempt of $mount_attempts..."
                # Between retries, force another sync
                sync
                sleep 2
            fi

            if mount $DATA_PARTITION /mnt/data 2>/dev/null; then
                einfo "Storage mounted at /mnt/data (attempt $attempt)"
                mount_success=true
                break
            else
                if [ $attempt -lt $mount_attempts ]; then
                    ewarn "Mount attempt $attempt failed, retrying..."
                fi
            fi

            attempt=$((attempt + 1))
        done

        if [ "$mount_success" = "false" ]; then
            eerror "Failed to mount storage after $mount_attempts attempts"
            eerror "This can happen on first boot - filesystem needs kernel recognition"
            einfo "Possible solutions:"
            einfo "  1. Reboot - filesystem will mount successfully"
            einfo "  2. Wait a few seconds and run: rc-service storage-init restart"
            eend 1 "Failed to mount storage"
            return 1
        fi
    fi

    # CRITICAL: Check if mount is read-only and fix if needed
    if ! touch /mnt/data/.write-test 2>/dev/null; then
        ewarn "Storage mounted as read-only, attempting to remount as read-write..."

        # First, try to investigate WHY it's read-only
        einfo "Checking filesystem for errors..."
        e2fsck -p $DATA_PARTITION 2>&1 | head -5 || true

        # Attempt remount as read-write
        # If using Alpine's mount, we need to remount the source partition
        if [ -n "$ALPINE_MOUNT_POINT" ]; then
            einfo "Remounting source partition $ALPINE_MOUNT_POINT as read-write..."
            if mount -o remount,rw "$ALPINE_MOUNT_POINT"; then
                einfo "Successfully remounted $ALPINE_MOUNT_POINT as read-write"
            else
                eerror "Failed to remount $ALPINE_MOUNT_POINT as read-write"
                eend 1 "Cannot fix read-only filesystem"
                return 1
            fi
        else
            # Direct mount - remount /mnt/data
            if mount -o remount,rw /mnt/data; then
                einfo "Successfully remounted /mnt/data as read-write"
            else
                eerror "Failed to remount /mnt/data as read-write"
                eend 1 "Cannot fix read-only filesystem"
                return 1
            fi
        fi

        # Verify write capability
        if touch /mnt/data/.write-test 2>/dev/null; then
            rm -f /mnt/data/.write-test
            einfo "Write test successful"
        else
            eerror "Still cannot write to /mnt/data after remount"
            eend 1 "Filesystem remains read-only"
            return 1
        fi
    else
        rm -f /mnt/data/.write-test
        einfo "Storage is writable"
    fi

    # Create directories for k3s, APK cache, LBU config, usr/local/bin, and chrony
    mkdir -p /mnt/data/k3s /mnt/data/etc-persistent /mnt/data/var-lib-k3s /mnt/data/apk-cache /mnt/data/etc-lbu /mnt/data/usr-local-bin /mnt/data/var-lib-chrony

    # Set up APK local cache (Alpine's official mechanism)
    # This enables packages to be cached and restored across reboots
    if [ ! -L /etc/apk/cache ]; then
        einfo "Setting up APK local cache on persistent storage"
        mkdir -p /mnt/data/apk-cache
        ln -sf /mnt/data/apk-cache /etc/apk/cache
        eend $? "APK cache symlink"
    fi

    # Set up LBU config bind mount to persistent storage
    if ! mountpoint -q /etc/lbu 2>/dev/null; then
        einfo "Setting up LBU config on persistent storage"
        # Copy overlay LBU config to persistent storage if it doesn't exist
        if [ -d /etc/lbu ] && [ ! -f /mnt/data/etc-lbu/lbu.conf ]; then
            cp -a /etc/lbu/* /mnt/data/etc-lbu/ 2>/dev/null || true
        fi
        mount --bind /mnt/data/etc-lbu /etc/lbu
        eend $? "LBU config mount"
    fi

    # Set up /usr/local/bin bind mount to persistent storage
    if ! mountpoint -q /usr/local/bin 2>/dev/null; then
        einfo "Setting up /usr/local/bin on persistent storage"
        # Copy overlay files from /usr/local/bin to persistent storage if they don't exist
        if [ -d /usr/local/bin ]; then
            for file in /usr/local/bin/*; do
                if [ -f "$file" ] && [ ! -f "/mnt/data/usr-local-bin/$(basename "$file")" ]; then
                    cp -a "$file" /mnt/data/usr-local-bin/
                fi
            done
        fi
        mount --bind /mnt/data/usr-local-bin /usr/local/bin
        eend $? "/usr/local/bin mount"
    fi

    # Set up chrony drift file on persistent storage
    mkdir -p /mnt/data/var-lib-chrony
    if ! mountpoint -q /var/lib/chrony 2>/dev/null; then
        einfo "Setting up /var/lib/chrony on persistent storage"
        mkdir -p /var/lib/chrony
        # Copy any existing drift data
        if [ -f /var/lib/chrony/chrony.drift ] && [ ! -f /mnt/data/var-lib-chrony/chrony.drift ]; then
            cp -a /var/lib/chrony/chrony.drift /mnt/data/var-lib-chrony/
        fi
        mount --bind /mnt/data/var-lib-chrony /var/lib/chrony
        eend $? "/var/lib/chrony mount"
    fi

    # Set up rancher config bind mount to persistent storage
    # Persist entire /etc/rancher directory (not just k3s subdirectory)
    # This supports k3s, Rancher Desktop, and other Rancher products
    mkdir -p /mnt/data/etc-rancher /mnt/data/var-lib-rancher-k3s
    mkdir -p /etc/rancher /var/lib/rancher/k3s

    # Copy overlay rancher configs to persistent storage if they don't exist there
    # This preserves k3s config.yaml and any other files in /etc/rancher from the overlay
    if [ -d /etc/rancher ] && [ "$(ls -A /etc/rancher 2>/dev/null)" ] && [ ! -f /mnt/data/etc-rancher/.copied-from-overlay ]; then
        einfo "Copying overlay rancher configs to persistent storage"
        cp -a /etc/rancher/* /mnt/data/etc-rancher/ 2>/dev/null || true
        touch /mnt/data/etc-rancher/.copied-from-overlay
    fi

    if ! mountpoint -q /etc/rancher 2>/dev/null; then
        einfo "Setting up /etc/rancher on persistent storage"
        mount --bind /mnt/data/etc-rancher /etc/rancher
        eend $? "/etc/rancher mount"
    fi

    if ! mountpoint -q /var/lib/rancher/k3s 2>/dev/null; then
        einfo "Setting up /var/lib/rancher/k3s on persistent storage"
        mount --bind /mnt/data/var-lib-rancher-k3s /var/lib/rancher/k3s
        eend $? "/var/lib/rancher/k3s mount"
    fi

    # Mark storage initialization as complete
    echo "$(date): Storage initialization completed successfully" > /mnt/data/.storage-init-complete

    eend 0 "Persistent storage setup complete"
}

stop() {
    ebegin "Unmounting persistent storage"
    umount /mnt/data 2>/dev/null || true
    eend 0
}
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/storage-init"

    # Create ssh-persist OpenRC service (idempotent SSH setup on every boot)
    cat > "${NODE_NAME}-apkovl/etc/init.d/ssh-persist" << 'EOF'
#!/sbin/openrc-run

description="Persistent SSH setup service"
name="ssh persist"

depend() {
    need storage-init net
    after storage-init net
    before system-bootstrap
    provide ssh-persist
}

start() {
    ebegin "Setting up persistent SSH"

    # Persistent storage location for SSH
    SSH_PERSIST_DIR="/mnt/data/ssh"

    # Wait for storage to be ready
    if [ ! -d /mnt/data ] || ! mountpoint -q /mnt/data 2>/dev/null; then
        ewarn "Persistent storage not available, SSH may not persist across reboots"
    else
        mkdir -p "$SSH_PERSIST_DIR"
    fi

    # Install openssh packages (always check for ssh-keygen as it's required for key generation)
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        einfo "Installing OpenSSH packages..."
        apk update >/dev/null 2>&1
        if apk add openssh openssh-server openssh-keygen; then
            einfo "OpenSSH installed successfully"
        else
            eerror "Failed to install OpenSSH"
            eend 1 "OpenSSH installation failed"
            return 1
        fi
    fi

    # Restore or generate SSH host keys
    if [ -d "$SSH_PERSIST_DIR" ] && [ -f "$SSH_PERSIST_DIR/ssh_host_ed25519_key" ]; then
        einfo "Restoring SSH host keys from persistent storage..."
        cp -a "$SSH_PERSIST_DIR"/ssh_host_*_key* /etc/ssh/ 2>/dev/null
        chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null
        chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null
    else
        einfo "Generating new SSH host keys..."
        rm -f /etc/ssh/ssh_host_*_key*
        ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N "" -q
        ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key -N "" -q
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q

        # Save to persistent storage
        if [ -d "$SSH_PERSIST_DIR" ]; then
            einfo "Saving SSH host keys to persistent storage..."
            cp -a /etc/ssh/ssh_host_*_key* "$SSH_PERSIST_DIR/" 2>/dev/null
        fi
    fi

    # Restore authorized_keys from persistent storage if available
    if [ -d "$SSH_PERSIST_DIR" ] && [ -f "$SSH_PERSIST_DIR/authorized_keys" ]; then
        einfo "Restoring authorized_keys from persistent storage..."
        mkdir -p /root/.ssh
        cp -a "$SSH_PERSIST_DIR/authorized_keys" /root/.ssh/authorized_keys
    fi

    # Ensure /root and .ssh have correct ownership and permissions
    # (apkovl files may have wrong ownership from build host)
    chown root:root /root
    chmod 700 /root

    if [ -f /root/.ssh/authorized_keys ]; then
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
        chown -R root:root /root/.ssh

        # Save to persistent storage if not already there
        if [ -d "$SSH_PERSIST_DIR" ] && [ ! -f "$SSH_PERSIST_DIR/authorized_keys" ]; then
            cp -a /root/.ssh/authorized_keys "$SSH_PERSIST_DIR/authorized_keys"
        fi
    fi

    # Ensure sshd_config has correct permissions
    chmod 644 /etc/ssh/sshd_config 2>/dev/null

    # Create /var/empty directory for sshd privilege separation
    # This is required by sshd but may not exist or have wrong permissions in diskless environment
    if [ ! -d /var/empty ]; then
        einfo "Creating /var/empty for sshd privilege separation..."
        mkdir -p /var/empty
    fi
    # Always fix ownership and permissions (directory may exist with wrong perms from base system)
    einfo "Fixing /var/empty ownership and permissions..."
    chown root:root /var/empty 2>/dev/null
    chmod 755 /var/empty 2>/dev/null

    # Enable and start sshd
    if ! rc-service sshd status >/dev/null 2>&1; then
        einfo "Starting SSH service..."
        rc-update add sshd default 2>/dev/null
        rc-service sshd start
    else
        einfo "SSH service already running"
    fi

    eend 0 "SSH setup complete"
}

stop() {
    ebegin "Stopping ssh-persist service"
    # Nothing to do - sshd has its own stop
    eend 0
}
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/ssh-persist"

    # Create k3s-worker-token OpenRC service for worker nodes
    # This service retrieves the k3s join token from the master server
    cat > "${NODE_NAME}-apkovl/etc/init.d/k3s-worker-token" << 'K3S_WORKER_TOKEN_EOF'
#!/sbin/openrc-run

description="k3s worker token retrieval service"
name="k3s worker token"

depend() {
    need localmount storage-init ssh-persist net
    after localmount storage-init ssh-persist net
    before k3s
    provide k3s-worker-token
}

start() {
    # Check if this is a worker node (has server: in config)
    if ! grep -q "^server:" /etc/rancher/k3s/config.yaml 2>/dev/null; then
        einfo "Master node detected - no token retrieval needed"
        mark_service_started
        return 0
    fi

    ebegin "Retrieving k3s worker token from master"

    # Extract master URL from config
    SERVER_URL=$(grep "^server:" /etc/rancher/k3s/config.yaml | cut -d' ' -f2)

    # Extract hostname from URL - remove protocol prefix then port and path
    MASTER_HOST=$(echo "${SERVER_URL}" | sed 's|https://||' | sed 's|http://||' | cut -d: -f1 | cut -d/ -f1)

    einfo "Connecting to master: ${MASTER_HOST}"

    # Retrieve token from master via SSH with retry
    TOKEN_FILE="/etc/rancher/k3s/server-token"
    MAX_RETRIES=10
    RETRY_DELAY=10
    RETRY_COUNT=0

    while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
        einfo "Attempting to retrieve token (attempt $((RETRY_COUNT + 1))/${MAX_RETRIES})..."

        # SSH to master and get token using cluster SSH key
        if TOKEN=$(ssh -i /root/.ssh/cluster_id_rsa \
                    -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=5 \
                    root@${MASTER_HOST} \
                "cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null); then
            if [ -n "${TOKEN}" ]; then
                mkdir -p /etc/rancher/k3s
                echo "${TOKEN}" > "${TOKEN_FILE}"
                chmod 600 "${TOKEN_FILE}"
                # Add token to the existing rancher k3s config
                # Config is already at /etc/rancher/k3s/config.yaml from setup-k3s-yaml.sh
                mkdir -p /etc/rancher/k3s
                # Add token if not already present
                if ! grep -q "^token:" /etc/rancher/k3s/config.yaml 2>/dev/null; then
                    echo "token: ${TOKEN}" >> /etc/rancher/k3s/config.yaml
                fi
                eend 0 "Token retrieved successfully"
                return 0
            fi
        fi

        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; then
            einfo "Master not ready, waiting ${RETRY_DELAY}s before retry..."
            sleep ${RETRY_DELAY}
        fi
    done

    eend 1 "Failed to retrieve k3s token after ${MAX_RETRIES} attempts"
    return 1
}

stop() {
    # Nothing to do on stop
    ebegin "Stopping k3s-worker-token service"
    eend 0
}
K3S_WORKER_TOKEN_EOF
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/k3s-worker-token"

    # NOTE: lbu-restore service removed - Alpine's init automatically loads
    # any .apkovl.tar.gz files it finds on mounted partitions during boot.
    # Our lbu-persist service creates runtime-*.apkovl.tar.gz on /mnt/data,
    # which Alpine's init automatically discovers and loads on next boot.
    # No need for a separate restore service - Alpine handles it natively!

    # Create lbu-persist OpenRC service (commits changes on shutdown)
    cat > "${NODE_NAME}-apkovl/etc/init.d/lbu-persist" << 'EOF'
#!/sbin/openrc-run

description="Commit LBU changes on shutdown/reboot"
name="lbu persist"

depend() {
    need storage-init
    after storage-init system-bootstrap
    provide lbu-persist
}

start() {
    # Nothing to do on start - system-bootstrap handles initial LBU setup
    ebegin "LBU persistence service started"
    eend 0
}

stop() {
    ebegin "Committing LBU changes before shutdown"

    # Save any runtime changes made during this session
    if [ -d /mnt/data ] && mountpoint -q /mnt/data; then
        # Use the custom lbu-commit-runtime created by system-bootstrap
        if [ -x /usr/local/bin/lbu-commit-runtime ]; then
            /usr/local/bin/lbu-commit-runtime
            if [ $? -eq 0 ]; then
                einfo "Runtime changes committed"
            else
                ewarn "LBU commit failed"
            fi
        else
            # Fallback to standard lbu commit
            if lbu commit -d 2>/dev/null; then
                einfo "Changes saved to persistent storage"
            else
                ewarn "LBU commit failed"
            fi
        fi
    else
        ewarn "Persistent storage not available, changes will be lost"
    fi

    eend 0
}
EOF
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/lbu-persist"

    # Enable lbu-persist service (lbu-restore not needed - Alpine auto-loads apkovl)
    ln -sf /etc/init.d/lbu-persist "${NODE_NAME}-apkovl/etc/runlevels/default/lbu-persist"

done

# Clean up temporary cluster SSH key directory
rm -rf "$CLUSTER_KEY_DIR"
echo "✅ Cluster SSH key pair cleaned up"

echo ""
echo "✅ Base apkovl structure created for all nodes from YAML configuration"
echo ""
echo "Created apkovl directories:"
yaml_get_nodes | while IFS=':' read -r NODE_NAME NODE_IP NODE_ROLE; do
    if [ -d "${NODE_NAME}-apkovl" ]; then
        echo "  ✅ ${NODE_NAME}-apkovl/ (${NODE_ROLE} - ${NODE_IP})"
    else
        echo "  ❌ ${NODE_NAME}-apkovl/ (failed to create)"
    fi
done

echo ""
echo "Next steps:"
echo "1. Run setup-k3s-yaml.sh $CONFIG_FILE"
echo "2. Run generate-manifests-yaml.sh $CONFIG_FILE"  
echo "3. Run build-from-yaml.sh $CONFIG_FILE (or use individual scripts)"