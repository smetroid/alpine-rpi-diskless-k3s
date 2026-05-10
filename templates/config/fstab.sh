# Alpine diskless k3s cluster
# Data partition mounting is handled dynamically by storage-init service

# Standard pseudo-filesystems (required for clean boot)
proc            /proc           proc    defaults        0 0
sysfs           /sys            sysfs   defaults        0 0
devpts          /dev/pts        devpts  defaults        0 0
tmpfs           /tmp            tmpfs   nosuid,nodev    0 0
tmpfs           /run            tmpfs   nosuid,nodev    0 0
