#!/bin/sh
# Hourly (busybox crond, /etc/periodic/hourly): keep /var/log/k3s.log under
# ~10MB. /var/log is tmpfs on these diskless nodes, so an unrotated log eats
# RAM (~15MB/day on a server). Copy-truncate is safe because supervise-daemon
# opens the log with O_APPEND. Keeps one old copy in k3s.log.1.

LOG=/var/log/k3s.log
MAX_BYTES=10485760

[ -f "$LOG" ] || exit 0
[ "$(stat -c %s "$LOG")" -gt "$MAX_BYTES" ] || exit 0

cp "$LOG" "$LOG.1" && : > "$LOG"
