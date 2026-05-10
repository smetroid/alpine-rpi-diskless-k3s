#!/sbin/openrc-run
# shellcheck shell=sh
# shellcheck disable=SC2034

description="Persistent SSH setup service"
name="ssh persist"

depend() {
    need storage-init net
    after storage-init net
    before system-bootstrap
    provide ssh-persist
}

start() {
    ebegin "Setting up persistent SSH"

    # Persistent storage location for SSH
    SSH_PERSIST_DIR="/mnt/data/ssh"

    # Wait for storage to be ready
    if [ ! -d /mnt/data ] || ! mountpoint -q /mnt/data 2>/dev/null; then
        ewarn "Persistent storage not available, SSH may not persist across reboots"
    else
        mkdir -p "$SSH_PERSIST_DIR"
    fi

    # Install openssh packages (always check for ssh-keygen as it's required for key generation)
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        einfo "Installing OpenSSH packages..."
        apk update >/dev/null 2>&1
        if apk add openssh openssh-server openssh-keygen; then
            einfo "OpenSSH installed successfully"
        else
            eerror "Failed to install OpenSSH"
            eend 1 "OpenSSH installation failed"
            return 1
        fi
    fi

    # Restore or generate SSH host keys
    if [ -d "$SSH_PERSIST_DIR" ] && [ -f "$SSH_PERSIST_DIR/ssh_host_ed25519_key" ]; then
        einfo "Restoring SSH host keys from persistent storage..."
        cp -a "$SSH_PERSIST_DIR"/ssh_host_*_key* /etc/ssh/ 2>/dev/null
        chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null
        chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null
    else
        einfo "Generating new SSH host keys..."
        rm -f /etc/ssh/ssh_host_*_key*
        ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N "" -q
        ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key -N "" -q
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q

        # Save to persistent storage
        if [ -d "$SSH_PERSIST_DIR" ]; then
            einfo "Saving SSH host keys to persistent storage..."
            cp -a /etc/ssh/ssh_host_*_key* "$SSH_PERSIST_DIR/" 2>/dev/null
        fi
    fi

    # Restore authorized_keys from persistent storage if available
    if [ -d "$SSH_PERSIST_DIR" ] && [ -f "$SSH_PERSIST_DIR/authorized_keys" ]; then
        einfo "Restoring authorized_keys from persistent storage..."
        mkdir -p /root/.ssh
        cp -a "$SSH_PERSIST_DIR/authorized_keys" /root/.ssh/authorized_keys
    fi

    # Ensure /root and .ssh have correct ownership and permissions
    # (apkovl files may have wrong ownership from build host)
    chown root:root /root
    chmod 700 /root

    if [ -f /root/.ssh/authorized_keys ]; then
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
        chown -R root:root /root/.ssh

        # Save to persistent storage if not already there
        if [ -d "$SSH_PERSIST_DIR" ] && [ ! -f "$SSH_PERSIST_DIR/authorized_keys" ]; then
            cp -a /root/.ssh/authorized_keys "$SSH_PERSIST_DIR/authorized_keys"
        fi
    fi

    # Ensure sshd_config has correct permissions
    chmod 644 /etc/ssh/sshd_config 2>/dev/null

    # Create /var/empty directory for sshd privilege separation
    # This is required by sshd but may not exist or have wrong permissions in diskless environment
    if [ ! -d /var/empty ]; then
        einfo "Creating /var/empty for sshd privilege separation..."
        mkdir -p /var/empty
    fi
    # Always fix ownership and permissions (directory may exist with wrong perms from base system)
    einfo "Fixing /var/empty ownership and permissions..."
    chown root:root /var/empty 2>/dev/null
    chmod 755 /var/empty 2>/dev/null

    # Enable and start sshd
    if ! rc-service sshd status >/dev/null 2>&1; then
        einfo "Starting SSH service..."
        rc-update add sshd default 2>/dev/null
        rc-service sshd start
    else
        einfo "SSH service already running"
    fi

    eend 0 "SSH setup complete"
}

stop() {
    ebegin "Stopping ssh-persist service"
    # Nothing to do - sshd has its own stop
    eend 0
}
