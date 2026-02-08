# Auto-Start Services Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `auto_start_services` YAML configuration to automatically install packages and start their services at every boot.

**Architecture:** A new OpenRC service (`auto-start-services`) is generated during apkovl build. It reads packages from YAML config, installs them via `apk add`, derives service names from package names, and starts services via `rc-service`. The service runs during boot between storage-init and k3s-bootstrap.

**Tech Stack:** Alpine Linux OpenRC, APK package manager, YAML parser (lib/yaml-parser.sh), Bash scripts

---

## Task 1: Add `auto_start_services` block to YAML configs

**Files:**
- Modify: `k3s.yaml` (after line ~120)
- Modify: `qemu.yaml` (after line ~132)

**Step 1: Add auto_start_services section to k3s.yaml**

Add after the `overlay_packages` section:

```yaml
# Services to auto-start at every boot
# Each package will be installed via 'apk add' and its service started automatically
# Service dependencies (like rpcbind for nfs) are handled by OpenRC
auto_start_services:
  - "nfs-utils"   # Installs package, starts 'nfs' service
  - "chrony"      # Installs package, starts 'chronyd' service
```

**Step 2: Add auto_start_services section to qemu.yaml**

Add after the `overlay_packages` section (note: qemu.yaml already installs nfs-utils via alpine.packages, but this ensures service starts):

```yaml
# Services to auto-start at every boot
# Each package will be installed via 'apk add' and its service started automatically
# Service dependencies (like rpcbind for nfs) are handled by OpenRC
auto_start_services:
  - "nfs-utils"   # Installs package, starts 'nfs' service
  - "chrony"      # Installs package, starts 'chronyd' service
```

**Step 3: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('k3s.yaml'))"`
Expected: No errors (if error, fix YAML syntax)

Run: `python3 -c "import yaml; yaml.safe_load(open('qemu.yaml'))"`
Expected: No errors (if error, fix YAML syntax)

**Step 4: Commit**

```bash
git add k3s.yaml qemu.yaml
git commit -m "feat: add auto_start_services YAML configuration block"
```

---

## Task 2: Add `generate_auto_start_services()` function to script

**Files:**
- Modify: `scripts/create-apkovl-yaml.sh` (after `process_overlay_packages()` function, around line ~280)

**Step 1: Add the generate_auto_start_services function**

```bash
# Generate auto-start service configuration
# Creates a service that installs packages and starts services at boot
generate_auto_start_services() {
    local apkovl_dir="$1"
    local config_file="$2"

    local packages=$(yaml_get_array ".auto_start_services[]" "$config_file")

    if [ -z "$packages" ]; then
        echo "No auto-start services configured"
        return 0
    fi

    echo "Generating auto-start services configuration..."

    # Build packages list for the service script
    local pkg_list=""
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        pkg_list="$pkg_list $pkg"
    done <<< "$packages"

    # Trim leading space
    pkg_list=$(echo "$pkg_list" | sed 's/^ //')

    if [ -z "$pkg_list" ]; then
        echo "  No packages to configure"
        return 0
    fi

    echo "  Configuring: $pkg_list"

    # Create the auto-start service script
    cat > "${apkovl_dir}/etc/init.d/auto-start-services" <<'SERVICE_SCRIPT'
#!/sbin/openrc-run

# Auto-start services - installs packages and starts services at boot
# Generated from cluster-config.yaml auto_start_services section

description="Install and start configured services"

depend() {
    need net
    after firewall storage-init
    before k3s-bootstrap
}

start() {
    ebegin "Installing and starting auto-start services"

    local failed=0
    # Packages to install (injected during build)
    PACKAGES="__PACKAGES__"

    for pkg in $PACKAGES; do
        # Skip empty entries
        [ -z "$pkg" ] && continue

        # Package already installed? Skip installation
        if apk info -e "$pkg" >/dev/null 2>&1; then
            einfo "$pkg already installed"
        else
            # Try installation, but don't fail hard
            einfo "Installing $pkg..."
            if ! apk add -q "$pkg"; then
                ewarn "Failed to install $pkg (will retry next boot)"
                failed=1
                continue
            fi
        fi

        # Derive service name from package name
        svc=$(derive_service_name "$pkg")

        # Service exists? Start it
        if [ -f "/etc/init.d/$svc" ]; then
            if rc-service "$svc" status >/dev/null 2>&1; then
                einfo "$svc already running"
            else
                einfo "Starting $svc..."
                if ! rc-service "$svc" start; then
                    ewarn "Failed to start $svc"
                fi
            fi
        else
            einfo "No service found for $pkg (package-only)"
        fi
    done

    # Always return success - boot should continue even if one service fails
    eend 0
}

derive_service_name() {
    local pkg="$1"
    case "$pkg" in
        nfs-utils)      echo "nfs" ;;
        chrony)         echo "chronyd" ;;
        acpid)          echo "acpid" ;;
        syslog)         echo "syslog" ;;
        cron)           echo "crond" ;;
        sshd)           echo "sshd" ;;
        *)
            # Fallback: strip common suffixes
            echo "$pkg" | sed 's/-utils$//' | sed 's/-openrc$//'
            ;;
    esac
}
SERVICE_SCRIPT

    # Replace placeholder with actual packages list
    sed -i "s/__PACKAGES__/$pkg_list/g" "${apkovl_dir}/etc/init.d/auto-start-services"

    chmod +x "${apkovl_dir}/etc/init.d/auto-start-services"

    # Enable in default runlevel
    ln -sf /etc/init.d/auto-start-services "${apkovl_dir}/etc/runlevels/default/auto-start-services"

    echo "  ✓ auto-start-services service created and enabled"
}
```

**Step 2: Verify function was added**

Run: `grep -n "generate_auto_start_services()" scripts/create-apkovl-yaml.sh`
Expected: Shows line number where function was added

**Step 3: Commit**

```bash
git add scripts/create-apkovl-yaml.sh
git commit -m "feat: add generate_auto_start_services function"
```

---

## Task 3: Call `generate_auto_start_services()` during apkovl build

**Files:**
- Modify: `scripts/create-apkovl-yaml.sh` (find where `process_overlay_packages` is called, around line ~278)

**Step 1: Find the call to process_overlay_packages**

Look for:
```bash
process_overlay_packages "${NODE_NAME}-apkovl" "$CONFIG_FILE"
```

**Step 2: Add call to generate_auto_start_services after process_overlay_packages**

Add right after the `process_overlay_packages` call:

```bash
# Generate auto-start services configuration
generate_auto_start_services "${NODE_NAME}-apkovl" "$CONFIG_FILE"
```

**Step 3: Verify the change**

Run: `grep -A1 "process_overlay_packages" scripts/create-apkovl-yaml.sh | grep generate_auto_start_services`
Expected: Shows the new function call

**Step 4: Commit**

```bash
git add scripts/create-apkovl-yaml.sh
git commit -m "feat: call generate_auto_start_services during build"
```

---

## Task 4: Test build with k3s.yaml

**Step 1: Clean previous builds**

Run: `make clean`
Expected: `builds/` directory is cleaned

**Step 2: Build with default config**

Run: `make build`
Expected: Build completes with "Generating auto-start services configuration..." message

**Step 3: Verify service was created**

Run: `ls -la builds/k3s-21-apkovl/etc/init.d/auto-start-services`
Expected: File exists and is executable

Run: `ls -la builds/k3s-21-apkovl/etc/runlevels/default/auto-start-services`
Expected: Symlink exists

**Step 4: Verify PACKAGES list in service**

Run: `grep "PACKAGES=" builds/k3s-21-apkovl/etc/init.d/auto-start-services`
Expected: `PACKAGES="nfs-utils chrony"` (or similar based on config)

**Step 5: Verify service script syntax**

Run: `sh -n builds/k3s-21-apkovl/etc/init.d/auto-start-services`
Expected: No syntax errors

**Step 6: No commit yet** (testing in progress)

---

## Task 5: Test QEMU boot verification

**Prerequisite:** QEMU test environment working

**Step 1: Build with qemu.yaml**

Run: `CONFIG_FILE=qemu.yaml ./scripts/build-from-yaml.sh`
Expected: Build completes successfully

**Step 2: Start QEMU test**

Run: `CONFIG_FILE=qemu.yaml ./test/qemu-test.sh`
Expected: QEMU boots

**Step 3: Wait for boot, then check service status**

Run: `sshpass -p root ssh -o StrictHostKeyChecking=no -p 2215 root@localhost "rc-status | grep auto-start"`
Expected: Shows `auto-start-services` in started state

**Step 4: Verify nfs-utils is installed**

Run: `sshpass -p root ssh -o StrictHostKeyChecking=no -p 2215 root@localhost "apk info | grep nfs-utils"`
Expected: `nfs-utils-<version>` listed

**Step 5: Verify nfs service is running**

Run: `sshpass -p root ssh -o StrictHostKeyChecking=no -p 2215 root@localhost "rc-status | grep nfs"`
Expected: `nfs` service shows as "started"

**Step 6: Verify rpcbind started (dependency)**

Run: `sshpass -p root ssh -o StrictHostKeyChecking=no -p 2215 root@localhost "rc-status | grep rpcbind"`
Expected: `rpcbind` service shows as "started"

**Step 7: Stop QEMU test**

Run: `CONFIG_FILE=qemu.yaml ./test/qemu-test.sh stop`
Expected: QEMU stops

**Step 8: Commit after successful test**

```bash
git add -A
git commit -m "test: verify auto-start-services works in QEMU"
```

---

## Task 6: Add documentation to README

**Files:**
- Modify: `README.md`

**Step 1: Add auto_start_services documentation**

Add a new section after "Overlay packages" or in the appropriate configuration section:

```markdown
### Auto-Start Services

The `auto_start_services` block allows you to specify packages that should be installed at every boot and have their services automatically started. This is useful for services like NFS that need to be available before k3s starts.

```yaml
auto_start_services:
  - "nfs-utils"   # NFS client utilities, starts 'nfs' service
  - "chrony"      # NTP daemon, starts 'chronyd' service
```

**How it works:**
1. At boot, the `auto-start-services` OpenRC service runs
2. Each package is installed via `apk add` (if not already installed)
3. The service name is derived from the package name
4. The service is started via `rc-service`
5. Service dependencies are handled automatically by OpenRC

**Package-to-service mappings:**
| Package | Service | Notes |
|---------|---------|-------|
| `nfs-utils` | `nfs` | Auto-starts rpcbind, rpc.statd |
| `chrony` | `chronyd` | NTP time synchronization |
| `acpid` | `acpid` | ACPI events |
| `*-utils` | `*` | Strips `-utils` suffix |
| `*-openrc` | `*` | Strips `-openrc` suffix |

If a package has no corresponding service, it is still installed but no service is started.
```

**Step 2: Verify documentation renders correctly**

Run: `head -200 README.md | tail -50`
Expected: Documentation is visible and formatted

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add auto_start_services documentation"
```

---

## Task 7: Clean up and final verification

**Step 1: Full clean build**

Run: `make clean && make build`
Expected: Clean build completes successfully

**Step 2: Verify all nodes have auto-start-services**

Run: `for f in builds/*-apkovl/etc/runlevels/default/auto-start-services; do echo "$f exists: $(test -f "$f" && echo YES || echo NO)"; done`
Expected: All nodes show "YES"

**Step 3: Check git status**

Run: `git status`
Expected: Clean working directory (all changes committed)

**Step 4: View final diff**

Run: `git diff main...feature/auto-start-services --stat`
Expected: Shows summary of all changes

**Step 5: Final commit if needed**

```bash
# If any uncommitted changes remain
git add -A
git commit -m "feat: complete auto-start-services implementation"
```

---

## Summary of Changes

| File | Change |
|------|--------|
| `k3s.yaml` | Add `auto_start_services` block |
| `qemu.yaml` | Add `auto_start_services` block |
| `scripts/create-apkovl-yaml.sh` | Add `generate_auto_start_services()` function and call it |
| `README.md` | Add documentation for `auto_start_services` |

## Boot Order

```
1. storage-init       (mount partitions, bind mounts)
2. auto-start-services (NEW: install packages, start services)
3. k3s-bootstrap     (k3s installation, cluster join)
4. k3s                (k3s daemon)
```

## Testing Checklist

- [ ] Build completes with both k3s.yaml and qemu.yaml
- [ ] Service script is created in apkovl
- [ ] Service is enabled in default runlevel
- [ ] QEMU boot test passes
- [ ] nfs-utils package is installed
- [ ] nfs service is running
- [ ] rpcbind dependency is running
- [ ] Service survives reboot
- [ ] README documentation added
