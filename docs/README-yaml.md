# Alpine Linux Diskless k3s Cluster - YAML Configuration

This project creates a multi-node k3s cluster running on Alpine Linux in diskless mode using YAML-based configuration for easy customization and deployment automation.

## YAML Configuration Approach

Instead of hardcoding network settings and node information in shell scripts, this setup uses a single YAML configuration file (`cluster-config.yaml`) to define your entire cluster setup.

## Quick Start

### 1. Configure Your Cluster

Copy and customize the cluster configuration:

```bash
cp cluster-config.yaml my-cluster.yaml
```

Edit `my-cluster.yaml` with your specific settings:

```yaml
cluster:
  name: "my-k3s-cluster"

network:
  subnet: "192.168.1.0/24"
  gateway: "192.168.1.1"
  dns_servers:
    - "192.168.1.1"
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

### 2. Validate Configuration

```bash
./validate-config.sh my-cluster.yaml
```

### 3. Build Complete Setup

```bash
# Build everything from YAML configuration
./build-from-yaml.sh my-cluster.yaml

# Or use default cluster-config.yaml
./build-from-yaml.sh
```

### 4. Deploy to SD Cards

```bash
# Prepare SD cards using YAML configuration (replace /dev/sdX with actual device)
sudo ./setup-sd-card.sh /dev/sdX my-cluster.yaml

# Or use default configuration file
sudo ./setup-sd-card.sh /dev/sdX

# Copy apkovl files to boot partitions
# The script will show which .apkovl.tar.gz files were created
```

### 5. Boot Your Cluster

1. Insert SD cards into nodes
2. Power on master node first
3. Power on worker nodes after master is running
4. Wait for cluster formation (5-10 minutes)

## Configuration File Structure

### Basic Settings
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
  subnet: "192.168.1.0/24"       # Network subnet in CIDR
  gateway: "192.168.1.1"         # Gateway IP address
  dns_servers:                   # List of DNS servers
    - "192.168.1.1"
    - "8.8.8.8"
  
  loadbalancer_pool:             # MetalLB IP range
    start: "192.168.1.100"
    end: "192.168.1.199"
```

### Node Definition
```yaml
nodes:
  - name: "master-node"          # Unique node name
    ip: "192.168.1.10"           # Static IP address
    role: "master"               # Role: master or worker
    
  - name: "worker-node-1"
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
  authorized_keys:               # List of SSH public keys
    - "ssh-rsa AAAAB3NzaC1yc2E... user@host"
    - "ssh-ed25519 AAAAC3NzaC1... user2@host2"
```

### Storage Configuration
```yaml
storage:
  device: "/dev/mmcblk0"         # SD card device path
  boot_partition_size: "512MiB"  # Boot partition size
  data_mount: "/mnt/data"        # Persistent data mount point
  persistent_paths:              # Paths to persist
    - "/etc/k3s"
    - "/var/lib/k3s"
```

### Alpine Linux Settings
```yaml
alpine:
  version: "3.18.6"
  architecture: "aarch64"
  packages:                      # Additional packages to install
    - "curl"
    - "ca-certificates"
    - "iptables"
```

## Available Scripts

### Core Scripts
- `validate-config.sh` - Validates YAML configuration
- `build-from-yaml.sh` - Builds complete setup from YAML
- `create-apkovl-yaml.sh` - Creates apkovl structure from YAML
- `setup-k3s-yaml.sh` - Configures k3s from YAML
- `generate-manifests-yaml.sh` - Generates Kubernetes manifests
- `create-apkovl-archives.sh` - Creates .apkovl.tar.gz files from YAML

### Utility Scripts
- `setup-sd-card.sh` - Prepares SD cards using YAML configuration
- `lib/yaml-parser.sh` - YAML parsing library

## Multiple Environment Management

You can maintain different configurations for different environments:

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

## Standalone Archive Creation

If you only need to create the .apkovl.tar.gz files (after already building the configuration):

```bash
# Create archives from default config
./create-apkovl-archives.sh

# Create archives from custom config  
./create-apkovl-archives.sh my-cluster.yaml

# This will automatically:
# - Read all nodes from YAML config
# - Create .apkovl.tar.gz for each node
# - Show file sizes and next steps
# - Provide copy commands for SD cards
```

**Output example:**
```
=== Creating apkovl archives from YAML configuration ===
Cluster: homelab-k3s

Processing master-01 (master - 192.168.1.10)...
  ✅ Created master-01.apkovl.tar.gz (2.1M)

Processing worker-01 (worker - 192.168.1.11)...
  ✅ Created worker-01.apkovl.tar.gz (2.0M)

📁 Created apkovl archives:
  • master-01.apkovl.tar.gz (2.1M) - master node
  • worker-01.apkovl.tar.gz (2.0M) - worker node

Next steps:
1. Setup SD cards: sudo ./setup-sd-card.sh /dev/diskN my-cluster.yaml
2. Copy apkovl files to SD card boot partitions:
   cp master-01.apkovl.tar.gz /Volumes/BOOT/
   cp worker-01.apkovl.tar.gz /Volumes/BOOT/
```

## Configuration Examples

### Small Home Lab (3 nodes)
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
  - name: "pi-master"
    ip: "192.168.1.10"
    role: "master"
  - name: "pi-worker1"
    ip: "192.168.1.11"
    role: "worker"
  - name: "pi-worker2"
    ip: "192.168.1.12"
    role: "worker"
```

### Larger Development Cluster (5 nodes)
```yaml
cluster:
  name: "dev-k3s-cluster"

network:
  subnet: "10.0.0.0/24"
  gateway: "10.0.0.1"
  dns_servers: ["10.0.0.1", "8.8.8.8"]
  loadbalancer_pool:
    start: "10.0.0.100"
    end: "10.0.0.150"

nodes:
  - name: "k3s-master-01"
    ip: "10.0.0.10"
    role: "master"
  - name: "k3s-worker-01"
    ip: "10.0.0.21"
    role: "worker"
  - name: "k3s-worker-02"
    ip: "10.0.0.22"
    role: "worker"
  - name: "k3s-worker-03"
    ip: "10.0.0.23"
    role: "worker"
  - name: "k3s-worker-04"
    ip: "10.0.0.24"
    role: "worker"

services:
  metallb:
    enabled: true
    version: "v0.13.12"
  nginx_ingress:
    enabled: true
    version: "v1.8.4"
    replicas: 3
```

## Validation Features

The `validate-config.sh` script checks for:

- ✅ Required configuration fields
- ✅ Valid IP address formats
- ✅ Network subnet consistency
- ✅ Duplicate IP addresses or node names
- ✅ At least one master node
- ✅ Service configuration consistency
- ✅ SSH configuration validity
- ⚠️  Warnings for potential issues

## Benefits of YAML Configuration

1. **Reusability**: Save and reuse configurations for different environments
2. **Version Control**: Track configuration changes with Git
3. **Validation**: Built-in validation prevents common configuration errors
4. **Flexibility**: Easy to modify without editing multiple shell scripts
5. **Documentation**: Self-documenting configuration files
6. **Automation**: Perfect for CI/CD and infrastructure-as-code workflows

## Migration from Shell Scripts

If you have an existing setup using the shell script approach, you can create a YAML configuration file that matches your current settings and use the new workflow for future deployments.

## Troubleshooting

### Configuration Issues
```bash
# Validate your configuration
./validate-config.sh your-config.yaml

# Check YAML syntax
python3 -c "import yaml; yaml.safe_load(open('your-config.yaml'))"
```

### Build Issues
```bash
# Ensure scripts are executable
chmod +x *.sh lib/*.sh

# Check if lib directory exists
mkdir -p lib

# Rebuild from scratch
rm -rf *-apkovl *.apkovl.tar.gz k3s-manifests/
./build-from-yaml.sh your-config.yaml
```

### Deployment Verification
```bash
# After cluster is running, verify from master node:
kubectl get nodes -o wide
kubectl get pods --all-namespaces
kubectl get svc --all-namespaces
```