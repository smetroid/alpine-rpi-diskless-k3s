# HA Home Gateway: OpenWrt on a Dedicated k3s Cluster

## Project Summary

Build a highly available home network gateway using **2 Raspberry Pi nodes** running a
**dedicated k3s cluster**. OpenWrt runs as a **DaemonSet** (one pod per node), giving you:

- **k3s** handles pod-level failures — if the OpenWrt pod crashes, it restarts automatically
- **VRRP (keepalived)** handles node-level failures — if a whole RPi goes down, the VIP
  floats to the surviving node in ~2 seconds
- **Alpine Linux** as the node OS — lightweight, mainline kernel, solid USB NIC support

This is a **dedicated** cluster. Its only job is the gateway. There is no chicken-and-egg
problem with cluster networking because the cluster network and the gateway network are the
same thing — and no other workloads depend on it.

> **Build base:** an existing repo already provides Alpine + k3s + RPi provisioning —
> `https://github.com/smetroid/diskless-alpine-k3s-rpi`. Roughly 70–80% of the node
> provisioning work is already done there. See **"Adapting the Existing Repo"** below for
> the concrete gap list and task breakdown. Sections 2–5 of the Step-by-Step content in
> this document describe the *target state*; the repo is how you get there.

---

## Architecture

```
          ISP Modem/Router
                 │
       ┌─────────┴──────────┐
       │     eth1 (WAN)      │  ← USB NIC on each RPi (RTL8153 chipset)
       │                     │
  ┌────▼────────┐   ┌────────▼────┐
  │  RPi-GW1    │   │  RPi-GW2    │
  │ Alpine Linux│   │ Alpine Linux│
  │ k3s primary │   │ k3s agent   │
  │ VRRP prio   │   │ VRRP prio   │
  │    200      │   │    100      │
  │ [openwrt    │   │ [openwrt    │
  │  pod]       │   │  pod]       │
  └────┬────────┘   └────────┬────┘
       │    VRRP / VIP       │
       └──────────┬──────────┘
                  │  192.168.1.1  ← Virtual IP — all devices point here
       ┌──────────▼──────────────────┐
       │         LAN switch           │
       │   eth0 (built-in) each RPi   │
       ├─────────────────────────────┤
       │  All home devices            │
       │  Any other k3s clusters      │
       └─────────────────────────────┘
```

### Failure modes covered

| Failure | Recovery | Time |
|---|---|---|
| OpenWrt pod crashes on GW1 | k3s restarts pod on GW1 | ~5s |
| Entire GW1 node goes down | VRRP promotes GW2, claims VIP | ~2s |
| GW1 comes back online | VRRP returns VIP to GW1 (higher priority) | ~2s |
| Both nodes up, pod healthy | Normal operation via VIP | — |

---

## Hardware Requirements

- 2x Raspberry Pi 4 or 5 (4GB+ RAM recommended)
- 2x USB 3.0 Gigabit NIC — **Realtek RTL8153 chipset** (see NIC section below)
- 2x MicroSD card (32GB+) or USB SSD for reliability
- 1x LAN switch (unmanaged is fine)
- Access to ISP modem/router

### Why Two NICs

OpenWrt requires WAN and LAN to be on separate interfaces for zone-based firewall rules
to work correctly. With `hostNetwork: true`, the pod owns the host's NICs directly.

```
eth0  — built-in RPi NIC  → LAN (home devices, cluster traffic)
eth1  — USB NIC dongle    → WAN (ISP modem)
```

### NIC Chipset Choice — RTL8153 over ASIX AX88179

| Chipset | Alpine Linux | Ubuntu/RPi OS | Notes |
|---|---|---|---|
| **Realtek RTL8153** | ✅ Solid | ⚠️ Some kernel versions flaky | Driver: `r8152` — in mainline kernel |
| ASIX AX88179 | ✅ Good | ⚠️ Boot init issues on some distros | Driver: `ax88179_178a` |

On Alpine with a mainline kernel both work well. RTL8153 is the safer pick — more widely
tested and the `r8152` driver is actively maintained upstream.

**Known USB NIC issue on Ubuntu/RPi OS:** certain RPi kernel patch versions cause RTL8153
adapters to freeze the system on interface access. This is a RPi-patched kernel issue, not
a Linux issue. Alpine uses a mainline kernel and does not have this problem.

**Fix if you hit TX issues on any distro:**
```bash
ethtool -K eth1 tx off
```

**Pin interface name via udev to prevent rename on reboot:**
```bash
# /etc/udev/rules.d/10-usb-nic.rules
SUBSYSTEM=="net", DRIVERS=="r8152", NAME="eth-wan"
```

---

## Node OS: Alpine Linux

Alpine is the recommended OS for this dedicated gateway cluster.

| | Alpine Linux | Ubuntu 24.04 |
|---|---|---|
| **Footprint** | ~130MB | ~2GB |
| **Kernel** | Mainline | RPi-patched (can cause USB NIC issues) |
| **USB NIC stability** | ✅ Solid | ⚠️ Kernel-version dependent |
| **k3s support** | ✅ Supported | ✅ Supported |
| **Boot time** | Very fast | Moderate |
| **Fit for dedicated appliance** | ✅ Ideal | Overkill |

### Install Alpine on RPi

Download the Alpine Linux aarch64 Raspberry Pi image:
```
https://alpinelinux.org/downloads/  → Raspberry Pi → aarch64
```

Flash to SD card:
```bash
dd if=alpine-rpi-*.img of=/dev/sdX bs=4M status=progress
sync
```

Boot and run setup:
```bash
setup-alpine
# Set hostname: rpi-gw1 (or rpi-gw2)
# Set static IP on eth0 (LAN)
# Enable sshd
# Install to disk when prompted
```

Enable community repo and install prerequisites:
```bash
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community" \
  >> /etc/apk/repositories
apk update
apk add curl bash cni-plugins nftables keepalived
```

Enable IP forwarding permanently:
```bash
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p
```

---

## k3s Cluster Setup

### Node IPs (example — adjust to your subnet)

| Node | LAN IP (eth0) | WAN IP (eth1) | Role |
|---|---|---|---|
| RPi-GW1 | 192.168.1.2 | DHCP from ISP | k3s server (control plane) |
| RPi-GW2 | 192.168.1.3 | DHCP from ISP | k3s agent (worker) |
| VIP | 192.168.1.1 | — | Floats between nodes via VRRP |

### Install k3s on GW1 (server node)

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --node-ip 192.168.1.2 \
  --advertise-address 192.168.1.2 \
  --flannel-iface eth0 \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644
```

Get the join token:
```bash
cat /var/lib/rancher/k3s/server/node-token
```

### Install k3s on GW2 (agent node)

```bash
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://192.168.1.2:6443 \
  --token <token-from-gw1> \
  --node-ip 192.168.1.3 \
  --flannel-iface eth0
```

Verify both nodes are ready (from GW1):
```bash
kubectl get nodes
# NAME       STATUS   ROLES                  AGE
# rpi-gw1    Ready    control-plane,master   2m
# rpi-gw2    Ready    <none>                 1m
```

Label nodes for scheduling awareness:
```bash
kubectl label node rpi-gw1 role=gateway
kubectl label node rpi-gw2 role=gateway
```

---

## OpenWrt DaemonSet

A DaemonSet runs exactly one pod per node automatically. If the pod crashes, k3s restarts
it. If a new node joins, k3s schedules a pod on it.

### OpenWrt container image

Pinned image for this build:

```bash
docker pull albrechtloh/openwrt-docker:openwrt-25.12.5-2bca120
```

The OpenWrt project publishes no official Docker images, so this is a community build.
Before committing to it, verify it ships an arm64 manifest:

```bash
docker manifest inspect albrechtloh/openwrt-docker:openwrt-25.12.5-2bca120
```

If arm64 is missing, fall back to building from OpenWrt ImageBuilder for aarch64:
`https://openwrt.org/docs/guide-user/additional-software/imagebuilder`

### DaemonSet manifest

`gateway-daemonset.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gateway
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: openwrt-gateway
  namespace: gateway
spec:
  selector:
    matchLabels:
      app: openwrt
  template:
    metadata:
      labels:
        app: openwrt
    spec:
      hostNetwork: true          # pod owns host NICs directly
      hostPID: true
      tolerations:
        - operator: Exists       # run on all nodes including control-plane
      nodeSelector:
        role: gateway            # only on labeled gateway nodes
      containers:
      - name: openwrt
        image: albrechtloh/openwrt-docker:openwrt-25.12.5-2bca120
        securityContext:
          privileged: true       # required for NET_ADMIN, nftables, routing
        volumeMounts:
        - name: openwrt-config
          mountPath: /etc/config
        - name: openwrt-overlay
          mountPath: /overlay
        resources:
          requests:
            memory: "128Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "1000m"
      volumes:
      - name: openwrt-config
        hostPath:
          path: /etc/openwrt/config    # config lives on the node, persists pod restarts
          type: DirectoryOrCreate
      - name: openwrt-overlay
        hostPath:
          path: /etc/openwrt/overlay
          type: DirectoryOrCreate
```

Deploy:
```bash
kubectl apply -f gateway-daemonset.yaml

# Verify pods are running on both nodes
kubectl get pods -n gateway -o wide
# NAME                    READY   STATUS    NODE
# openwrt-gateway-xxxxx   1/1     Running   rpi-gw1
# openwrt-gateway-yyyyy   1/1     Running   rpi-gw2
```

### Config persistence

Because config is mounted from `hostPath`, OpenWrt config survives pod restarts.
Keep `/etc/openwrt/` in sync between nodes (see Config Sync section below).

---

## VRRP Failover with Keepalived

Keepalived runs on the **host** (not inside the pod) so it can monitor node health
independently of the OpenWrt pod. Install and configure on both RPis:

### GW1 — `/etc/keepalived/keepalived.conf`

```
global_defs {
    router_id RPi-GW1
}

vrrp_script chk_openwrt {
    script "kubectl get pod -n gateway -o wide 2>/dev/null | grep rpi-gw1 | grep Running"
    interval 5
    weight -50
    fall 2
    rise 2
}

vrrp_instance GATEWAY {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 200
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass changeme123
    }

    virtual_ipaddress {
        192.168.1.1/24 dev eth0
    }

    track_script {
        chk_openwrt
    }

    notify_master "/etc/keepalived/become-master.sh"
    notify_backup "/etc/keepalived/become-backup.sh"
    notify_fault  "/etc/keepalived/become-backup.sh"
}
```

### GW2 — same file, two changes:
```
    router_id RPi-GW2
    state BACKUP
    priority 100
    # update chk_openwrt script: grep rpi-gw2 instead of rpi-gw1
```

### Notify scripts (both nodes)

`/etc/keepalived/become-master.sh`:
```bash
#!/bin/sh
# Node is now active — ensure WAN interface is up
ip link set eth1 up
logger "VRRP: became MASTER — gateway active"
```

`/etc/keepalived/become-backup.sh`:
```bash
#!/bin/sh
logger "VRRP: became BACKUP — standby mode"
```

```bash
chmod +x /etc/keepalived/become-master.sh /etc/keepalived/become-backup.sh

# Alpine uses OpenRC
rc-update add keepalived default
rc-service keepalived start
```

Verify VIP is on GW1:
```bash
ip addr show eth0 | grep 192.168.1.1
```

---

## OpenWrt Configuration (inside the pod)

Once the pod is running, exec in and configure OpenWrt:

```bash
kubectl exec -it -n gateway daemonset/openwrt-gateway -- /bin/ash
```

### Network interfaces (`/etc/config/network`):

```
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config interface 'lan'
    option device 'eth0'
    option proto 'static'
    option ipaddr '192.168.1.2'    # node IP — NOT the VIP
    option netmask '255.255.255.0'

config interface 'wan'
    option device 'eth1'
    option proto 'dhcp'            # or 'static' if ISP gives fixed IP
```

> The VIP (192.168.1.1) is managed by keepalived on the host, not by OpenWrt.
> OpenWrt uses the node's physical IP. Devices reach OpenWrt via the VIP which
> keepalived assigns to eth0 on whichever node is master.

### Firewall zones (`/etc/config/firewall`):

```
config defaults
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'DROP'
    option synflood_protect '1'

config zone
    option name 'lan'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'
    list network 'lan'

config zone
    option name 'wan'
    option input 'DROP'
    option output 'ACCEPT'
    option forward 'DROP'
    option masq '1'
    option mtu_fix '1'
    list network 'wan'

config forwarding
    option src 'lan'
    option dest 'wan'
```

### DHCP (`/etc/config/dhcp`):

```
config dnsmasq
    option domainneeded '1'
    option boguspriv '1'
    option filterwin2k '0'
    option localise_queries '1'
    option local '/home.lab/'
    option domain 'home.lab'
    option expandhosts '1'
    option authoritative '1'
    list server '1.1.1.1'
    list server '8.8.8.8'

config dhcp 'lan'
    option interface 'lan'
    option start '100'
    option limit '150'
    option leasetime '24h'
    option dhcpv4 'server'
```

Apply config changes:
```bash
/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
```

---

## Config Sync Between Nodes

OpenWrt config lives in `hostPath` on each node. Keep nodes in sync after any change.

### Quick rsync (run on GW1 after changes):

```bash
#!/bin/sh
# /usr/local/bin/sync-gw-config.sh
STANDBY="192.168.1.3"

rsync -av /etc/openwrt/ root@${STANDBY}:/etc/openwrt/

ssh root@${STANDBY} "
  kubectl rollout restart daemonset/openwrt-gateway -n gateway
"
echo "Sync complete"
```

### Ansible structure (recommended for GitOps):

```
homelab-gateway/
├── inventory.yml
├── group_vars/
│   └── gateways.yml           # VIP, subnets, DHCP ranges, DNS
├── host_vars/
│   ├── rpi-gw1.yml            # vrrp_priority: 200, vrrp_state: MASTER
│   └── rpi-gw2.yml            # vrrp_priority: 100, vrrp_state: BACKUP
├── roles/
│   └── gateway/
│       ├── tasks/
│       │   ├── main.yml
│       │   ├── alpine.yml     # OS-level setup
│       │   ├── k3s.yml        # k3s install
│       │   ├── keepalived.yml # VRRP config
│       │   └── openwrt.yml    # config sync + pod deploy
│       ├── templates/
│       │   ├── keepalived.conf.j2
│       │   ├── network.j2     # OpenWrt /etc/config/network
│       │   ├── firewall.j2    # OpenWrt /etc/config/firewall
│       │   └── dhcp.j2        # OpenWrt /etc/config/dhcp
│       └── handlers/
│           └── main.yml
├── manifests/
│   └── gateway-daemonset.yaml
└── playbooks/
    └── deploy-gateway.yml
```

`group_vars/gateways.yml`:
```yaml
vip: 192.168.1.1
lan_interface: eth0
wan_interface: eth1
lan_subnet: 192.168.1.0/24
node_ips:
  gw1: 192.168.1.2
  gw2: 192.168.1.3
dhcp_start: 100
dhcp_limit: 150
dhcp_leasetime: 24h
dns_upstream:
  - 1.1.1.1
  - 8.8.8.8
local_domain: home.lab
vrrp_router_id: 51
vrrp_auth_pass: changeme123   # change this
k3s_version: v1.29.0+k3s1
openwrt_image: albrechtloh/openwrt-docker:openwrt-25.12.5-2bca120
```

Deploy everything:
```bash
ansible-playbook -i inventory.yml playbooks/deploy-gateway.yml
```

---

## Zero-Downtime Maintenance Procedure

```
1. Confirm GW2 is healthy
   $ kubectl get nodes
   $ kubectl get pods -n gateway -o wide
   $ ssh rpi-gw2 "rc-service keepalived status"

2. Force failover to GW2
   $ ssh rpi-gw1 "rc-service keepalived stop"
   # VIP moves to GW2 in ~2s

3. Verify GW2 holds the VIP
   $ ssh rpi-gw2 "ip addr show eth0 | grep 192.168.1.1"

4. Maintain GW1 freely — update Alpine, update k3s, reboot, reconfigure

5. Restore GW1
   $ ssh rpi-gw1 "rc-service keepalived start"
   # GW1 reclaims VIP (higher priority)

6. Verify
   $ ssh rpi-gw1 "ip addr show eth0 | grep 192.168.1.1"
```

---

## USB NIC Stability Notes for Agent

The USB NIC (eth1/WAN) on Alpine with mainline kernel is stable for both RTL8153 and
AX88179 chipsets. However apply these two hardening steps on both nodes to be safe:

```bash
# 1. Disable TX offload (prevents rare transmit queue lockups)
apk add ethtool
echo 'ethtool -K eth1 tx off' >> /etc/local.d/usb-nic.start
chmod +x /etc/local.d/usb-nic.start
rc-update add local default

# 2. Pin interface name so reboots don't rename eth1
cat > /etc/udev/rules.d/10-usb-nic.rules << 'EOF'
SUBSYSTEM=="net", DRIVERS=="r8152", NAME="eth-wan"
EOF
# Then update all configs to use eth-wan instead of eth1
```

---

## Summary Checklist

> Implementation is driven by the existing repo — see **"Adapting the Existing Repo"** for
> the phased task order. This checklist is the end-state acceptance criteria.

| Step | Task |
|---|---|
| 1 | Extend repo YAML schema for dual interfaces + VRRP (GAP 1, 2) |
| 2 | Add sysctl forwarding, USB NIC hardening, OpenWrt persistence (GAP 3, 4, 6) |
| 3 | Disable MetalLB / nginx-ingress; add OpenWrt DaemonSet manifest (GAP 5, 7) |
| 4 | Validate all of the above in QEMU before touching hardware |
| 5 | Add RTL8153 USB NIC dongle to each RPi |
| 6 | Build SD cards via `make build` + `make setup-sd`; boot both nodes |
| 7 | Verify cluster forms (`kubectl get nodes`) and eth1 is stable |
| 8 | Verify VIP is held by gw-1; NAT, DHCP, DNS all functional |
| 9 | Test failover: stop keepalived on gw-1, verify gw-2 takes VIP in <2s |
| 10 | Test pod restart: `kubectl delete pod` on gw-1, verify k3s restarts it |
| 11 | Test reboot: confirm OpenWrt config survives (validates diskless persistence) |
| 12 | Cut over home devices to the VIP as their gateway |

---

## Adapting the Existing Repo

**Repo:** `https://github.com/smetroid/diskless-alpine-k3s-rpi`
**What it is:** Alpine Linux diskless k3s cluster builder for Raspberry Pi. YAML-driven,
generates apkovl overlays, OpenRC service ordering, bind-mount persistence, QEMU test harness.

This repo is the intended starting point. Do **not** rebuild node provisioning from scratch.

### Why diskless is a win for a gateway

A gateway is always-on and writes constantly — SD card wear is a classic RPi router failure
mode. Running the root filesystem from RAM with only critical state persisted to SD
effectively eliminates this. The existing design is a better fit for this role than a
conventional disk-based install would be.

### What already works — do not touch

| Capability | Status |
|---|---|
| Alpine aarch64 diskless boot on RPi | ✅ Working |
| k3s server/agent install + cluster join | ✅ Working |
| YAML-driven config as single source of truth | ✅ Working |
| apkovl overlay generation | ✅ Working |
| OpenRC service boot ordering | ✅ Working |
| Bind-mount persistence model (`/mnt/data`) | ✅ Working |
| `auto_start_services` (apk install + rc-update + rc-service) | ✅ Working |
| SD card preparation (Linux + macOS) | ✅ Working |
| QEMU multi-node test harness | ✅ Working |
| Per-node static IP assignment | ✅ Working |
| Config validation (`make validate`) | ✅ Working |

### Gap list — what must be added

---

#### GAP 1 — Dual-interface support in the config schema  ⚠️ **Largest task**

**Current schema assumes one NIC per node:**

```yaml
network:
  gateway: "192.168.1.1"      # points AT an upstream router
nodes:
  - name: "k3s-master"
    ip: "192.168.1.21"        # single interface only
```

**Problem:** for a gateway cluster this inverts. `192.168.1.1` becomes the VIP the cluster
*owns*, not an upstream device it points at. Each node also needs a WAN interface, and the
default route must come from WAN DHCP — not from a LAN `gateway:` value.

**Proposed schema extension:**

```yaml
network:
  domain: "home.lab"
  lan_subnet: "192.168.1.0/24"
  vip: "192.168.1.1"              # NEW — the floating gateway IP
  dns_upstream:
    - "1.1.1.1"
    - "8.8.8.8"
  # NOTE: no top-level `gateway:` — this cluster IS the gateway

nodes:
  - name: "gw-1"
    role: "master"
    interfaces:                    # NEW — replaces flat `ip:`
      lan:
        device: "eth0"
        ip: "192.168.1.2/24"
      wan:
        device: "eth1"
        proto: "dhcp"              # or static, per ISP
    vrrp:                          # NEW
      state: "MASTER"
      priority: 200

  - name: "gw-2"
    role: "worker"
    interfaces:
      lan:
        device: "eth0"
        ip: "192.168.1.3/24"
      wan:
        device: "eth1"
        proto: "dhcp"
    vrrp:
      state: "BACKUP"
      priority: 100
```

**Files to change:**
- `lib/yaml-parser.sh` — parse nested `interfaces:` and `vrrp:` blocks
- `scripts/validate-config.sh` — validate both interfaces present, VRRP priorities unique,
  VIP inside `lan_subnet`, VIP not colliding with any node IP
- `scripts/create-apkovl-yaml.sh` — generate `/etc/network/interfaces` with both NICs
- `cluster-config.yaml.example` — add a gateway-cluster example

**Backward compatibility:** keep the flat `ip:` form working so existing workload clusters
built from this repo don't break. Treat `interfaces:` as an optional richer form.

---

#### GAP 2 — keepalived / VRRP support

**Good news:** `auto_start_services` already handles installation. The package→service
mapping resolves `keepalived` → `keepalived` with no new code:

```yaml
auto_start_services:
  - "keepalived"
  - "chrony"
```

**What's missing:** a per-node templated `keepalived.conf`, since `state` and `priority`
differ between nodes. This fits the existing per-node generation pattern.

**Work:**
- Add `templates/keepalived.conf.tmpl`
- Extend `scripts/create-apkovl-yaml.sh` to render it per node from the `vrrp:` block
- Place output at `/etc/keepalived/keepalived.conf` in each node's apkovl
- Add notify scripts to `/etc/keepalived/` (see the VRRP section earlier in this doc)

---

#### GAP 3 — IP forwarding

Not currently set. Required for any routing.

**Work:** add to the apkovl sysctl config:

```
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
```

Ensure it is applied at boot (either `/etc/sysctl.d/99-gateway.conf` in the apkovl, or via
the existing `system-bootstrap` OpenRC service).

---

#### GAP 4 — OpenWrt config persistence

**Critical**, because the root filesystem runs from RAM. Without this, OpenWrt config is
lost on every reboot.

**Current:**
```yaml
storage:
  persistent_paths:
    - "/etc/k3s"
    - "/var/lib/k3s"
```

**Needed:**
```yaml
storage:
  persistent_paths:
    - "/etc/k3s"
    - "/var/lib/k3s"
    - "/etc/openwrt"        # NEW — hostPath source for the DaemonSet
```

This must become a bind mount from `/mnt/data/etc-openwrt` → `/etc/openwrt`, handled by the
existing `storage-init` service. The DaemonSet's `hostPath` volumes point here.

---

#### GAP 5 — Disable MetalLB and nginx-ingress for this cluster

Both default to `enabled: true`. Neither is needed for a gateway-only cluster, and the
MetalLB pool actively conflicts:

```yaml
# Current example — pool overlaps a typical DHCP range
loadbalancer_pool:
  start: "192.168.1.100"
  end: "192.168.1.199"
```

**Work:**
```yaml
services:
  metallb:
    enabled: false
  nginx_ingress:
    enabled: false
```

Confirm `scripts/generate-manifests-yaml.sh` cleanly skips manifest generation when both are
disabled, rather than emitting empty or broken YAML.

---

#### GAP 6 — USB NIC hardening

Needed because the WAN interface is a USB dongle. Two mitigations, both applied at boot.

**Work:** add `/etc/local.d/usb-nic.start` to the apkovl:

```sh
#!/bin/sh
# Disable TX offload — prevents rare transmit queue lockups
ethtool -K eth1 tx off
```

Add `ethtool` to the `alpine.packages` list, and ensure the `local` service is in the
default runlevel (`rc-update add local default`).

**Optionally** pin the interface name so reboots can't reorder NICs:

```
# /etc/udev/rules.d/10-usb-nic.rules
SUBSYSTEM=="net", DRIVERS=="r8152", NAME="eth-wan"
```

If you adopt this, use `eth-wan` consistently in the YAML `interfaces.wan.device` field.

---

#### GAP 7 — OpenWrt DaemonSet manifest

The repo generates k3s manifests (MetalLB, nginx-ingress) into `builds/k3s-manifests/`.
Add the gateway DaemonSet to that pipeline so it deploys automatically at cluster bring-up
via k3s's auto-deploy manifest directory.

**Work:**
- Add `templates/openwrt-daemonset.yaml.tmpl`
- Render it in `scripts/generate-manifests-yaml.sh`, templating the image reference and
  hostPath locations from YAML
- Place output where k3s auto-applies it (`/var/lib/rancher/k3s/server/manifests/`)

Use the DaemonSet spec from the **OpenWrt DaemonSet** section earlier in this document.

---

### Verification / version bumps

| Item | Current | Action |
|---|---|---|
| Alpine version | `3.18.6` in example config | Bump to 3.22.x — newer kernel means better `r8152` / `ax88179` USB NIC driver support |
| RPi model support | README states Pi 3 or 4 | Verify boot path if gateway nodes are Pi 5 |
| Master node taint | `CriticalAddonsOnly=true:NoExecute` | Harmless — the DaemonSet uses `tolerations: [{operator: Exists}]`. Do not remove that toleration if simplifying the manifest |
| k3s flannel iface | Not currently pinned | Pin to the LAN device so cluster traffic never traverses WAN |

---

### Suggested task order

```
Phase 1 — Schema (test entirely in QEMU, no hardware needed)
  1. Extend yaml-parser.sh for interfaces: and vrrp: blocks
  2. Extend validate-config.sh with gateway-specific checks
  3. Add gateway-cluster.yaml.example
  4. Verify `make validate` passes; confirm backward compat with flat `ip:`

Phase 2 — apkovl generation (still QEMU)
  5. Generate dual-interface /etc/network/interfaces
  6. Add keepalived.conf template + notify scripts
  7. Add sysctl IP forwarding
  8. Add /etc/local.d/usb-nic.start + ethtool package
  9. Add /etc/openwrt to persistent_paths + storage-init bind mount
 10. `make build-test` and boot two QEMU nodes; verify VRRP elects a master
     and the VIP moves when the master is stopped

Phase 3 — Manifests (QEMU)
 11. Disable metallb + nginx_ingress; confirm clean skip
 12. Add openwrt-daemonset.yaml.tmpl to manifest generation
 13. Verify one pod per node in the QEMU cluster

Phase 4 — Hardware
 14. Source RTL8153 USB NIC dongles
 15. Flash both RPis; verify eth1 appears and is stable
 16. Bring up cluster; verify VIP, NAT, DHCP, DNS
 17. Failover test: stop keepalived on gw-1, confirm <2s recovery
 18. Pod restart test: `kubectl delete pod` on gw-1, confirm k3s restarts it
 19. Reboot test: confirm OpenWrt config survives (validates GAP 4)
```

**Phases 1–3 need no hardware.** The existing QEMU harness (`./test/qemu-test.sh`) can
validate schema changes, VRRP election, and DaemonSet scheduling before a Pi is touched.
This is the single biggest advantage of building on this repo.

---

### Resolved decisions

**1. QEMU second NIC — confirmed available.**
The test harness supports attaching a second NIC per VM, so dual-interface config and VRRP
election can both be validated in QEMU. Phases 1–3 require no hardware. Extend
`qemu.yaml.example` with the second interface definition to match the new schema.

**2. OpenWrt container image — pinned.**

```
albrechtloh/openwrt-docker:openwrt-25.12.5-2bca120
```

```bash
docker pull albrechtloh/openwrt-docker:openwrt-25.12.5-2bca120
```

Set this in the cluster YAML rather than hardcoding it in the DaemonSet template:

```yaml
services:
  openwrt:
    enabled: true
    image: "albrechtloh/openwrt-docker:openwrt-25.12.5-2bca120"
```

Two notes for the implementer:
- Confirm the image publishes an **arm64/aarch64** manifest before building around it —
  `docker manifest inspect albrechtloh/openwrt-docker:openwrt-25.12.5-2bca120`
- The tag already includes a commit hash, which is good. Consider resolving it to a full
  `sha256:` digest in the YAML so the deployment is fully immutable.

**3. Control plane — single server to start.**
Begin with one k3s server (gw-1) plus one agent (gw-2), as written throughout this document.

This is sufficient because the two failure domains are independent: if the server node dies,
VRRP still moves the VIP to gw-2 and **traffic keeps flowing** — you only lose `kubectl`
until gw-1 returns. Network availability does not depend on control-plane availability.

Move to dual-server embedded etcd later only if losing `kubectl` during a gw-1 outage
becomes an actual problem. That migration is:

```bash
# On gw-1, restart with cluster-init
k3s server --cluster-init

# On gw-2, join as a second server instead of an agent
k3s server --server https://192.168.1.2:6443 --token <token>
```

> ⚠️ Embedded etcd wants an odd number of nodes for quorum. A 2-node etcd cluster has **no**
> fault tolerance — losing either node loses quorum, which is worse than a single server.
> If you go this route, plan for 3 nodes.

---

## Appendix A: x86 SBCs as an Alternative to RPi

If you want to avoid USB NIC dongles entirely, these x86 SBCs have **dual NICs built in**
and run VyOS or any Linux natively without ARM compatibility concerns:

| Board | CPU | Built-in NICs | VyOS | Price |
|---|---|---|---|---|
| **MSI MS-CF16 V3.0** | Alder Lake | 2.5GbE + 1GbE | ✅ | ~$200+ |
| **ZimaBoard 2** | Intel N150 | Dual 2.5GbE | ✅ | ~$150–200 |
| **AAEON UP 7000** | N50/N97/N100 | 1GbE (+ USB NIC) | ✅ | ~$130–180 |

On x86 nodes, VyOS can be run via KubeVirt — see Appendix B.

---

## Appendix B: VyOS via KubeVirt (x86 Only)

If using x86 nodes, KubeVirt allows running VyOS as a proper VM inside k3s.
VyOS only officially supports amd64 — it does not run on RPi natively.

VyOS is open source (GPL). Pre-built LTS ISOs require a subscription; the rolling
release can be built free from source:

```bash
git clone -b current --single-branch https://github.com/vyos/vyos-build
cd vyos-build
docker pull vyos/vyos-build:current
docker run --rm --privileged \
  -v $(pwd):/vyos -w /vyos \
  vyos/vyos-build:current \
  sudo --preserve-env ./build-vyos-image generic \
    --architecture amd64 \
    --build-by "homelab@local" \
    --build-type release \
    --version "1.5-rolling"
```

Requirements:
- x86-64 k3s nodes only
- KubeVirt + CDI installed
- Multus CNI for WAN interface passthrough
- MetalLB for VIP
- VyOS VMs pinned to separate nodes via `nodeSelector`
- VRRP configured inside VyOS using `set high-availability vrrp`

---

## Appendix C: Experimental VyOS ARM64 Build for RPi

> 🧪 Not officially supported. Builds break on kernel version mismatches and boot
> failures on RPi hardware are commonly reported. Good learning project, not production.

Community tools:
- `https://github.com/runborg/vyos-pi-builder` — RPi-specific, cross-compiles via QEMU
- `https://github.com/mcbridematt/vyos-arm64-builder` — generic ARM64, not RPi-specific

Key challenges: RPi uses a proprietary bootloader, VyOS expects UEFI/GRUB; kernel version
must match exactly between VyOS and RPi firmware; build takes 1–2+ hours per attempt.

If it boots, VyOS CLI config is identical to x86 — the `set`/`commit`/`save` model works
the same way.
