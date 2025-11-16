# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Alpine Linux diskless k3s cluster setup system for Raspberry Pi. The project creates multi-node Kubernetes clusters running entirely from RAM with persistent storage on SD cards. The system uses YAML-based configuration for easy customization and deployment automation.

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
│   ├── setup-sd-card.sh       # SD card preparation
│   └── validate-config.sh     # Configuration validation
├── lib/
│   └── yaml-parser.sh         # YAML parsing library
├── builds/                    # Generated output directory
├── test/                      # Testing and simulation scripts
├── docs/                      # Documentation
├── k3s.yaml                   # Main cluster configuration
└── cluster-config.yaml.example # Example configuration
```

### Key Architecture Principles
1. **YAML-Driven**: All configuration managed through YAML files
2. **Dynamic Generation**: Scripts generate apkovl overlays dynamically
3. **Persistent Storage**: Critical data survives reboots via SD card persistence
4. **Service Dependencies**: OpenRC services with proper dependency management
5. **Cross-Platform**: Works on both development machines and target devices

## Development Commands

### Build and Validation
```bash
# Validate YAML configuration
./validate-config.sh [config-file.yaml]

# Build complete cluster setup from YAML
./build-from-yaml.sh [config-file.yaml]

# Individual build steps (if needed)
./scripts/create-apkovl-yaml.sh [config-file.yaml]
./scripts/setup-k3s-yaml.sh [config-file.yaml]
./scripts/generate-manifests-yaml.sh [config-file.yaml]
./scripts/create-apkovl-archives.sh [config-file.yaml]
```

### SD Card Preparation
```bash
# Linux
sudo ./setup-sd-card.sh /dev/sdX [config-file.yaml]

# macOS
sudo ./setup-sd-card.sh /dev/diskN [config-file.yaml]
```

### Testing and Simulation
```bash
# Test Alpine diskless boot process
./test/test-alpine-diskless-boot.sh

# Test automatic network detection
./test/test-auto-network.sh
```

### Configuration Management
```bash
# Use default configuration
cp cluster-config.yaml.example my-cluster.yaml

# Multiple environments
./build-from-yaml.sh dev-cluster.yaml
./build-from-yaml.sh prod-cluster.yaml
```

## Key Files and Their Purposes

### Configuration Files
- `k3s.yaml`: Main cluster configuration (currently active)
- `cluster-config.yaml.example`: Template configuration file
- Individual `*-cluster.yaml`: Environment-specific configurations

### Generated Files (in builds/)
- `{node-name}-apkovl/`: Unpacked overlay directories
- `{node-name}.apkovl.tar.gz`: Final deployment archives
- `k3s-manifests/`: Kubernetes manifests (MetalLB, NGINX Ingress)
- `k3s-token.txt`: Cluster join token

### Critical Scripts
- `scripts/build-from-yaml.sh`: Main orchestrator that calls all other scripts
- `lib/yaml-parser.sh`: YAML parsing functions used by all scripts
- Root-level wrapper scripts (`build-from-yaml.sh`, `validate-config.sh`, etc.)

## Development Guidelines

### Script Modification Rules
**CRITICAL**: When modifying functionality, always edit scripts in the `scripts/` directory, not the root-level wrapper scripts. The wrapper scripts just call the actual implementation in `scripts/`.

- Root-level scripts (`build-from-yaml.sh`, `validate-config.sh`) are wrappers
- Actual implementation is in `scripts/` directory
- Always modify `scripts/build-from-yaml.sh` or `scripts/create-apkovl-yaml.sh` for functionality changes

### YAML Configuration
The system uses a custom YAML parser (`lib/yaml-parser.sh`) that supports:
- Nested key access (e.g., `network.gateway`)
- Array parsing (e.g., `nodes`, `dns_servers`)
- Service configuration parsing
- Node definitions with IP, role, and optional taints

### Testing Strategy
- Use QEMU simulation for testing (`test/test-alpine-diskless-boot.sh`)
- Supports both DHCP and bridge networking modes
- Simulates exact Raspberry Pi boot process including device setup

### Service Dependencies
OpenRC services follow this dependency chain:
1. `qemu-device-setup` (testing only) or native device detection
2. `system-bootstrap` (package installation, timezone, SSH setup)
3. `k3s-bootstrap` (k3s installation and cluster formation)
4. `k3s` service (actual k3s daemon)

### Persistence Model
The system uses Alpine's LBU (Local Backup Utility) combined with SD card persistence:
- Boot partition: Alpine kernel and .apkovl overlay
- Data partition: Persistent storage for k3s data, configuration backups
- Runtime overlays: Dynamically saved configuration changes

## Common Development Tasks

### Adding New Node Configuration
1. Edit the YAML configuration file to add new nodes
2. Run `./validate-config.sh` to check configuration
3. Run `./build-from-yaml.sh` to generate new overlays
4. Deploy to SD cards using `./setup-sd-card.sh`

### Modifying k3s Configuration
1. Edit YAML configuration (k3s section)
2. Modify `scripts/setup-k3s-yaml.sh` if new k3s features needed
3. Test with `./build-from-yaml.sh`

### Adding New Services
1. Add service configuration to YAML schema
2. Update `scripts/generate-manifests-yaml.sh` for Kubernetes manifests
3. Update `lib/yaml-parser.sh` for new parsing functions if needed

### Troubleshooting Build Issues
1. Check `builds/` directory for generated files
2. Validate YAML syntax: `python3 -c "import yaml; yaml.safe_load(open('config.yaml'))"`
3. Run individual script steps to isolate issues
4. Check OpenRC service logs on target devices

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

This architecture enables rapid deployment of k3s clusters while maintaining consistency across different environments and platforms.