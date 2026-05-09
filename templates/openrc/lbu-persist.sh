#!/sbin/openrc-run

description="Commit LBU changes on shutdown/reboot"
name="lbu persist"

depend() {
    need storage-init
    after storage-init system-bootstrap
    provide lbu-persist
}

start() {
    # Nothing to do on start - system-bootstrap handles initial LBU setup
    ebegin "LBU persistence service started"
    eend 0
}

stop() {
    ebegin "Committing LBU changes before shutdown"

    # Save any runtime changes made during this session
    if [ -d /mnt/data ] && mountpoint -q /mnt/data; then
        # Use the custom lbu-commit-runtime created by system-bootstrap
        if [ -x /usr/local/bin/lbu-commit-runtime ]; then
            /usr/local/bin/lbu-commit-runtime
            if [ $? -eq 0 ]; then
                einfo "Runtime changes committed"
            else
                ewarn "LBU commit failed"
            fi
        else
            # Fallback to standard lbu commit
            if lbu commit -d 2>/dev/null; then
                einfo "Changes saved to persistent storage"
            else
                ewarn "LBU commit failed"
            fi
        fi
    else
        ewarn "Persistent storage not available, changes will be lost"
    fi

    eend 0
}
