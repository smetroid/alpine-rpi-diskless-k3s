#!/bin/bash
# Create partitioned disk template for QEMU testing
# This creates data-partitioned-template.qcow2 with pre-formatted partitions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$PROJECT_DIR/test"
VM_DIR="$TEST_DIR/vm-diskless"

echo "Creating partitioned disk template for QEMU testing..."
mkdir -p "$VM_DIR"
cd "$VM_DIR"

python3 << 'PYEOF'
import subprocess
import struct
import os

disk_size = 4 * 1024 * 1024 * 1024  # 4GB
part1_start = 204
part1_size = 524288  # 256MB boot
part2_start = part1_start + part1_size
part2_size = (disk_size // 512) - part2_start

# Create raw disk
print(f"Creating 4GB raw disk with partition table...")
with open('data-raw.img', 'wb') as f:
    f.seek(disk_size - 1)
    f.write(b'\x00')

# Write MBR with partition table
mbr = bytearray(512)
LBA_CHS = b'\xFE\xFF\xFF'

def pack_partition(status, part_type, lba, size):
    return struct.pack('<B3sB3sII', status, LBA_CHS, part_type, LBA_CHS, lba, size)

mbr[0x1BE:0x1CE] = pack_partition(0x80, 0x0C, part1_start, part1_size)  # boot, FAT32/LBA
mbr[0x1CE:0x1DE] = pack_partition(0x00, 0x83, part2_start, part2_size)  # data, Linux
mbr[0x1FE:0x200] = b'\x55\xAA'

with open('data-raw.img', 'r+b') as f:
    f.write(mbr)

print("Converting to qcow2...")
subprocess.run(['qemu-img', 'convert', '-f', 'raw', '-O', 'qcow2',
                'data-raw.img', 'data-partitioned-template.qcow2'],
               check=True, capture_output=True)

os.remove('data-raw.img')
print("✓ Template created")
PYEOF

echo ""
echo "✓ Template created: $VM_DIR/data-partitioned-template.qcow2"
echo ""
echo "Template contains:"
echo "  Partition 1: 256MB boot (FAT32/LBA, bootable)"
echo "  Partition 2: ~3.8GB data (Linux - will be formatted by Alpine on first boot)"
