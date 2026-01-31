# Testing vs Physical Raspberry Pi Deployment

This document explains the differences between testing the Alpine diskless k3s setup in QEMU simulation versus deploying to physical Raspberry Pi hardware.

## Overview

The testing system uses QEMU to simulate the exact boot process of a Raspberry Pi, allowing you to test your cluster configuration before deploying to physical hardware. However, there are important differences between testing and production environments.

## Architecture Comparison

### Physical Raspberry Pi Deployment
```
Raspberry Pi Hardware
├── SD Card (/dev/mmcblk0)
│   ├── Boot Partition (FAT32) - Alpine kernel + .apkovl overlay
│   └── Data Partition (ext4) - Persistent storage (auto-created)
├── ARM64 Architecture (aarch64)
├── Real Network Interface (eth0/wlan0)
├── GPIO/Hardware specific features
└── Direct hardware storage access
```

### QEMU Testing Environment
```
QEMU Virtual Machine
├── Virtual Storage (/dev/sda or /dev/vda)
│   ├── Simulated Boot - Alpine ISO boot
│   └── QCOW2 Data Disk - Persistent storage simulation
├── x86_64 Architecture (for development speed)
├── Virtual Network (NAT/Bridge)
├── Device simulation layer
└── Storage device mapping (/dev/sda → /dev/mmcblk0)
```

## Key Differences

### 1. **Hardware Architecture**
- **Physical RPi**: ARM64 (aarch64) architecture
- **Testing**: x86_64 architecture for faster development

### 2. **Storage Devices**
- **Physical RPi**: `/dev/mmcblk0` (SD card), `/dev/mmcblk0p1` (boot), `/dev/mmcblk0p2` (data)
- **Testing**: `/dev/sda` or `/dev/vda` mapped to `/dev/mmcblk0` via device simulation

### 3. **Network Configuration**
- **Physical RPi**: Static IP configuration from YAML
- **Testing**: DHCP mode for easy development, bridge mode for realistic testing

### 4. **Boot Process**
- **Physical RPi**: Real Alpine kernel boot from SD card
- **Testing**: Alpine ISO boot with overlay injection

### 5. **Service Dependencies**
- **Physical RPi**: Native hardware detection
- **Testing**: QEMU device simulation service (`qemu-device-setup`)

## Testing Modes

### Single-Node Testing
```bash
# Simple testing with automatic networking
./test/qemu-test.sh server

# Access via port forwarding:
ssh root@localhost -p 2221        # SSH access (port varies by node IP)
curl localhost:6443               # k3s API
```

**Best for:**
- Quick development iteration
- Service testing
- Configuration validation

### Multi-Node Cluster Testing
```bash
# Terminal 1: Start server
./test/qemu-test.sh server

# Terminal 2: Start first worker
./test/qemu-test.sh worker qemu-2

# Terminal 3: Start second worker
./test/qemu-test.sh worker qemu-3
```

**Best for:**
- Multi-node testing
- Network policy testing
- Load balancer testing
- Production-like scenarios

### Using Make Targets
```bash
# Show test usage
make test

# Start server
make test-server

# Start worker
make test-worker NODE=qemu-2

# Show status / stop VMs
make test-cluster-status
make test-cluster-stop
```

## What Gets Tested

### ✅ **Accurately Simulated**
- Alpine diskless boot process
- .apkovl overlay loading
- OpenRC service dependencies
- Persistent storage setup
- SSH key persistence
- k3s cluster formation
- Configuration backup/restore
- System initialization sequence

### ⚠️ **Partially Simulated**
- Hardware device detection (via qemu-device-setup service)
- Network interfaces (virtual vs physical)
- Storage device names (mapped via device nodes)

### ❌ **Not Tested**
- ARM64 specific issues
- Real hardware GPIO/peripherals
- SD card specific performance
- Hardware-specific Alpine packages
- Physical network hardware issues

## Testing Workflow

### 1. **Development Phase**
```bash
# Build configuration
make build-test

# Single-node test
./test/qemu-test.sh server
# Or: make test-qemu
```

### 2. **Multi-Node Cluster Testing**
```bash
# Terminal 1: Start server
./test/qemu-test.sh server

# Terminal 2-3: Start workers
./test/qemu-test.sh worker qemu-2
./test/qemu-test.sh worker qemu-3
```

### 3. **Physical Deployment**
```bash
# Deploy to actual hardware
make setup-sd DEVICE=/dev/sdX NODE=k3s-21
# Boot physical Raspberry Pi nodes
```

## Troubleshooting Differences

### Common Issues When Moving from Test to Physical

#### Device Detection Issues
**Problem**: `/dev/mmcblk0` not found on physical RPi
**Testing**: Simulated perfectly in QEMU
**Solution**: Check SD card detection, ensure proper Alpine aarch64 image

#### Network Configuration Issues
**Problem**: Static IP not working on physical RPi
**Testing**: DHCP worked fine in test
**Solution**: Verify network configuration, check physical network setup

#### Architecture-Specific Packages
**Problem**: x86_64 packages installed during testing
**Testing**: Works fine on x86_64 test environment
**Solution**: Ensure aarch64 packages in Alpine configuration

## Improving Test Coverage

### Test Script Features

The unified `qemu-test.sh` script supports:
1. **Single-Node Testing**: Boot just the server node
2. **Multi-Node Testing**: Boot full cluster with server + workers
3. **Socket Networking**: VM-to-VM communication for cluster testing
4. **Management Commands**: Status and stop commands for VM control

### Future Enhancements

1. **ARM64 Emulation**: Could use ARM64 QEMU for better accuracy
2. **Real Network Testing**: Bridge mode for production-like networking
3. **Storage Performance**: No SD card performance simulation
4. **Hardware Feature Testing**: No GPIO/hardware specific testing

### Suggested Improvements

#### 1. **ARM64 Testing Mode**
```bash
# Test with ARM64 emulation (slower but more accurate)
ARCH=aarch64 ./test/test-alpine-diskless-boot.sh
```

#### 3. **Automated Testing Pipeline**
```bash
# Full test suite
./test/run-test-suite.sh
├── Single node DHCP test
├── Multi-node bridge test  
├── Configuration validation
├── Service dependency test
└── Backup/restore test
```

#### 4. **Test Data Persistence**
```bash
# Test reboot scenarios
./test/test-persistence.sh
├── Boot system
├── Create test data
├── Reboot simulation
└── Verify data persistence
```

## Best Practices

### For Development
1. **Always test first**: Use QEMU testing before physical deployment
2. **Use DHCP mode**: For quick iteration and development
3. **Test configuration changes**: Validate YAML changes in simulation
4. **Check service logs**: Monitor OpenRC service startup in test environment

### For Production Validation
1. **Use bridge mode**: Test realistic networking scenarios
2. **Test multi-node**: Simulate actual cluster scenarios
3. **Validate persistence**: Test reboot scenarios thoroughly
4. **Check performance**: Understand test vs production performance differences

### Migration Checklist
- [ ] Configuration tested and validated in QEMU
- [ ] Multi-node networking tested (bridge mode)
- [ ] SSH key persistence verified
- [ ] Service dependencies working correctly
- [ ] Backup/restore functionality tested
- [ ] k3s cluster formation successful
- [ ] Load balancer and ingress tested
- [ ] Ready for physical deployment

## Conclusion

The QEMU testing environment provides excellent coverage for configuration validation and service testing, but physical deployment may reveal hardware-specific issues. Use testing for rapid development iteration, but always validate on physical hardware before production use.

The testing system is designed to catch 90% of issues before you touch physical hardware, saving time and reducing the risk of SD card corruption or hardware issues during development.

## USB Boot Testing

Test Alpine diskless k3s cluster booting from USB drives (Pi 4/5).

### Quick Start

```bash
# Build cluster configuration first
./build-from-yaml.sh k3s.yaml

# Run USB boot test
./test/test-alpine-diskless-usb-boot.sh
```

### Test Configuration

The USB boot test supports multiple QEMU storage interfaces:

- **SCSI** (default): Most accurate simulation of USB storage behavior
- **USB**: Direct USB device emulation
- **virtio**: High-performance paravirtualized storage

```bash
# Test with different interfaces
USB_INTERFACE=scsi ./test/test-alpine-diskless-usb-boot.sh
USB_INTERFACE=usb ./test/test-alpine-diskless-usb-boot.sh
USB_INTERFACE=virtio ./test/test-alpine-diskless-usb-boot.sh
```

### Success Criteria

1. Alpine boots from USB device
2. USB storage detected as `/dev/sda` (or documented alternative)
3. System bootstrap completes (packages, SSH, timezone)
4. k3s bootstrap completes (installation, cluster init)
5. k3s node reaches Ready state

### Validation Commands

Inside the QEMU VM:

```bash
# Check USB device
ls -la /dev/sd*
dmesg | grep -i usb

# Verify services
rc-status
rc-service usb-device-setup status

# Check k3s
kubectl get nodes
kubectl get pods -A
```

### Comparing SD vs USB Boot

Both test scripts should produce identical results:

```bash
# SD card boot test
./test/test-alpine-diskless-boot.sh

# USB boot test
./test/test-alpine-diskless-usb-boot.sh
```

Differences:
- Device naming: `/dev/mmcblk0` vs `/dev/sda`
- QEMU interface: SD simulation vs USB/SCSI simulation
- Service: `qemu-device-setup` vs `usb-device-setup`