# macOS Setup Guide for Alpine Diskless k3s

This guide covers the specific requirements and steps for using this project on macOS.

## Prerequisites for macOS

### Required Tools

1. **Homebrew** (if not already installed):
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

2. **No additional tools required** - The setup script only creates the boot partition (FAT32), which macOS handles natively.

3. **Optional but recommended - GNU sed**:
   ```bash
   brew install gnu-sed
   # Add to PATH if needed
   echo 'export PATH="/usr/local/opt/gnu-sed/libexec/gnubin:$PATH"' >> ~/.bash_profile
   ```

### SD Card Device Names on macOS

On macOS, SD card devices are typically named differently:
- Raw device: `/dev/rdiskN` (faster)
- Buffered device: `/dev/diskN` (slower but safer)

Use `diskutil list` to identify your SD card:

```bash
diskutil list
```

Look for your SD card (usually shows as something like):
```
/dev/disk2 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:     FDisk_partition_scheme                        *32.0 GB    disk2
```

In this example, you would use `/dev/disk2`.

## Usage on macOS

### 1. Configure Your Cluster

Same as Linux - edit your `cluster-config.yaml`:

```yaml
cluster:
  name: "my-k3s-cluster"

nodes:
  - name: "k3s-master"
    ip: "192.168.1.10"
    role: "master"
  # ... etc
```

### 2. Validate Configuration

```bash
./validate-config.sh cluster-config.yaml
```

### 3. Build Configuration

```bash
./build-from-yaml.sh cluster-config.yaml
```

### 4. Setup SD Card (macOS-specific)

```bash
# Find your SD card
diskutil list

# Setup the SD card (replace diskN with your actual disk)
sudo ./setup-sd-card.sh /dev/diskN cluster-config.yaml
```

The script will automatically detect macOS and:
- Use `diskutil` instead of `parted` for partitioning
- Create only the boot partition (FAT32)
- Leave remaining space unpartitioned for Alpine to handle on first boot
- No ext4 tools required - data partition creation happens at boot time

### 5. Copy apkovl Files

```bash
# The script will show you which files to copy
# Example:
cp builds/k3s-master.apkovl.tar.gz /Volumes/BOOT/
```

## macOS-Specific Behaviors

### Partitioning
- Uses `diskutil partitionDisk` for clean, reliable partitioning
- Partition names include 's' (e.g., `disk2s1`, `disk2s2`)
- Creates MBR partition scheme compatible with Raspberry Pi

### Formatting
- Uses `diskutil partitionDisk` to create FAT32 boot partition
- No data partition formatting needed - handled automatically on first boot
- Simplified approach reduces complexity and tool requirements

### Mounting
- macOS automatically mounts FAT32 partitions
- May show volumes in Finder
- Uses temporary mount points for setup

## Troubleshooting on macOS

### "Resource busy" errors
If you get resource busy errors, unmount the disk first:
```bash
sudo diskutil unmountDisk /dev/diskN
```

### Permissions issues
Make sure to use `sudo` for disk operations:
```bash
sudo ./setup-sd-card.sh /dev/diskN cluster-config.yaml
```

### Data partition concerns
No action needed - the data partition is automatically created and formatted by Alpine Linux on first boot. This eliminates ext4 tool requirements and compatibility issues.

### Disk not found
Use `diskutil list` to find the correct device name:
```bash
diskutil list | grep external
```

### Script won't run
Make sure scripts are executable:
```bash
chmod +x *.sh lib/*.sh
```

## Alternative: Using Docker

If you prefer to avoid installing tools on macOS, you can use Docker with a Linux container:

```bash
# Run setup in Linux container
docker run -it --privileged -v $(pwd):/workspace ubuntu:20.04 bash

# Inside container:
apt update && apt install parted e2fsprogs curl
cd /workspace
./setup-sd-card.sh /dev/sdX cluster-config.yaml
```

## Notes

- The script automatically detects macOS and adjusts behavior
- All YAML configuration features work the same on macOS
- SD card preparation is the main difference between macOS and Linux
- Once the SD card is prepared, the Alpine Linux boot process is identical

## Complete macOS Workflow

```bash
# 1. No prerequisites needed (optional: install gnu-sed for better compatibility)

# 2. Configure cluster
cp cluster-config.yaml my-cluster.yaml
# Edit my-cluster.yaml with your settings

# 3. Validate and build
./validate-config.sh my-cluster.yaml
./build-from-yaml.sh my-cluster.yaml

# 4. Setup SD cards
diskutil list  # Find your SD card (e.g., /dev/disk2)
sudo ./setup-sd-card.sh /dev/disk2 my-cluster.yaml

# 5. Copy apkovl to SD card
cp builds/k3s-*.apkovl.tar.gz /Volumes/BOOT/

# 6. Eject and use SD card
diskutil eject /dev/disk2
```