# Unified QEMU Test Script Design

**Date:** 2026-01-31
**Status:** Design Phase

## Overview

Combine `test-qemu.sh` and `test-multinode.sh` into a single unified `qemu-test.sh` script that handles both single-node and multi-node cluster testing. The script uses socket networking consistently and relies on `qemu.yaml` configuration which already contains the correct test IPs (10.99.0.x).

## Goals

1. **Simplify maintenance** - One script instead of two with duplicate code
2. **Consistent networking** - Socket networking for all VMs
3. **Easier user experience** - Single command interface for all test scenarios
4. **Simpler documentation** - One testing approach to document

## Architecture

```
qemu-test.sh
├── setup_environment()       # Download ISO, extract kernel/initramfs
├── create_qemu_device_service()  # Add to overlay (shared function)
├── prepare_overlay()         # Extract, add qemu-device-setup, repack
│   └── No IP/hostname changes - already correct from build!
├── create_data_disk()        # Per-node data disk creation
├── start_vm()                # Launch QEMU with socket networking
│   ├── server: listens on socket port
│   └── worker: connects to server socket
├── show_status()             # List running VMs
└── stop_vm()                 # Stop VM(s)
```

### Key Design Decisions

1. **No IP conversion** - The `qemu.yaml` config already has correct test IPs (10.99.0.x)
2. **Minimal overlay modification** - Only add `qemu-device-setup` service
3. **Socket networking default** - VMs communicate via QEMU socket networking
4. **Dual NIC configuration**:
   - `eth0`: Cluster network (static IP, VM-to-VM via socket)
   - `eth1`: Host access (DHCP via QEMU user mode, port forwarding for SSH)

## Command Interface

```
Usage: qemu-test.sh <command> [options]

Commands:
  server                    Boot the master node from config
  worker <node-name>        Boot a specific worker node
  status                    Show running VMs
  stop [node-name|all]      Stop VM(s)

Environment Variables:
  CONFIG_FILE    YAML config (default: qemu.yaml)
  RAM_SIZE       VM RAM (default: 4096M)
  NETWORK_MODE   Networking mode (default: socket)
                  socket: VM-to-VM via socket networking
                  dhcp:    Single VM with user networking
                  bridge:  Single VM with bridge networking

Examples:
  # Single-node test (just the server)
  ./qemu-test.sh server

  # Multi-node cluster - 3 terminals
  ./qemu-test.sh server           # Terminal 1
  ./qemu-test.sh worker qemu-2    # Terminal 2
  ./qemu-test.sh worker qemu-3    # Terminal 3

  # Check status and cleanup
  ./qemu-test.sh status
  ./qemu-test.sh stop all
```

### Command Behavior

| Command | Validation | Action |
|---------|-----------|--------|
| `server` | At least one master node in config | Boot first master node |
| `worker <name>` | Node exists and role != master | Boot specified worker |
| `status` | None | List running VMs via pgrep |
| `stop [target]` | If node specified, check it exists | Kill VM(s) |

## Networking

### Socket Networking (Default)

```bash
# Server mode (listens for connections)
-netdev socket,id=cluster,listen=:1234

# Worker mode (connects to server)
-netdev socket,id=cluster,connect=127.0.0.1:1234

# Both get second NIC for host access
-netdev user,id=hostnet,hostfwd=tcp::<ssh_port>-:22
```

### Port Forwarding Logic

```bash
# SSH port based on last octet of node IP
# 10.99.0.21 → port 2221
# 10.99.0.22 → port 2222

# API port forwarding only for master
# hostfwd=tcp::6443-:6443
```

### Alternative Modes (Optional)

- **DHCP mode**: Single VM with QEMU user networking (simpler, no bridge needed)
- **Bridge mode**: Single VM with host bridge (requires pre-configured bridge)

## Directory Structure

```
test/
├── qemu-test.sh          # New unified script
├── test-qemu.sh          # DELETE - merged into qemu-test.sh
├── test-multinode.sh     # DELETE - merged into qemu-test.sh
├── qemu-cluster/         # Created at runtime
│   ├── alpine-virt-*.iso
│   ├── vmlinuz-virt
│   ├── initramfs-virt
│   ├── <node>-data.qcow2
│   └── overlays/
│       └── <node>/
│           └── <node>.apkovl.tar.gz
└── vm-diskless/          # Legacy, can be removed
```

## File Changes

### Files to Create
- `test/qemu-test.sh` - New unified test script

### Files to Delete
- `test/test-qemu.sh`
- `test/test-multinode.sh`

### Files to Modify

#### Makefile

```makefile
# Remove old targets:
# - test-qemu
# - test-multinode

# Add new unified target:
.PHONY: test qemu-test
qemu-test: test/qemu-test.sh
	@echo "QEMU test script ready"
	@echo "  ./test/qemu-test.sh server      # Boot master node"
	@echo "  ./test/qemu-test.sh worker <n>  # Boot worker node"
	@echo "  ./test/qemu-test.sh status      # Show running VMs"
	@echo "  ./test/qemu-test.sh stop [all]  # Stop VM(s)"

test: qemu-test
```

#### README.md / TESTING.md

Replace separate test-qemu and test-multinode sections with:

```markdown
## QEMU Testing

The unified `qemu-test.sh` script handles both single-node and multi-node testing.

### Single-node Test
```bash
./test/qemu-test.sh server
```
Access via: `ssh root@localhost -p 2221`

### Multi-node Cluster Test
```bash
# Terminal 1: Start server
./test/qemu-test.sh server

# Terminal 2: Start first worker
./test/qemu-test.sh worker qemu-2

# Terminal 3: Start second worker
./test/qemu-test.sh worker qemu-3
```

### Management Commands
```bash
./test/qemu-test.sh status      # Show running VMs
./test/qemu-test.sh stop all    # Stop all VMs
./test/qemu-test.sh stop qemu-2 # Stop specific VM
```
```

## Error Handling

### Pre-flight Checks
- Config file exists and is readable
- Build directory has overlays for nodes in config
- `qemu-system-x86_64` is available
- Kernel/initramfs extracted or can be extracted

### Error Scenarios

| Scenario | Action |
|----------|--------|
| Config file not found | Error with hint to check path |
| Overlay missing for node | Error with `make build` hint |
| qemu-system not installed | Error with install instructions |
| Kernel extraction fails | Try bsdtar → 7z → mount, error if all fail |
| Worker node not found | List available workers from config |
| Trying to worker start a master | Error directing to use `server` command |

### Graceful Degradation
- Socket port in use → Warn but attempt to use it
- Data disk exists → Reuse existing disk
- Overlay directory exists → Clean and recreate

## Testing Strategy

### Validation Checklist

- [ ] Single-node boot (`qemu-test.sh server`)
  - Server starts successfully
  - k3s initializes and becomes ready
  - SSH accessible on forwarded port
  - Can run `kubectl get nodes` inside VM

- [ ] Multi-node cluster (server + workers)
  - Server starts first
  - Workers successfully join cluster
  - All nodes appear in `kubectl get nodes`
  - Inter-node communication works

- [ ] Error handling
  - Missing overlay shows helpful error
  - Invalid worker name lists available workers
  - Status shows correct running VMs
  - Stop all kills all VMs

- [ ] Documentation
  - Makefile targets work
  - README documentation is clear
  - Help text is accurate

## Implementation Notes

### Code Reuse Strategy

**From test-qemu.sh:**
- `setup_environment()` - ISO download, kernel extraction
- `create_qemu_device_service()` - exact same function
- `prepare_overlay()` - extract/add service/repack logic (simplified)
- Config file → build directory mapping logic

**From test-multinode.sh:**
- Subcommand structure (server/worker/status/stop)
- Socket networking configuration
- Multiple data disk management
- `show_status()` and `stop_vm()` functions
- YAML node queries (get_master_node, get_node_role, etc.)

### Kernel Command Line

Consistent across all VMs, includes cgroups for k3s:

```bash
modules=loop,squashfs,sd-mod,usb-storage quiet console=ttyS0,115200 \
cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset
```

## Future Considerations

- Add `--nodes` flag to boot all nodes at once (requires multi-terminal or backgrounding)
- Add `--dry-run` flag to show what would be done without executing
- Consider adding support for other VM types (parallels, vmware) if needed
