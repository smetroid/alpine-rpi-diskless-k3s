# USB Drive Boot Testing for Alpine k3s Cluster

**Date:** 2025-11-09
**Status:** Design Approved
**Target:** Raspberry Pi 4 and Pi 5

## Overview

Enable comprehensive testing of the Alpine diskless k3s cluster when booting from USB drives instead of SD cards, ensuring feature parity between both storage types on Raspberry Pi hardware.

## Goals and Scope

### Objective
Validate that the entire Alpine diskless k3s cluster system works identically when booting from USB drives as it does from SD cards on Raspberry Pi 4 and Pi 5 hardware.

### Key Principles
1. **Independent validation** - Write USB boot test from scratch to discover true differences without SD card assumptions
2. **Incremental development** - Start with single-node validation, expand to multi-node once proven
3. **Experimentation-driven** - Use QEMU testing to discover optimal USB simulation parameters
4. **Same success criteria** - k3s nodes reaching Ready state validates entire bootstrap chain

### Target Hardware
- Raspberry Pi 4
- Raspberry Pi 5
- USB boot capability (no support needed for Pi 3B+)

### Test Deliverable
New script `test/test-alpine-diskless-usb-boot.sh` that validates Alpine boot, service initialization, and k3s cluster formation when running from USB storage.

## Test Script Structure

### Script Name
`test/test-alpine-diskless-usb-boot.sh`

### Initial Scope
Single-node k3s server validation

### Test Phases

1. **Environment Setup**
   - Create working directory
   - Prepare USB disk image
   - Set up QEMU parameters

2. **QEMU Discovery**
   - Experiment with different QEMU disk interface configurations
   - Find which accurately simulates USB boot
   - Options to test: `-drive if=usb`, `-drive if=scsi`, `-device usb-storage`, etc.

3. **Boot Simulation**
   - Launch QEMU VM with USB-simulated storage
   - Monitor boot process
   - Capture console output

4. **Service Validation**
   - Verify OpenRC service chain completes
   - Check: device setup → system-bootstrap → k3s-bootstrap → k3s

5. **k3s Ready Check**
   - Wait for k3s to start
   - Verify node reaches Ready state
   - Validate kubectl connectivity

6. **Cleanup**
   - Terminate QEMU
   - Optionally preserve artifacts for debugging

### Key Differences from SD Card Test

- **Device naming:** `/dev/sda` and `/dev/sda1`, `/dev/sda2` instead of `/dev/mmcblk0p1`, `/dev/mmcblk0p2`
- **QEMU interface parameters** (to be discovered experimentally)
- **Potential differences** in partition detection/mounting timing

## QEMU Configuration and Experimentation

### Experimentation Strategy

Since we don't know upfront which QEMU configuration best simulates RPi USB boot, the test script should support experimentation.

### QEMU Interface Options to Test

1. `-drive file=disk.img,format=raw,if=usb` - Direct USB simulation
2. `-drive file=disk.img,format=raw,if=scsi` - SCSI/SATA (how USB storage typically appears)
3. `-drive file=disk.img,format=raw,if=virtio` - Modern paravirtualized storage
4. `-device usb-storage,drive=...` - Explicit USB storage device attachment

### Testing Approach

- Start with USB interface, fall back to SCSI if device naming doesn't match expectations
- Monitor Alpine boot messages to see how the kernel detects the storage device
- Verify device appears as `/dev/sda` (or document if different)

### Boot Configuration

- Use same Alpine RPi image as SD card tests
- Boot partition contains Alpine kernel and apkovl overlay
- Data partition for k3s persistent storage
- Network: Start with simple user-mode networking for single-node test

## Image Preparation and Build Integration

### Build Process

The existing `build-from-yaml.sh` and `setup-sd-card.sh` already create the necessary apkovl overlays and partition structure.

### Preparation Steps

1. **Use existing build output** - Run `./build-from-yaml.sh k3s.yaml` to generate apkovl archives
2. **Create USB disk image** - Instead of writing to real hardware, create a disk image file
3. **Partition and format** - Apply same partition layout as SD cards (boot FAT32 + data ext4)
4. **Install Alpine** - Copy Alpine RPi files and apkovl overlay to boot partition
5. **Boot in QEMU** - Mount image as USB device and start simulation

### No Changes to Core Build Scripts

The beauty of this approach is that `scripts/build-from-yaml.sh` and related scripts remain unchanged. They generate the same apkovl overlays whether targeting SD or USB. Only the test harness and QEMU setup differ.

### Disk Image Creation

- Create raw disk image (e.g., 8GB)
- Use loop device or direct partitioning tools to set up partitions
- Same filesystem structure as physical SD cards

## Validation Criteria and Success Metrics

### Primary Success Criteria

#### 1. Boot Completion
- Alpine kernel loads from USB device
- Initial ramdisk mounts successfully
- System reaches multi-user runlevel

#### 2. Device Detection
- USB storage appears as `/dev/sda` (or documented alternative)
- Boot partition (`/dev/sda1`) mounts at `/media/usb` or equivalent
- Data partition (`/dev/sda2`) mounts at `/var/lib/rancher` for k3s persistence

#### 3. Service Chain Validation
- `system-bootstrap` completes (packages, timezone, SSH)
- `k3s-bootstrap` completes (k3s installation, token setup)
- `k3s` service starts successfully

#### 4. k3s Ready State (Primary Goal)
- k3s API server responds
- `kubectl get nodes` shows node in Ready state
- Node has correct role label (control-plane/master)

### Test Output

- Clear pass/fail messages for each phase
- Timing information (boot time, service startup, k3s ready time)
- Logs preserved in `test/logs/usb-boot-test-TIMESTAMP/` for debugging
- Screenshot or console output capture at key milestones

## Implementation Plan

### Phase 1: Initial USB Boot Test (Single Node)

1. Create `test/test-alpine-diskless-usb-boot.sh` from scratch
2. Implement disk image creation and partitioning
3. Experiment with QEMU USB interface configurations
4. Validate boot process and device naming
5. Test through to k3s Ready state

### Phase 2: Refinement

- Document which QEMU configuration works best
- Add detailed logging and debugging output
- Handle edge cases (boot failures, timeouts, etc.)
- Optimize boot time and test execution speed

### Phase 3: Multi-Node Expansion (Future)

- Extend to multi-node cluster testing once single-node is solid
- Test server + agent configurations
- Validate cluster networking with USB-booted nodes

## Documentation Outputs

1. **Design document** - `docs/plans/2025-11-09-usb-boot-testing-design.md` (this document)
2. **Test script** - `test/test-alpine-diskless-usb-boot.sh` (to be implemented)
3. **Testing guide** - Update `docs/TESTING.md` with USB boot testing instructions

## Future Enhancements

- Once both SD and USB tests are mature, consider extracting common test library
- Add CI/CD integration for automated testing
- Test matrix support (SD/USB × network modes × single/multi-node)

## Success Definition

This design is successful when:
- Single-node k3s cluster boots from USB-simulated storage in QEMU
- All OpenRC services complete successfully
- k3s node reaches Ready state
- Test runs reliably and provides clear pass/fail output
- Design can be extended to multi-node scenarios in the future
