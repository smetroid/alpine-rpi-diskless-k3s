#!/sbin/openrc-run
# shellcheck shell=sh
# shellcheck disable=SC2034

description="k3s worker token retrieval service"
name="k3s worker token"

depend() {
    need localmount storage-init ssh-persist net
    after localmount storage-init ssh-persist net
    before k3s
    provide k3s-worker-token
}

start() {
    # Check if this is a worker node (has server: in config)
    if ! grep -q "^server:" /etc/rancher/k3s/config.yaml 2>/dev/null; then
        einfo "Master node detected - no token retrieval needed"
        mark_service_started
        return 0
    fi

    ebegin "Retrieving k3s worker token from master"

    # Extract master URL from config
    SERVER_URL=$(grep "^server:" /etc/rancher/k3s/config.yaml | cut -d' ' -f2)

    # Extract hostname from URL - remove protocol prefix then port and path
    MASTER_HOST=$(echo "${SERVER_URL}" | sed 's|https://||' | sed 's|http://||' | cut -d: -f1 | cut -d/ -f1)

    einfo "Connecting to master: ${MASTER_HOST}"

    # Retrieve token from master via SSH with retry
    TOKEN_FILE="/etc/rancher/k3s/server-token"
    MAX_RETRIES=10
    RETRY_DELAY=10
    RETRY_COUNT=0

    while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
        einfo "Attempting to retrieve token (attempt $((RETRY_COUNT + 1))/${MAX_RETRIES})..."

        # SSH to master and get token using cluster SSH key
        if TOKEN=$(ssh -i /root/.ssh/cluster_id_rsa \
                    -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=5 \
                    root@${MASTER_HOST} \
                "cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null); then
            if [ -n "${TOKEN}" ]; then
                mkdir -p /etc/rancher/k3s
                echo "${TOKEN}" > "${TOKEN_FILE}"
                chmod 600 "${TOKEN_FILE}"
                # Add token to the existing rancher k3s config
                # Config is already at /etc/rancher/k3s/config.yaml from setup-k3s-yaml.sh
                mkdir -p /etc/rancher/k3s
                # Add token if not already present
                if ! grep -q "^token:" /etc/rancher/k3s/config.yaml 2>/dev/null; then
                    echo "token: ${TOKEN}" >> /etc/rancher/k3s/config.yaml
                fi
                eend 0 "Token retrieved successfully"
                return 0
            fi
        fi

        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; then
            einfo "Master not ready, waiting ${RETRY_DELAY}s before retry..."
            sleep ${RETRY_DELAY}
        fi
    done

    eend 1 "Failed to retrieve k3s token after ${MAX_RETRIES} attempts"
    return 1
}

stop() {
    # Nothing to do on stop
    ebegin "Stopping k3s-worker-token service"
    eend 0
}
