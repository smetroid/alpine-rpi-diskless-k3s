# Alpine Linux Diskless k3s Cluster

A system for creating multi-node Kubernetes clusters running entirely from RAM on Raspberry Pi, with persistent storage on SD cards. Uses YAML-based configuration for easy customization and deployment automation.

## Overview

This project creates a diskless Alpine Linux k3s cluster where:
- Each node runs entirely from RAM for optimal performance
- System boots from SD card with minimal footprint
- Persistent storage is maintained on SD card partitions
- Configuration is managed through simple YAML files
- Supports both single-node and multi-node clusters

## Architecture

### Core Components

- **Alpine Linux Diskless**: Runs entirely from RAM, boots from SD card
- **k3s**: Lightweight Kubernetes distribution for cluster management
- **YAML Configuration**: Single source of truth for all cluster settings
- **apkovl Archives**: Alpine's overlay system for persistent configuration
- **Cross-Platform Support**: Works on both Linux and macOS for SD card preparation

### Directory Structure

```
alpine-rpi-diskless/
├── scripts/                    # All build scripts (source of truth)
│   ├── build-from-yaml.sh     # Main build orchestrator
│   ├── create-apkovl-yaml.sh  # Creates apkovl directory structure
│   ├── setup-k3s-yaml.sh     # Configures k3s settings
│   ├── generate-manifests-yaml.sh # Generates Kubernetes manifests
│   ├── create-apkovl-archives.sh # Creates final .apkovl.tar.gz files
│   ├── setup-bootable-device.sh # SD card preparation
│   └── validate-config.sh     # Configuration validation
├── lib/
│   └── yaml-parser.sh         # YAML parsing library
├── builds/                    # Generated output directory
├── test/                      # Testing and simulation scripts
├── docs/                      # Documentation
├── k3s.yaml                   # Main cluster configuration
└── cluster-config.yaml.example # Example configuration
```

## Quick Start

### Prerequisites

- A Raspberry Pi 3 or 4 (recommended 4GB+ RAM)
- SD card (minimum 8GB, recommended 16GB+)
- macOS or Linux development machine
- SSH keys for remote access

### Basic Usage

1. **Configure your cluster**:
   ```bash
   cp cluster-config.yaml.example my-cluster.yaml
   # Edit my-cluster.yaml with your settings
   ```

2. **Validate the configuration**:
   ```bash
   make validate CONFIG=my-cluster.yaml
   ```

3. **Build the cluster setup**:
   ```bash
   make build CONFIG=my-cluster.yaml
   ```

4. **Prepare SD cards**:
   ```bash
   # Using make (recommended)
   make setup-sd DEVICE=/dev/sdX NODE=k3s-21

   # Or directly
   sudo ./scripts/setup-bootable-device.sh /dev/sdX my-cluster.yaml k3s-21
   ```

5. **Boot and join**: Insert SD cards into your Raspberry Pis and power on. The nodes will automatically join the cluster.

## Configuration

The cluster is configured through YAML files. Key configuration sections include:

### Network Settings
- Network interface configuration
- Gateway and DNS settings
- Static IP assignments per node

### Node Definitions
- Node hostnames and IP addresses
- Role assignment (server/agent)
- Optional taints for dedicated workloads

### k3s Settings
- Cluster token for node joining
- Server/agent specific configurations
- TLS and security options

### Service Configuration
- OpenRC service dependencies
- Boot-time service startup order
- Custom service scripts

## Development

### Build Commands

```bash
# Using make (recommended)
make build              # Build from default config (k3s.yaml)
make build-test         # Build test overlays from qemu.yaml
make validate           # Validate default config
make clean              # Clean production build artifacts
make clean-test         # Clean test build artifacts

# With custom config
make build CONFIG=my-cluster.yaml
make validate CONFIG=my-cluster.yaml

# Or run scripts directly
./scripts/build-from-yaml.sh [config-file.yaml]
./scripts/validate-config.sh [config-file.yaml]

# Individual build steps (if needed)
./scripts/create-apkovl-yaml.sh [config-file.yaml]
./scripts/setup-k3s-yaml.sh [config-file.yaml]
./scripts/generate-manifests-yaml.sh [config-file.yaml]
./scripts/create-apkovl-archives.sh [config-file.yaml]
```

### Testing

The project provides unified QEMU testing for both single and multi-node scenarios:

```bash
# Build test overlays
make build-test

# Single-node test (just the server)
./test/qemu-test.sh server

# Multi-node cluster - run in separate terminals
./test/qemu-test.sh server           # Terminal 1
./test/qemu-test.sh worker qemu-2    # Terminal 2
./test/qemu-test.sh worker qemu-3    # Terminal 3

# Management commands
./test/qemu-test.sh status
./test/qemu-test.sh stop all
```

Or use Make targets:
```bash
make test-server              # Start server VM
make test-worker NODE=qemu-2  # Start worker VM
make test-cluster-status      # Show running VMs
make test-cluster-stop        # Stop all VMs
```

**Access the cluster:**
```bash
# SSH to a node (port varies by IP: 10.99.0.21 -> 2221)
ssh -p 2221 root@localhost

# Verify cluster
kubectl get nodes
kubectl get pods -A
```

**Clean test data:**
```bash
make clean-test           # Remove test build artifacts
rm -rf test/qemu-cluster  # Wipe VM data disks
```

## Key Architecture Principles

1. **YAML-Driven**: All configuration managed through YAML files
2. **Dynamic Generation**: Scripts generate apkovl overlays dynamically
3. **Persistent Storage**: Critical data survives reboots via SD card persistence
4. **Service Dependencies**: OpenRC services with proper dependency management
5. **Cross-Platform**: Works on both development machines and target devices

## Service Boot Sequence

OpenRC services follow this dependency chain:
1. `qemu-device-setup` (testing only) or native device detection
2. `system-bootstrap` (package installation, timezone, SSH setup)
3. `k3s-bootstrap` (k3s installation and cluster formation)
4. `k3s` service (actual k3s daemon)

## Persistence Model

The system uses a multi-layered persistence strategy combining Alpine's LBU (Local Backup Utility) with bind mounts for critical data:

### Storage Layers

| Layer | Location | Contents | Persistence |
|-------|----------|----------|-------------|
| **RAM Overlay** | In-memory | Running system files | Lost on reboot |
| **apkovl Archive** | SD card (boot partition) | Base configuration files | Reloaded each boot |
| **Bind Mounts** | SD card (data partition) | Critical runtime data | Persists across reboots |
| **LBU Backups** | SD card (data partition) | Configuration snapshots | Manual/triggered commits |

### The storage-init Service

The `storage-init` OpenRC service (runs on every boot) orchestrates all persistent storage:

1. **Device Detection**: Auto-detects storage device (SD card, USB, virtio)
2. **Partition Mounting**: Mounts data partition to `/mnt/data`
3. **Bind Mount Creation**: Sets up persistent directories via bind mounts
4. **Overlay Copy**: First-boot only - copies apkovl files to persistent storage
5. **Marker File**: Creates `.copied-from-overlay` to prevent re-copy on subsequent boots

### Persistent Directory Bind Mounts

| Source (persistent) | Target (runtime) | Purpose |
|---------------------|------------------|---------|
| `/mnt/data/etc-rancher` | `/etc/rancher` | Rancher/k3s configs (entire directory) |
| `/mnt/data/var-lib-rancher-k3s` | `/var/lib/rancher/k3s` | k3s database and state |
| `/mnt/data/etc-lbu` | `/etc/lbu` | LBU configuration |
| `/mnt/data/usr-local-bin` | `/usr/local/bin` | Custom scripts |
| `/mnt/data/var-lib-chrony` | `/var/lib/chrony` | NTP drift file |
| `/mnt/data/ssh` | - | SSH host keys (copied by ssh-persist) |

**Why bind mounts instead of direct paths?**
- Overlay files in apkovl are first-boot defaults
- Bind mount shadows overlay, showing persisted data instead
- k3s and services write directly to persistent storage
- No manual sync needed - writes go straight to SD card

### How Reboot Persistence Works

**First Boot:**
```
1. Alpine loads kernel + apkovl into RAM
2. storage-init runs:
   - Mounts /mnt/data from SD card
   - Copies /etc/rancher/* → /mnt/data/etc-rancher/ (first time only)
   - Creates marker: /mnt/data/etc-rancher/.copied-from-overlay
   - Bind mounts: /mnt/data/etc-rancher → /etc/rancher
3. k3s starts, writes to /etc/rancher → actually writes to /mnt/data
```

**Subsequent Reboots:**
```
1. Alpine loads kernel + apkovl into RAM (fresh)
2. storage-init runs:
   - Mounts /mnt/data from SD card
   - Sees .copied-from-overlay marker → skips copy
   - Bind mounts: /mnt/data/etc-rancher → /etc/rancher
3. Overlay files are hidden by bind mount
4. k3s sees all its previous files from SD card
```

### LBU (Local Backup Utility) Backup

The `lbu-persist` service provides configuration snapshot capability:

**Triggered on:**
- System shutdown/reboot
- Manual: `/usr/local/bin/lbu-commit-runtime`

**What gets backed up:**
- Configuration-only changes (not large data)
- Files modified outside bind-mount directories
- Creates `runtime-{hostname}-{timestamp}.apkovl.tar.gz`

**What's NOT backed up (already persisted via bind mounts):**
- `/etc/rancher/*` → Already on `/mnt/data/etc-rancher`
- `/var/lib/rancher/k3s/*` → Already on `/mnt/data/var-lib-rancher-k3s`
- `/root/.ssh/*` → Already copied by ssh-persist service
- SSH host keys → Already on `/mnt/data/ssh`

**LBU is minimal because:**
- Large data (k3s database) already persisted via bind mounts
- Only captures small config changes made during runtime
- Fast shutdown/reboot cycles

## Platform-Specific Notes

### macOS Development
- Use `diskutil list` to find SD card devices
- SD card naming: `/dev/diskN` (not `/dev/diskNsX`)
- No additional tools required for SD card setup

### Linux Development
- Use `lsblk` to find SD card devices
- SD card naming: `/dev/sdX` (partitions: `/dev/sdXN`)
- Standard Linux tools work out of the box

### Raspberry Pi Target
- Real hardware uses `/dev/mmcblk0` device names
- Automatic partition creation and formatting on first boot
- SSH access enabled by default with configured keys

## Generated Files

The build process generates files in the `builds/` directory:
- `{node-name}-apkovl/`: Unpacked overlay directories
- `{node-name}.apkovl.tar.gz`: Final deployment archives
- `k3s-manifests/`: Kubernetes manifests (MetalLB, NGINX Ingress)
- `k3s-token.txt`: Cluster join token

## Troubleshooting

1. **Check generated files**: Look in `builds/` directory for generated files
2. **Validate YAML syntax**: `python3 -c "import yaml; yaml.safe_load(open('config.yaml'))"`
3. **Run individual script steps**: Isolate issues by running scripts separately
4. **Check OpenRC service logs**: Use `rc-status` and `rc-service` on target devices

## License

[Add your license here]
