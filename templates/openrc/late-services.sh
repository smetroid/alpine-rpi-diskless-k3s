#!/sbin/openrc-run

description="Late services - start after system is fully up"
name="late services"

depend() {
    need k3s
    after k3s
    provide late-services
}

start() {
    ebegin "Starting late services"

    # Install nfs-utils (provides NFS init scripts and binaries)
    einfo "Installing nfs-utils..."
    apk add -q nfs-utils

    # Create required directories for NFS
    einfo "Creating NFS directories..."
    mkdir -p /var/lib/nfs/sm

    # Enable NFS services in default runlevel
    einfo "Enabling NFS services..."
    rc-update add rpc.statd default >/dev/null 2>&1
    rc-update add nfs default >/dev/null 2>&1

    # Start rpc.statd first (required by NFS)
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
