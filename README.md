# Alpine Linux Diskless k3s Cluster

This project creates a multi-node k3s cluster running on Alpine Linux in diskless mode, with YAML-based configuration for easy customization and deployment automation.

**🗂️ Clean Project Structure**: Scripts are organized in `scripts/` directory, build output goes to `builds/` directory, while configuration files and documentation remain at the project root for easy access.

## Features

- **YAML-Driven Configuration** - Single source of truth for all cluster settings
- **Diskless Alpine Linux** - Runs entirely from RAM with persistent storage on SD card
- **Automated k3s Setup** - Multi-node cluster with automatic formation
- **Load Balancing** - MetalLB for bare-metal LoadBalancer services
- **Ingress Controller** - NGINX Ingress (replaces Traefik)
- **Cross-Platform** - Supports both Linux and macOS for SD card preparation
- **Persistent Storage** - Critical data survives reboots via SD card persistence
- **Clean Organization** - Separate directories for scripts, builds, and configuration

## Quick Start

### 1. Configure Your Cluster

Copy and edit the cluster configuration:

```bash
cp cluster-config.yaml my-cluster.yaml
# Edit my-cluster.yaml with your network settings, node details, and SSH keys
```

Example configuration:
```yaml
cluster:
  name: "my-k3s-cluster"

network:
  subnet: "192.168.1.0/24"
  gateway: "192.168.1.1"
  dns_servers: ["192.168.1.1"]
  loadbalancer_pool:
    start: "192.168.1.100"
    end: "192.168.1.199"

nodes:
  - name: "k3s-master"
    ip: "192.168.1.10"
    role: "master"
  - name: "k3s-worker1"
    ip: "192.168.1.11"
    role: "worker"
  - name: "k3s-worker2"
    ip: "192.168.1.12"
    role: "worker"

ssh:
  authorized_keys:
    - "ssh-rsa AAAAB3NzaC1yc2E... your-key-here"
```

### 2. Validate and Build

```bash
# Validate your configuration
./validate-config.sh my-cluster.yaml

# Build complete cluster setup
./build-from-yaml.sh my-cluster.yaml
```

### 3. Prepare SD Cards

The SD card setup script only creates the boot partition and installs Alpine Linux. The data partition is automatically created and formatted by Alpine on first boot.

**On Linux:**
```bash
sudo ./setup-sd-card.sh /dev/sdX my-cluster.yaml
```

**On macOS:**
```bash
# Find your SD card
diskutil list

# Setup SD card (no additional tools required)
sudo ./setup-sd-card.sh /dev/diskN my-cluster.yaml
```

### 4. Deploy to Cluster

```bash
# Copy apkovl files to each SD card's boot partition
# The build script shows you exactly which files to copy

# For each node:
cp builds/k3s-master.apkovl.tar.gz /Volumes/BOOT/
cp builds/k3s-worker1.apkovl.tar.gz /Volumes/BOOT/
cp builds/k3s-worker2.apkovl.tar.gz /Volumes/BOOT/
```

### 5. Boot Your Cluster

1. Insert SD cards into nodes
2. Power on master node first
3. Wait 3-5 minutes for initialization (includes data partition creation and formatting)
4. Power on worker nodes
5. Wait 5-10 minutes for complete cluster formation

**Note:** On first boot, each node will automatically:
- Create and format the data partition (ext4)
- Mount persistent storage
- Set up k3s configuration and data directories

### 6. Verify Deployment

SSH to your master node and verify:

```bash
ssh root@192.168.1.10

# Check cluster status
kubectl get nodes -o wide

# Check all pods
kubectl get pods --all-namespaces

# Check LoadBalancer services
kubectl get svc --all-namespaces | grep LoadBalancer
```

## Available Scripts

### Main Workflow Scripts
- **`validate-config.sh`** - Validates YAML configuration with detailed error checking
- **`build-from-yaml.sh`** - Complete cluster setup builder (runs all steps)
- **`setup-sd-card.sh`** - Cross-platform SD card preparation (Linux/macOS)
- **`create-apkovl-archives.sh`** - Creates .apkovl.tar.gz files from YAML

### Individual Component Scripts
- **`create-apkovl-yaml.sh`** - Creates apkovl directory structure
- **`setup-k3s-yaml.sh`** - Configures k3s settings
- **`generate-manifests-yaml.sh`** - Generates Kubernetes manifests

### Utility Scripts
- **`lib/yaml-parser.sh`** - YAML parsing library

## Configuration Reference

### Cluster Settings
```yaml
cluster:
  name: "cluster-name"           # Cluster identifier
  k3s_version: "latest"          # k3s version or "latest"
  token: ""                      # Leave empty to auto-generate
```

### Network Configuration
```yaml
network:
  domain: "local"                # Local domain name
  subnet: "192.168.1.0/24"       # Network subnet in CIDR notation
  gateway: "192.168.1.1"         # Gateway IP address
  dns_servers:                   # List of DNS servers
    - "192.168.1.1"
  loadbalancer_pool:             # MetalLB IP range
    start: "192.168.1.100"
    end: "192.168.1.199"
```

### Node Definition
```yaml
nodes:
  - name: "unique-name"          # Unique node hostname
    ip: "192.168.1.10"           # Static IP address
    role: "master"               # Role: "master" or "worker"
  - name: "worker-01"
    ip: "192.168.1.11"
    role: "worker"
```

### Service Configuration
```yaml
services:
  metallb:                       # LoadBalancer service
    enabled: true
    version: "v0.13.12"
  nginx_ingress:                 # Ingress controller
    enabled: true
    version: "v1.8.4"
    replicas: 2
```

### SSH Access
```yaml
ssh:
  port: 22
  permit_root_login: true
  password_authentication: true
  authorized_keys:               # SSH public keys
    - "ssh-rsa AAAAB3NzaC1yc2E... user@host"
    - "ssh-ed25519 AAAAC3NzaC1... user2@host2"
```

### Alpine Linux Settings
```yaml
alpine:
  version: "3.18.6"             # Alpine version
  architecture: "aarch64"       # Architecture (aarch64 for RPi)
  packages:                     # Additional packages
    - "curl"
    - "ca-certificates"
```

### Storage Configuration
```yaml
storage:
  device: "/dev/mmcblk0"         # SD card device path
  boot_partition_size: "512MiB"  # Boot partition size
  data_mount: "/mnt/data"        # Persistent data mount
```

## Multiple Environments

Manage different cluster configurations:

```bash
# Development cluster
./validate-config.sh dev-cluster.yaml
./build-from-yaml.sh dev-cluster.yaml

# Production cluster
./validate-config.sh prod-cluster.yaml
./build-from-yaml.sh prod-cluster.yaml

# Home lab cluster
./validate-config.sh homelab-cluster.yaml
./build-from-yaml.sh homelab-cluster.yaml
```

## Advanced Usage

### Standalone Archive Creation

If you need to regenerate just the apkovl files:

```bash
# Rebuild archives from existing configuration
./create-apkovl-archives.sh my-cluster.yaml
```

### Individual Steps

Run individual components if needed:

```bash
# Step 1: Create apkovl structure
./create-apkovl-yaml.sh my-cluster.yaml

# Step 2: Configure k3s
./setup-k3s-yaml.sh my-cluster.yaml

# Step 3: Generate Kubernetes manifests
./generate-manifests-yaml.sh my-cluster.yaml

# Step 4: Create final archives
./create-apkovl-archives.sh my-cluster.yaml
```

## Platform-Specific Notes

### macOS Users

1. **Find SD card device:**
   ```bash
   diskutil list
   ```

2. **SD card names use 's' prefix:**
   - Partitions: `/dev/diskNsX` (e.g., `/dev/disk2s1`)
   - Use `/dev/diskN` for the main device

3. **No additional tools required:**
   - The setup script only creates the boot partition (FAT32)
   - Data partition creation happens automatically on first boot

### Linux Users

1. **Standard tools work out of the box:**
   - `parted` for boot partition creation
   - No additional tools required for setup

2. **SD card names:**
   - Partitions: `/dev/sdXN` (e.g., `/dev/sdb1`)
   - Use `/dev/sdX` for the main device

3. **Simplified setup:**
   - Only boot partition is created during setup
   - Data partition is automatically created on first boot

## Services Included

- **k3s** - Lightweight Kubernetes distribution
- **MetalLB** - LoadBalancer implementation for bare metal
- **NGINX Ingress Controller** - HTTP/HTTPS ingress (replaces Traefik)
- **CoreDNS** - DNS server (included with k3s)

## Persistence

Data that survives reboots:
- k3s cluster data (`/var/lib/k3s`)
- k3s configuration (`/etc/k3s`)
- System configuration (hostname, network, SSH keys)
- Application data in persistent volumes

## File Structure

```
alpine-rpi-diskless/
├── cluster-config.yaml           # Main configuration file
├── build-from-yaml.sh            # Complete setup builder (wrapper)
├── validate-config.sh            # Configuration validator (wrapper)
├── setup-sd-card.sh              # SD card preparation (wrapper)
├── lib/
│   └── yaml-parser.sh            # YAML parsing library
├── scripts/                      # All build scripts
│   ├── build-from-yaml.sh        # Main build logic
│   ├── create-apkovl-yaml.sh     # apkovl structure creation
│   ├── setup-k3s-yaml.sh        # k3s configuration
│   ├── generate-manifests-yaml.sh # Manifest generation
│   ├── create-apkovl-archives.sh # Archive creation
│   └── ...                      # Other utility scripts
└── builds/                       # Generated output
    ├── k3s-manifests/            # Kubernetes manifests
    │   ├── metallb-config.yaml
    │   └── nginx-proxy.yaml
    ├── {node-name}-apkovl/       # Generated apkovl directories
    └── {node-name}.apkovl.tar.gz # Final deployment files
```

## Troubleshooting

### Configuration Issues
```bash
# Validate configuration
./validate-config.sh your-config.yaml

# Check YAML syntax
python3 -c "import yaml; yaml.safe_load(open('your-config.yaml'))"
```

### Build Issues
```bash
# Make scripts executable
chmod +x *.sh lib/*.sh

# Clean and rebuild
rm -rf builds/*
./build-from-yaml.sh your-config.yaml
```

### SD Card Issues

**Linux:**
```bash
# Check available disks
lsblk

# Unmount before formatting
sudo umount /dev/sdX*
```

**macOS:**
```bash
# Check available disks
diskutil list

# Unmount before formatting
sudo diskutil unmountDisk /dev/diskN
```

### Cluster Issues
```bash
# SSH to master node
ssh root@your-master-ip

# Check k3s status
rc-service k3s status

# View k3s logs
tail -f /var/log/k3s.log

# Check cluster formation
kubectl get nodes
```

### Network Issues
```bash
# Check network configuration
cat /etc/network/interfaces

# Test connectivity
ping your-gateway-ip

# Check routing
ip route show
```

## Security Considerations

**Development/Testing:**
- Default setup uses root access with SSH keys
- Password authentication enabled by default
- Consider firewalls for production use

**Production Hardening:**
- Change default passwords
- Disable password authentication (`password_authentication: false`)
- Set up proper TLS certificates
- Implement network policies
- Regular security updates
- Monitor cluster access

## Example Configurations

### Small Home Lab (3 nodes, single subnet)
```yaml
cluster:
  name: "homelab-k3s"
network:
  subnet: "192.168.1.0/24"
  gateway: "192.168.1.1"
  dns_servers: ["192.168.1.1"]
  loadbalancer_pool:
    start: "192.168.1.100"
    end: "192.168.1.110"
nodes:
  - {name: "rpi-master", ip: "192.168.1.10", role: "master"}
  - {name: "rpi-worker1", ip: "192.168.1.11", role: "worker"}
  - {name: "rpi-worker2", ip: "192.168.1.12", role: "worker"}
```

### Development Cluster (5 nodes, dedicated subnet)
```yaml
cluster:
  name: "dev-k3s"
network:
  subnet: "10.0.100.0/24"
  gateway: "10.0.100.1"
  dns_servers: ["10.0.100.1", "8.8.8.8"]
  loadbalancer_pool:
    start: "10.0.100.200"
    end: "10.0.100.250"
nodes:
  - {name: "dev-master", ip: "10.0.100.10", role: "master"}
  - {name: "dev-worker1", ip: "10.0.100.11", role: "worker"}
  - {name: "dev-worker2", ip: "10.0.100.12", role: "worker"}
  - {name: "dev-worker3", ip: "10.0.100.13", role: "worker"}
  - {name: "dev-worker4", ip: "10.0.100.14", role: "worker"}
```

## Support

For issues and questions:
- Check the troubleshooting section above
- Validate your YAML configuration first
- Ensure you're using the correct platform-specific commands
- Review the generated files in `builds/` directory for debugging

## Migration from Script-Based Setup

If you're migrating from the old hardcoded script approach:
1. Create a YAML config file matching your existing setup
2. Use the new `build-from-yaml.sh` workflow
3. The functionality is the same, but much more flexible and maintainable