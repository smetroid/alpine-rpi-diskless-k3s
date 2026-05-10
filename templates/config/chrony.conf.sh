# Use public NTP servers from pool.ntp.org
pool 2.pool.ntp.org iburst

# Record the rate at which the system clock gains/losses time
driftfile /var/lib/chrony/chrony.drift

# Allow the system clock to be stepped in the first three updates
# This is important for diskless systems that may have significant time drift on boot
makestep 1.0 3

# Enable kernel synchronization of the real-time clock (RTC)
rtcsync

# Allow NTP client access from local network
# This allows worker nodes to optionally sync from master node
allow 192.168.0.0/16
allow 10.0.0.0/8

# Serve time even if not synchronized to a time source
local stratum 10

# Log measurements and statistics
logdir /var/log/chrony
