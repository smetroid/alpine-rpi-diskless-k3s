#!/sbin/openrc-run
# shellcheck shell=sh
# shellcheck disable=SC2034

description="Late services - start after system is fully up"
name="late services"

depend() {
    need k3s
    after k3s
    provide late-services
}

start() {
    ebegin "Starting late services"

    # Install nfs-utils (provides NFS init scripts and binaries) and rpcbind
    # (the portmapper rpc.statd needs). Do not rely on auto-start-services for
    # rpcbind: if it is missing, rpc.statd exits with "Connection refused" and
    # every NFS-backed pod on the node fails to mount.
    einfo "Installing nfs-utils and rpcbind..."
    apk add -q nfs-utils rpcbind || ewarn "Failed to install nfs-utils/rpcbind"

    # Create required directories for NFS
    einfo "Creating NFS directories..."
    mkdir -p /var/lib/nfs/sm

    # Enable NFS services in default runlevel
    einfo "Enabling NFS services..."
    rc-update add rpcbind default >/dev/null 2>&1
    rc-update add rpc.statd default >/dev/null 2>&1
    rc-update add nfs default >/dev/null 2>&1

    # Start rpcbind first (rpc.statd registers with it)
    einfo "Starting rpcbind..."
    if ! rc-service rpcbind status >/dev/null 2>&1; then
        rc-service rpcbind start
    fi

    # Start rpc.statd (required by NFS)
    einfo "Starting rpc.statd..."
    if ! rc-service rpc.statd status >/dev/null 2>&1; then
        rc-service rpc.statd start
    fi

    # Wait for rpc.statd to be ready
    sleep 2

    # Start NFS server
    einfo "Starting NFS server..."
    if ! rc-service nfs status >/dev/null 2>&1; then
        rc-service nfs start
    fi

    eend 0
}

stop() {
    # Nothing to do on stop
    ebegin "Stopping late services"
    eend 0
}
