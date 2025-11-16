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

## Boot and Reboot Process

### Understanding Alpine Diskless Mode

Alpine Linux runs entirely from RAM in diskless mode. This means:
- ✅ **Fast** - Everything runs from memory
- ✅ **Clean** - Each boot starts fresh
- ⚠️ **Volatile** - Changes are lost unless saved

**The Challenge:** How do we keep SSH keys, network settings, and k3s data across reboots?

**The Solution:** Combination of persistent storage and LBU (Local Backup Utility)

### First Boot Process

When you first power on a node with a fresh SD card:

```
1. Hardware Boot
   └─> Raspberry Pi firmware loads Alpine kernel from SD card boot partition

2. Alpine initramfs (Initial RAM Filesystem)
   ├─> Creates tmpfs root filesystem in RAM
   ├─> Searches for *.apkovl.tar.gz on boot media
   ├─> Extracts k3s-{node}.apkovl.tar.gz to RAM
   └─> Hands off to OpenRC init system

3. OpenRC Boot Runlevel
   ├─> localmount (mounts local filesystems)
   ├─> networking (starts network interfaces)
   ├─> modules (loads kernel modules)
   └─> Other boot services

4. OpenRC Default Runlevel (Main Services)
   ├─> storage-init
   │   ├─> Auto-detects storage device (/dev/mmcblk0)
   │   ├─> Creates data partition (/dev/mmcblk0p2) if missing
   │   ├─> Formats as ext4
   │   ├─> Mounts to /mnt/data
   │   ├─> Sets up bind mounts (APK cache, LBU config, /usr/local/bin)
   │   └─> Creates /mnt/data/.storage-init-complete marker
   │
   ├─> lbu-restore
   │   ├─> Looks for /mnt/data/runtime-{hostname}.apkovl.tar.gz
   │   ├─> Not found on first boot (skips)
   │   └─> Continues...
   │
   ├─> system-bootstrap
   │   ├─> Checks for /mnt/data/.system-initialized
   │   ├─> Not found - performs full initialization:
   │   ├─> Updates APK repositories
   │   ├─> Installs required packages (curl, iptables, etc.)
   │   ├─> Configures timezone
   │   ├─> Installs and starts SSH server
   │   ├─> Generates SSH host keys
   │   ├─> Configures LBU (Local Backup Utility)
   │   ├─> Creates /etc/lbu/lbu.conf (backup location: /mnt/data)
   │   ├─> Creates /etc/lbu/include (files to backup)
   │   ├─> Runs lbu-commit-runtime
   │   │   └─> Saves to /mnt/data/runtime-{hostname}.apkovl.tar.gz
   │   └─> Creates /mnt/data/.system-initialized marker
   │
   ├─> k3s-bootstrap
   │   ├─> Waits for storage-init completion
   │   ├─> Sets up bind mounts (/etc/k3s, /var/lib/rancher/k3s)
   │   ├─> Installs k3s
   │   ├─> Starts k3s service
   │   └─> Creates /mnt/data/.k3s-initialized marker
   │
   └─> lbu-persist
       └─> Registers for shutdown (no action on startup)

5. System Ready
   └─> k3s cluster node is operational
```

**First Boot Timeline:**
- 0:00 - Power on
- 0:30 - Alpine boots, overlay loads
- 1:00 - storage-init creates/formats data partition
- 2:00 - system-bootstrap installs packages (downloading ~50MB)
- 4:00 - k3s-bootstrap installs k3s (downloading ~60MB)
- 5:00 - System ready, k3s operational

### Reboot Process (Subsequent Boots)

After you reboot a node (via `reboot` command or power cycle):

```
1. Alpine initramfs boots (fresh state)
   ├─> Loads ORIGINAL k3s-{node}.apkovl.tar.gz from SD card
   └─> System starts in clean state (all runtime changes are GONE)

2. OpenRC Boot Runlevel
   └─> (same as first boot)

3. OpenRC Default Runlevel
   ├─> storage-init
   │   ├─> Finds /dev/mmcblk0p2 already exists
   │   ├─> Mounts /mnt/data (data persists!)
   │   ├─> Finds /mnt/data/.storage-init-complete
   │   └─> Skips partition creation/formatting
   │
   ├─> lbu-restore ⭐ KEY SERVICE
   │   ├─> Finds /mnt/data/runtime-{hostname}.apkovl.tar.gz
   │   ├─> Extracts overlay to RAM root filesystem
   │   ├─> RESTORES:
   │   │   ├─> SSH host keys (same fingerprint!)
   │   │   ├─> SSH authorized_keys (remote access works!)
   │   │   ├─> Network configuration
   │   │   ├─> Hostname, timezone
   │   │   ├─> /etc/k3s configuration
   │   │   └─> LBU configuration
   │   └─> Runtime state restored!
   │
   ├─> system-bootstrap
   │   ├─> Finds /mnt/data/.system-initialized
   │   ├─> Skips package installation (already done)
   │   └─> Packages persist because bind mount to /mnt/data/var-cache-apk
   │
   ├─> k3s-bootstrap
   │   ├─> k3s already installed (persisted in /mnt/data)
   │   ├─> Configuration already mounted from /mnt/data
   │   └─> Starts k3s service
   │
   └─> lbu-persist
       └─> Registers for shutdown

4. System Ready (much faster!)
   └─> All runtime changes restored, k3s operational
```

**Reboot Timeline:**
- 0:00 - Reboot initiated
- 0:30 - Alpine boots, overlay loads
- 0:45 - storage-init mounts existing partition
- 0:50 - lbu-restore extracts runtime overlay (SSH keys, configs restored!)
- 1:00 - system-bootstrap skips install (already initialized)
- 1:30 - k3s-bootstrap starts k3s service
- 2:00 - System ready (much faster than first boot!)

### Shutdown Process

When you shutdown or reboot:

```
1. Shutdown/Reboot Command Issued
   └─> OpenRC begins shutdown sequence

2. Services Stop in Reverse Order
   ├─> k3s stops
   ├─> k3s-bootstrap stops
   ├─> system-bootstrap stops
   │
   ├─> lbu-persist stop() ⭐ KEY STEP
   │   ├─> Runs /usr/local/bin/lbu-commit-runtime
   │   ├─> Creates overlay package with ALL runtime changes:
   │   │   ├─> /etc/ssh/* (SSH host keys)
   │   │   ├─> /root/.ssh/authorized_keys
   │   │   ├─> /etc/network/interfaces
   │   │   ├─> /etc/hostname, /etc/hosts, /etc/resolv.conf
   │   │   ├─> /etc/k3s/* (k3s configuration)
   │   │   ├─> /etc/timezone, /etc/localtime
   │   │   └─> Custom services and runlevels
   │   ├─> Saves to /mnt/data/runtime-{hostname}.apkovl.tar.gz
   │   └─> Syncs to disk
   │
   ├─> lbu-restore stops
   ├─> storage-init unmounts /mnt/data
   └─> System halts or reboots
```

### What Persists vs What Reloads

**Persists on Disk (`/mnt/data/`):**
- ✅ k3s cluster data (`/var/lib/rancher/k3s/`)
- ✅ k3s configuration (`/etc/k3s/`)
- ✅ LBU runtime overlay (`runtime-{hostname}.apkovl.tar.gz`)
- ✅ APK package cache (`/var/cache/apk/`)
- ✅ User data in k3s persistent volumes
- ✅ System initialization markers (`.storage-init-complete`, `.system-initialized`)

**Saved in LBU Runtime Overlay (restored on boot):**
- ✅ SSH host keys (consistent fingerprint)
- ✅ SSH authorized_keys (remote access)
- ✅ Network configuration
- ✅ Hostname and timezone
- ✅ Custom services and runlevels
- ✅ LBU configuration itself

**Reloaded Fresh Each Boot (from original overlay):**
- 🔄 Base Alpine system
- 🔄 Original service definitions
- 🔄 Default apkovl structure
- 🔄 Build-time configuration

**Lost on Reboot (unless saved to /mnt/data or LBU):**
- ❌ Log files (unless explicitly persisted)
- ❌ /tmp directory contents
- ❌ Runtime processes state
- ❌ Memory caches

### LBU Backup Mechanism

**How LBU Works:**

1. **Configuration** (`/etc/lbu/lbu.conf`):
   ```
   LBU_BACKUPDIR=/mnt/data
   ```

2. **Include List** (`/etc/lbu/include`):
   ```
   etc/hostname
   etc/hosts
   etc/resolv.conf
   etc/network/interfaces
   etc/ssh
   etc/k3s
   root/.ssh/authorized_keys
   # ... and more
   ```

3. **Custom Commit Script** (`/usr/local/bin/lbu-commit-runtime`):
   ```bash
   #!/bin/sh
   HOSTNAME=$(hostname)
   BACKUP_FILE="/mnt/data/runtime-${HOSTNAME}.apkovl.tar.gz"
   lbu package "$BACKUP_FILE"
   ```

4. **Automatic Execution:**
   - First boot: `system-bootstrap` runs `lbu-commit-runtime`
   - Every shutdown: `lbu-persist stop()` runs `lbu-commit-runtime`
   - Manual: Run `lbu commit` or `lbu-commit-runtime` anytime

**Manual LBU Operations (on running system):**

```bash
# See what will be backed up
lbu status

# See current include list
lbu list-backup

# Add a file to backups
lbu include /path/to/file

# Save current state immediately
lbu commit

# Or use the custom script
lbu-commit-runtime

# See recent backups
ls -lh /mnt/data/*.apkovl.tar.gz
```

### Service Dependencies

The boot order is enforced by OpenRC dependencies:

```
storage-init (depends: localmount)
    ↓
lbu-restore (depends: storage-init)
    ↓
system-bootstrap (depends: storage-init)
    ↓
k3s-bootstrap (depends: storage-init, after: system-bootstrap)
    ↓
k3s (depends: k3s-bootstrap)
    ↓
lbu-persist (depends: storage-init, after: system-bootstrap)
```

**Key Dependency Rules:**
- `need` - Hard dependency (service must succeed)
- `after` - Ordering only (run after, but don't require)
- `before` - Run before another service
- `provide` - Service provides a virtual dependency

### Testing Boot/Reboot in QEMU

Test the boot process without real hardware:

```bash
# First boot test (creates partitions, installs everything)
./test/test-alpine-diskless-boot.sh

# Inside VM, reboot to test restoration
reboot

# Verify SSH keys persist
ssh root@localhost -p 2222
cat /etc/ssh/ssh_host_rsa_key.pub
# Key should be the same after reboot!
```

### Troubleshooting Boot Issues

**Check service status:**
```bash
rc-status                    # See what's running
rc-service storage-init status
rc-service lbu-restore status
rc-service system-bootstrap status
```

**Check markers:**
```bash
ls -la /mnt/data/.storage-init-complete
ls -la /mnt/data/.system-initialized
ls -la /mnt/data/runtime-*.apkovl.tar.gz
```

**Check LBU configuration:**
```bash
cat /etc/lbu/lbu.conf
cat /etc/lbu/include
lbu status
```

**View boot logs:**
```bash
dmesg                        # Kernel boot messages
cat /var/log/messages        # System log (includes OpenRC)
grep "storage-init" /var/log/messages
grep "lbu-restore" /var/log/messages
```

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

## Testing with QEMU

Before deploying to physical Raspberry Pis, test your configuration with QEMU simulation.

### Basic Test

```bash
# Test Alpine diskless boot process
./test/test-alpine-diskless-boot.sh
```

This simulates the exact boot process of a Raspberry Pi:
1. Alpine kernel loads from ISO
2. initramfs mounts root as tmpfs (RAM)
3. Alpine finds and loads .apkovl overlay
4. OpenRC starts services
5. Your k3s_bootstrap runs automatically

### Memory Requirements

Alpine diskless runs entirely in RAM. The test script uses **2GB RAM** by default:

| Component | RAM Usage |
|-----------|-----------|
| Alpine base | ~100MB |
| Runtime apkovl extraction | ~200-500MB |
| Package installation | ~300-500MB |
| k3s runtime | ~500MB-1GB |
| **Total recommended** | **2GB minimum** |

### Using Pre-Partitioned Template

For faster iterations, create a reusable partitioned disk template:

**One-time setup:**
```bash
# Run first boot (partitions and formats disk)
./test/test-alpine-diskless-boot.sh

# After boot completes, save template
cd test/vm-diskless
cp data.qcow2 data-partitioned-template.qcow2
```

**Every test run:**
```bash
# Clean start
rm -f test/vm-diskless/data.qcow2

# Run test - automatically uses template
./test/test-alpine-diskless-boot.sh
```

Benefits:
- ✅ No partitioning/formatting on each boot
- ✅ Mount works immediately
- ✅ Faster test iterations
- ✅ Avoids first-boot timing issues

### Test Modes

```bash
# DHCP mode (default)
./test/test-alpine-diskless-boot.sh

# Bridge mode (requires host bridge setup)
NETWORK_MODE=bridge ./test/test-alpine-diskless-boot.sh
```

### Accessing Test VM

```bash
# SSH (DHCP mode)
ssh root@localhost -p 2222

# k3s API
curl -k https://localhost:6443

# Web services
curl http://localhost:8080
```

## Support

For issues and questions:
- **Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md)** for detailed solutions
- Validate your YAML configuration first
- Test with QEMU before deploying to hardware
- Ensure you're using the correct platform-specific commands
- Review the generated files in `builds/` directory for debugging

## Migration from Script-Based Setup

If you're migrating from the old hardcoded script approach:
1. Create a YAML config file matching your existing setup
2. Use the new `build-from-yaml.sh` workflow
3. The functionality is the same, but much more flexible and maintainable