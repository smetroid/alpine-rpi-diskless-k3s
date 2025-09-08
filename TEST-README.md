# Alpine Diskless k3s Testing & Development Environment

This README covers the testing framework and development tools for the Alpine Linux Diskless k3s cluster project.

## Test Directory Overview

The `test/` directory provides a complete QEMU-based testing environment that simulates the exact boot process of a Raspberry Pi running Alpine Linux in diskless mode.

### Test Directory Structure

```
test/
├── test-alpine-diskless-boot.sh    # Main test script for QEMU simulation
├── vm-diskless/                     # QEMU virtual machine files
│   ├── alpine-virt-3.22.1-x86_64.iso  # Alpine Linux ISO (downloaded)
│   ├── data.qcow2                   # Virtual data disk (4GB)
│   └── overlaydir/                  # Overlay files for testing
├── k3s-21.apkovl.tar.gz            # Test overlay archive
├── k3s-21.apkovl/                   # Extracted test overlay
└── setup.log                       # Test execution logs
```

## Test Files Summary

### 1. `test-alpine-diskless-boot.sh`
**Purpose**: Main testing script that simulates the exact Raspberry Pi boot process using QEMU.

**What it does**:
- Downloads Alpine Linux 3.22.1 x86_64 ISO if not present
- Creates a 4GB virtual data disk (QCOW2 format)
- Copies overlay files to simulation environment
- Boots Alpine in diskless mode with proper networking
- Simulates the entire boot chain: kernel → initramfs → tmpfs → overlay loading → service startup

**Key Features**:
- **True Diskless Simulation**: Runs entirely from RAM like real Raspberry Pi
- **Automatic Overlay Loading**: Simulates Alpine's automatic .apkovl discovery
- **Network Forwarding**: SSH access via port 2222 (`ssh -p 2222 root@localhost`)
- **Persistent Storage**: Virtual data disk for testing persistence

### 2. Test Overlay Files
- **`k3s-21.apkovl.tar.gz`**: Test overlay archive containing k3s configuration
- **`k3s-21.apkovl/`**: Extracted overlay with full directory structure
- **`overlaydir/`**: Working directory for overlay files during testing

## Required Tools and Utilities

### Core Requirements

#### 1. QEMU (Virtual Machine Emulation)
**Required for**: Testing diskless boot simulation

**Installation**:
```bash
# macOS
brew install qemu

# Ubuntu/Debian
sudo apt update && sudo apt install qemu-system-x86

# RHEL/CentOS/Fedora
sudo dnf install qemu-system-x86

# Alpine Linux
apk add qemu-system-x86_64
```

**Components Used**:
- `qemu-system-x86_64`: Main x86_64 emulator
- `qemu-img`: Disk image creation and management

#### 2. Network Tools
**Required for**: Downloading Alpine ISO and k3s installation

**Installation**:
```bash
# Most systems have curl pre-installed
# If missing:

# macOS
brew install curl

# Ubuntu/Debian
sudo apt install curl

# RHEL/CentOS/Fedora
sudo dnf install curl

# Alpine Linux
apk add curl
```

#### 3. Storage Management Tools
**Required for**: SD card preparation and partition management

**Linux Tools**:
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install util-linux parted e2fsprogs dosfstools

# RHEL/CentOS/Fedora
sudo dnf install util-linux parted e2fsprogs dosfstools

# Alpine Linux
apk add util-linux parted e2fsprogs dosfstools
```

**macOS Tools** (built-in):
- `diskutil`: Disk management (built-in)
- `mount`/`umount`: File system mounting (built-in)

### Tool Breakdown by Function

#### Partitioning Tools
| Tool | Platform | Purpose |
|------|----------|---------|
| `sfdisk` | Linux | Primary partitioning tool |
| `parted` | Linux | Alternative partitioning tool |
| `cfdisk` | Linux | Interactive partitioning fallback |
| `fdisk` | Linux/macOS | Basic partitioning (fallback) |
| `diskutil` | macOS | Main disk management tool |

#### File System Tools
| Tool | Platform | Purpose |
|------|----------|---------|
| `mkfs.vfat` | Linux/macOS | Create FAT32 boot partition |
| `mkfs.ext4` | Linux | Create ext4 data partition |
| `mount`/`umount` | Linux/macOS | File system mounting |

#### Development Tools
| Tool | Platform | Purpose |
|------|----------|---------|
| `bash` | Linux/macOS | Script execution |
| `tar` | Linux/macOS | Archive handling |
| `gzip` | Linux/macOS | Compression |

## Getting Started with Testing

### 1. Prerequisites Check
```bash
# Check QEMU installation
qemu-system-x86_64 --version

# Check required tools (Linux)
which sfdisk parted mkfs.vfat mkfs.ext4 curl

# Check required tools (macOS)
which diskutil curl
diskutil list  # Should work without errors
```

### 2. Build Test Environment
```bash
# From project root
./build-from-yaml.sh cluster-config.yaml.example

# This creates the overlay files needed for testing:
# - builds/k3s-21-apkovl/ (directory structure)
# - builds/k3s-21.apkovl.tar.gz (compressed archive)
```

### 3. Run Test Simulation
```bash
cd test/
./test-alpine-diskless-boot.sh
```

**Expected Output**:
```
🍃 Alpine Linux Diskless Boot Simulation
==========================================

This test simulates the EXACT boot process of a Raspberry Pi:
  1. 🥧 Pi loads Alpine kernel from SD card boot partition
  2. 🔄 initramfs starts and mounts root as tmpfs (RAM)  
  3. 📦 Alpine automatically finds and loads .apkovl overlay
  4. 🚀 OpenRC starts services including local.d scripts
  5. ⚙️  Your k3s_bootstrap runs automatically via local.d

📥 Downloading Alpine Linux... (if needed)
Creating data.qcow2 (4G)...
Creating overlay archive...

🚀 Booting Alpine Linux in diskless mode...
```

### 4. Interact with Test Environment
Once QEMU boots Alpine:

```bash
# In another terminal, SSH to the VM
ssh -p 2222 root@localhost

# Inside the VM, check diskless status
df -h                    # Shows tmpfs root
mount | grep tmpfs       # Shows RAM-based filesystem
ls /etc/k3s/            # Should show k3s configuration
ps aux | grep k3s       # Check if k3s is running
```

## Test Simulation Features

### Exact Boot Process Replication
The test environment replicates the exact Raspberry Pi boot sequence:

1. **Kernel Loading**: QEMU loads Alpine kernel from ISO (simulating SD card boot)
2. **initramfs**: Alpine's initramfs initializes and mounts root as tmpfs
3. **Overlay Discovery**: Alpine automatically finds and loads .apkovl files
4. **Service Startup**: OpenRC starts services in proper order
5. **k3s Bootstrap**: Custom k3s_bootstrap script runs via local.d

### Storage Simulation
- **Boot Partition**: Simulated via QEMU ISO mount
- **Data Partition**: 4GB QCOW2 virtual disk at `/mnt/data`
- **Overlay Files**: Provided via FAT32 virtual drive
- **Persistence**: Data survives VM reboots just like real hardware

### Network Configuration
- **Host Networking**: VM can reach internet
- **SSH Access**: Port 2222 forwarded to VM's port 22
- **Service Access**: k3s services accessible from host

## Testing Scenarios

### 1. Basic Boot Test
```bash
# Test basic Alpine diskless boot
./test-alpine-diskless-boot.sh

# Verify in VM:
ssh -p 2222 root@localhost "df -h && mount | head -10"
```

### 2. k3s Cluster Test
```bash
# Test k3s installation and startup
ssh -p 2222 root@localhost "kubectl get nodes"
ssh -p 2222 root@localhost "kubectl get pods --all-namespaces"
```

### 3. Persistence Test
```bash
# Create test data
ssh -p 2222 root@localhost "echo 'test data' > /mnt/data/test.txt"

# Reboot VM (shutdown and restart test script)
# Verify persistence
ssh -p 2222 root@localhost "cat /mnt/data/test.txt"
```

### 4. Overlay Test
```bash
# Test different overlay configurations
cp builds/k3s-22.apkovl.tar.gz test/overlaydir/
./test-alpine-diskless-boot.sh
```

## Development Workflow

### 1. Configuration Development
```bash
# Edit cluster configuration
vim my-test-cluster.yaml

# Validate configuration
./validate-config.sh my-test-cluster.yaml

# Build test environment
./build-from-yaml.sh my-test-cluster.yaml
```

### 2. Script Development
```bash
# Modify scripts in scripts/ directory
vim scripts/create-apkovl-yaml.sh

# Test changes
./build-from-yaml.sh cluster-config.yaml.example
cd test && ./test-alpine-diskless-boot.sh
```

### 3. Overlay Development
```bash
# Build new overlay
./build-from-yaml.sh my-config.yaml

# Copy to test environment
cp builds/my-node.apkovl.tar.gz test/overlaydir/

# Test overlay
cd test && ./test-alpine-diskless-boot.sh
```

## Troubleshooting Test Environment

### QEMU Issues
```bash
# Check QEMU installation
qemu-system-x86_64 --version

# Verify KVM support (Linux)
kvm-ok  # Should show KVM acceleration available

# Check available memory
free -h  # Ensure at least 1GB available for VM
```

### Network Issues
```bash
# Test SSH connectivity
ssh -p 2222 -o ConnectTimeout=10 root@localhost

# Check QEMU network configuration
# In VM: ip addr show
# Host port 2222 should forward to VM port 22
```

### Storage Issues
```bash
# Verify QCOW2 disk
qemu-img info test/vm-diskless/data.qcow2

# Check overlay files
ls -la test/overlaydir/
tar -tzf test/overlaydir/*.apkovl.tar.gz | head -10
```

### Boot Issues
```bash
# Enable QEMU console output (edit test script)
# Change: -serial mon:stdio
# To: -nographic -serial mon:stdio

# Check overlay structure
tar -tzf builds/k3s-21.apkovl.tar.gz | grep -E "(k3s|local\.d)"
```

## Advanced Testing

### Custom Overlay Testing
```bash
# Test different overlay configurations
cp builds/k3s-22.apkovl.tar.gz test/overlaydir/
./test-alpine-diskless-boot.sh

# Test minimal overlay
cp builds/k3s-23.apkovl.tar.gz test/overlaydir/
./test-alpine-diskless-boot.sh
```

### Multi-Node Simulation
```bash
# Run multiple QEMU instances
./test-alpine-diskless-boot.sh &  # Master node
# Edit script for different ports/IPs
./test-alpine-diskless-boot.sh &  # Worker node 1
./test-alpine-diskless-boot.sh &  # Worker node 2
```

### Performance Testing
```bash
# Test with different RAM sizes
# Edit RAM_SIZE in test script
RAM_SIZE="256M"  # Minimal
RAM_SIZE="1G"    # Standard
RAM_SIZE="2G"    # High performance
```

## CI/CD Integration

### Automated Testing
```bash
#!/bin/bash
# ci-test.sh

# Validate configuration
./validate-config.sh cluster-config.yaml.example

# Build environment
./build-from-yaml.sh cluster-config.yaml.example

# Run headless test
cd test
timeout 300 ./test-alpine-diskless-boot.sh &
VM_PID=$!

# Wait for boot
sleep 120

# Test SSH connectivity
ssh -p 2222 -o ConnectTimeout=10 root@localhost "echo 'Test successful'"

# Cleanup
kill $VM_PID
```

### GitHub Actions Example
```yaml
name: Alpine Diskless Test
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install QEMU
        run: sudo apt install qemu-system-x86
      - name: Run tests
        run: ./ci-test.sh
```

## Platform-Specific Notes

### macOS Development
- **QEMU Installation**: Use Homebrew for easy installation
- **Performance**: Enable hardware acceleration if available
- **Network**: May require allowing QEMU through firewall
- **Storage**: Use built-in diskutil instead of Linux parted

### Linux Development
- **KVM Acceleration**: Enable for better performance
- **Permissions**: May need to add user to kvm group
- **Headless**: Works well for CI/CD environments
- **Tools**: All standard partitioning tools available

### Windows (WSL2)
- **WSL2 Required**: Use Windows Subsystem for Linux 2
- **QEMU in WSL**: Install QEMU within WSL environment
- **File Access**: Windows can access test files via WSL filesystem
- **Performance**: May be slower than native Linux

## Conclusion

The test environment provides a comprehensive way to develop and validate Alpine diskless configurations before deploying to physical Raspberry Pi hardware. It simulates the exact boot process and provides all the tools needed for development and debugging.

Key benefits:
- **Risk-Free Development**: Test changes without affecting physical hardware
- **Fast Iteration**: Quick boot times for rapid development cycles
- **Exact Simulation**: Matches real Raspberry Pi behavior precisely
- **Full Access**: Complete control over virtual environment for debugging
- **Cross-Platform**: Works on macOS, Linux, and Windows (WSL2)