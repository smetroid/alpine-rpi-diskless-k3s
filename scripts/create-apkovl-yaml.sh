#!/bin/bash

# Alpine diskless k3s setup script using YAML configuration
# Creates apkovl files for all nodes defined in cluster-config.yaml

set -e

# Source and library directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(cd "$SCRIPT_DIR/../lib" && pwd)}"

# Load cache library
source "$LIB_DIR/cache.sh"

# Load template rendering library
source "$LIB_DIR/templates.sh"

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

    export PACKAGES="$pkg_list"
    render_template "openrc/auto-start-services.tmpl" "${apkovl_dir}/etc/init.d/auto-start-services"
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
    
    export NODE_IP NETMASK GATEWAY DOMAIN
    export DNS_SERVER="${DNS_SERVERS[0]}"
    render_template "config/network-interfaces.tmpl" "${NODE_NAME}-apkovl/etc/network/interfaces"

    # Resolve configuration
    render_template "config/resolv.conf.tmpl" "${NODE_NAME}-apkovl/etc/resolv.conf"

    # APK repositories configuration
    ALPINE_VERSION=$(yaml_get "alpine.version" "$CONFIG_FILE")
    ALPINE_MAJOR=$(echo "$ALPINE_VERSION" | cut -d'.' -f1,2)
    export ALPINE_MAJOR
    render_template "config/apk-repositories.tmpl" "${NODE_NAME}-apkovl/etc/apk/repositories"

    # SSH daemon configuration
    SSH_PORT=$(yaml_get "ssh.port")
    PERMIT_ROOT=$(yaml_get "ssh.permit_root_login")
    PASS_AUTH=$(yaml_get "ssh.password_authentication")

    export SSH_PORT PERMIT_ROOT PASS_AUTH
    render_template "config/sshd_config.tmpl" "${NODE_NAME}-apkovl/etc/ssh/sshd_config"

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
    render_template "config/chrony.conf.sh" "${NODE_NAME}-apkovl/etc/chrony/chrony.conf"

    # Create persistent chrony directory structure
    mkdir -p "${NODE_NAME}-apkovl/var/lib/chrony"

    # Create k3s init script based on node role
    export NODE_ROLE
    render_template "openrc/k3s.tmpl" "${NODE_NAME}-apkovl/etc/init.d/k3s"
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/k3s"
    ln -sf /etc/init.d/k3s "${NODE_NAME}-apkovl/etc/runlevels/default/k3s"

    # Create minimal fstab — storage-init handles actual data partition mounting
    render_template "config/fstab.sh" "${NODE_NAME}-apkovl/etc/fstab"
    
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
    render_template "openrc/storage-init.sh" "${NODE_NAME}-apkovl/etc/init.d/storage-init"
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/storage-init"

    # Create ssh-persist OpenRC service (idempotent SSH setup on every boot)
    render_template "openrc/ssh-persist.sh" "${NODE_NAME}-apkovl/etc/init.d/ssh-persist"
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/ssh-persist"

    # Create k3s-worker-token OpenRC service for worker nodes
    # This service retrieves the k3s join token from the master server
    render_template "openrc/k3s-worker-token.sh" "${NODE_NAME}-apkovl/etc/init.d/k3s-worker-token"
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/k3s-worker-token"

    # NOTE: lbu-restore service removed - Alpine's init automatically loads
    # any .apkovl.tar.gz files it finds on mounted partitions during boot.
    # Our lbu-persist service creates runtime-*.apkovl.tar.gz on /mnt/data,
    # which Alpine's init automatically discovers and loads on next boot.
    # No need for a separate restore service - Alpine handles it natively!

    # Create lbu-persist OpenRC service (commits changes on shutdown)
    render_template "openrc/lbu-persist.sh" "${NODE_NAME}-apkovl/etc/init.d/lbu-persist"
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/lbu-persist"

    # Enable lbu-persist service (lbu-restore not needed - Alpine auto-loads apkovl)
    ln -sf /etc/init.d/lbu-persist "${NODE_NAME}-apkovl/etc/runlevels/default/lbu-persist"

    # Create late-services OpenRC service (starts services after everything is up)
    render_template "openrc/late-services.sh" "${NODE_NAME}-apkovl/etc/init.d/late-services"
    chmod +x "${NODE_NAME}-apkovl/etc/init.d/late-services"

    # Enable late-services in default runlevel (runs after k3s)
    ln -sf /etc/init.d/late-services "${NODE_NAME}-apkovl/etc/runlevels/default/late-services"

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