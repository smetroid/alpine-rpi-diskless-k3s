#!/bin/bash

# Wipe a worker node's containerd image/snapshot cache and restart k3s.
#
# Use when a node runs a corrupted unpacked image layer (e.g. a pod crash-loops
# with "exec format error" although the image is the right architecture, and
# deleting/re-pulling the image does not help because containerd reuses the
# existing broken snapshot). See docs/TROUBLESHOOTING.md.
#
# What it does on the node: stops k3s, kills all container processes, unmounts
# container/kubelet mounts, deletes ONLY /var/lib/rancher/k3s/agent/containerd,
# then starts k3s again. Images re-pull on start. Node identity, PVC data and
# config are untouched. Every pod on the node restarts in place (typically a
# few minutes of downtime for them), so run it in a maintenance window.
#
# Usage: ./scripts/wipe-containerd-cache.sh <node-name> [config-file] [--yes]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(cd "$SCRIPT_DIR/../lib" && pwd)}"

ASSUME_YES=false
ARGS=()
for a in "$@"; do
    case "$a" in
        --yes|-y) ASSUME_YES=true ;;
        *) ARGS+=("$a") ;;
    esac
done

NODE="${ARGS[0]:-}"
if [ -z "$NODE" ]; then
    echo "Usage: $0 <node-name> [config-file] [--yes]" >&2
    exit 1
fi

CONFIG_FILE="${CONFIG_FILE:-${ARGS[1]:-k3s.yaml}}"

if [ -f "$LIB_DIR/logging.sh" ]; then
    . "$LIB_DIR/logging.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[SUCCESS] $*"; }
fi

source "$LIB_DIR/yaml-parser.sh"

# Resolve node IP and role from the config
NODE_IP=""
NODE_ROLE=""
while IFS=':' read -r name ip role; do
    if [ "$name" = "$NODE" ]; then
        NODE_IP="$ip"
        NODE_ROLE="$role"
    fi
done < <(yaml_get_nodes)

if [ -z "$NODE_IP" ]; then
    log_error "Node '$NODE' not found in $CONFIG_FILE"
    exit 1
fi

# A master runs the control plane; stopping k3s there takes the API down.
if [ "$NODE_ROLE" != "worker" ]; then
    log_error "'$NODE' has role '$NODE_ROLE'. This script only supports workers."
    exit 1
fi

# Cluster SSH key (same resolution as create-apkovl-yaml.sh)
CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
CLUSTER_KEY=$(yaml_get "cluster.ssh_key" 2>/dev/null || true)
if [ -z "$CLUSTER_KEY" ]; then
    CLUSTER_KEY="$CONFIG_DIR/.cluster_ssh_keys/$(yaml_get "cluster.name")/cluster_id_rsa"
fi
CLUSTER_KEY="${CLUSTER_KEY/#\~/$HOME}"
case "$CLUSTER_KEY" in
    /*) ;;
    *) CLUSTER_KEY="$CONFIG_DIR/$CLUSTER_KEY" ;;
esac
[ -f "$CLUSTER_KEY" ] || { log_error "Cluster SSH key not found: $CLUSTER_KEY"; exit 1; }

SSH=(ssh -i "$CLUSTER_KEY" -o ConnectTimeout=8 -o BatchMode=yes "root@$NODE_IP")

"${SSH[@]}" true 2>/dev/null || { log_error "Cannot SSH to $NODE ($NODE_IP)"; exit 1; }

log_info "Node: $NODE ($NODE_IP)"
if command -v kubectl >/dev/null 2>&1; then
    PODS=$(kubectl get pods -A --field-selector "spec.nodeName=$NODE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log_info "Pods currently on $NODE: ${PODS:-unknown} (all will restart)"
fi

if [ "$ASSUME_YES" != true ]; then
    printf "Wipe containerd cache on %s and restart k3s? [y/N] " "$NODE"
    read -r reply
    case "$reply" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
fi

# The node has no scp/sftp, so ship the script over ssh stdin and run it detached
# so a dropped session cannot leave the node half wiped.
"${SSH[@]}" 'cat > /tmp/wipe-containerd.sh && chmod +x /tmp/wipe-containerd.sh' <<'REMOTE'
#!/bin/sh
D=/var/lib/rancher/k3s/agent/containerd
[ -d "$D" ] || { echo "ABORT: $D missing"; exit 1; }
echo "[$(date +%T)] stopping k3s"
rc-service k3s stop 2>&1 | tail -2
sleep 3
echo "[$(date +%T)] killing container processes and shims"
for shim in $(pgrep -f containerd-shim); do
  for c in $(pgrep -P "$shim"); do kill -9 "$c" 2>/dev/null; done
done
sleep 1
pkill -9 -f containerd-shim 2>/dev/null
pkill -9 -f "k3s server|k3s agent|k3s-agent" 2>/dev/null
sleep 2
echo "[$(date +%T)] unmounting"
for pass in 1 2 3; do
  awk '{print $2}' /proc/mounts | grep -E "^(/run/k3s|/var/lib/kubelet|$D)" | sort -r | while read -r m; do umount -l "$m" 2>/dev/null; done
done
left=$(awk '{print $2}' /proc/mounts | grep -cE "^(/run/k3s|/var/lib/kubelet|$D)")
echo "remaining mounts: $left"
echo "[$(date +%T)] deleting $D ($(du -sh "$D" 2>/dev/null | cut -f1))"
rm -rf "$D"
rm -rf /run/k3s/containerd
echo "exists after: $([ -e "$D" ] && echo yes || echo no)"
echo "[$(date +%T)] starting k3s"
rc-service k3s start 2>&1 | tail -2
echo "[$(date +%T)] done"
REMOTE

"${SSH[@]}" 'rm -f /tmp/wipe.log; nohup /tmp/wipe-containerd.sh > /tmp/wipe.log 2>&1 < /dev/null &'
log_info "Wipe started on $NODE; following progress..."

# Follow the log until the remote script reports completion (k3s restarts, so
# SSH to the node itself stays available throughout).
shown=0
for _ in $(seq 1 60); do
    LOG=$("${SSH[@]}" 'cat /tmp/wipe.log' 2>/dev/null || true)
    total=$(printf '%s\n' "$LOG" | grep -c . || true)
    if [ "$total" -gt "$shown" ]; then
        printf '%s\n' "$LOG" | tail -n +"$((shown + 1))"
        shown=$total
    fi
    case "$LOG" in
        *ABORT*) log_error "Remote script aborted"; exit 1 ;;
        *"] done"*) break ;;
    esac
    sleep 3
done

case "$LOG" in
    *"] done"*) ;;
    *) log_error "Timed out waiting for the wipe to finish; check /tmp/wipe.log on $NODE"; exit 1 ;;
esac

log_success "containerd cache wiped on $NODE. Images are re-pulling."
log_info "Watch it recover: kubectl get pods -A --field-selector spec.nodeName=$NODE"
log_info "Brief 'pull QPS exceeded' errors while many images re-pull are normal."
