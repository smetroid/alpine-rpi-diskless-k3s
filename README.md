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

The project provides two testing approaches for different use cases:

#### Single VM Testing
Use this to validate build scripts and apkovl overlays quickly:

```bash
# Build test overlays
make build-test

# Boot single VM (uses qemu.yaml configuration)
./test/test-qemu.sh qemu.yaml

# Or use make recipe
make test
```

This boots a single VM with minimal resources to verify:
- Overlay generation works correctly
- System bootstrap completes
- k3s installs and starts properly

#### QEMU Cluster Testing
Use this to test multi-node cluster formation with socket networking:

```bash
# Build and start full cluster (master + workers)
make qemu-cluster

# Check cluster status
make qemu-cluster-status

# Stop all cluster VMs
make qemu-cluster-stop
```

The cluster testing creates:
- VM-to-VM network on `10.99.0.x` subnet (socket networking)
- SSH access via `10.0.2.x` addresses (QEMU user networking)
- Per-node log files in `test/qemu-cluster/` (gitignored)

To access the cluster:
```bash
# SSH to master node
ssh -p 2222 root@localhost

# Verify cluster
kubectl get nodes
kubectl get pods -A
```

**Note**: Cluster VMs store k3s data in qcow2 files that persist across reboots. To perform a clean test:
```bash
make clean-test  # Remove test build artifacts
rm -rf test/qemu-cluster/*.qcow2  # Wipe data disks
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

The system uses Alpine's LBU (Local Backup Utility) combined with SD card persistence:
- **Boot partition**: Alpine kernel and .apkovl overlay
- **Data partition**: Persistent storage for k3s data, configuration backups
- **Runtime overlays**: Dynamically saved configuration changes

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
