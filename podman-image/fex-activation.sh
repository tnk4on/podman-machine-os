#!/bin/bash
# FEX-Emu activation script for Podman Machine VM (Strategy C)
# Loop-mounts EROFS rootfs, registers binfmt_misc handlers,
# and configures containers.conf for in-container FEXServer.
# FEX volumes and env vars are injected via OCI precreate hook.
# Code caching is enabled by default via Config.json EnableCodeCachingWIP.
set -euo pipefail

# SSOT: Guest-side marker file controls FEX enable/disable.
# Absence (default) = FEX enabled; presence = FEX disabled (QEMU fallback).
# Same pattern as Rosetta's /etc/containers/enable-rosetta (inverted logic).
DISABLE_MARKER="/etc/containers/disable-fex-emu"

if [ -f "$DISABLE_MARKER" ]; then
    echo "FEX: Disabled by marker file $DISABLE_MARKER — using QEMU fallback"
    exit 0
fi

EROFS_FILE="/usr/share/fex-emu/RootFS/default.erofs"
ROOTFS_DIR="/var/lib/fex-emu-rootfs"
FEX_CONFIG="/etc/fex-emu/Config.json"

# Step 1: Loop mount EROFS rootfs (no extraction needed — instant, saves 3.4GB disk)
if [ -f "$EROFS_FILE" ] && ! mountpoint -q "$ROOTFS_DIR"; then
    echo "FEX: Mounting x86-64 RootFS from EROFS (loop mount)..."
    mkdir -p "$ROOTFS_DIR"
    mount -o loop,ro "$EROFS_FILE" "$ROOTFS_DIR"
    echo "FEX: RootFS loop-mounted at $ROOTFS_DIR"
fi

# Step 2: Configure FEX with RootFS path and code caching
if mountpoint -q "$ROOTFS_DIR"; then
    mkdir -p "$(dirname "$FEX_CONFIG")"
    cat > "$FEX_CONFIG" << EOF
{
  "Config": {
    "RootFS": "$ROOTFS_DIR/",
    "EnableCodeCachingWIP": true
  }
}
EOF
    # Also set for root and core users
    for home in /root /var/home/core; do
        mkdir -p "$home/.fex-emu/Server" 2>/dev/null || true
        cp "$FEX_CONFIG" "$home/.fex-emu/Config.json" 2>/dev/null || true
    done
    # Fix ownership for core user (rootless container UID mapping can break this)
    chown -R core:core /var/home/core/.fex-emu/ 2>/dev/null || true
    echo "FEX: Config set with RootFS=$ROOTFS_DIR"

    # Code caching: enabled by default via Config.json EnableCodeCachingWIP.
    # FEXServer caches JIT-compiled code per container in /tmp/fex-data/cache/.
    # FEX_APP_* env vars are set in containers.conf for all containers
    # (harmless for ARM64; FEX is only invoked via binfmt_misc for x86/x86_64).

    # FEX volumes are injected via OCI precreate hook.
    # The hook modifies each container's OCI config.json to add FEX bind mounts.
    # Annotation-based filtering (io.podman.image.arch=amd64) ensures only amd64
    # containers get the mounts; ARM64 containers have zero overhead.
    mkdir -p /etc/containers/oci/hooks.d
    cp /usr/local/lib/fex-emu/fex-emu-hook.json /etc/containers/oci/hooks.d/
    echo "FEX: OCI precreate hook installed"

    # SELinux: Podman may create container storage dirs before SELinux policy
    # is loaded, resulting in default_t labels instead of container_file_t.
    # Pre-create with correct labels as fallback (fex-container.te handles
    # execmem but not storage label issues).
    for home in /var/home/core /root; do
        STORAGE_DIR="$home/.local/share/containers/storage"
        if [ ! -d "$STORAGE_DIR" ]; then
            mkdir -p "$STORAGE_DIR" 2>/dev/null || true
            chown -R $(stat -c '%U:%G' "$home") "$home/.local" 2>/dev/null || true
            chcon -R -t container_file_t "$home/.local/share/containers" 2>/dev/null || true
            echo "FEX: SELinux labels set for $STORAGE_DIR (fallback)"
        fi
    done

    # Rootless config: hooks_dir + FEX_APP_* env for in-container paths
    CORE_CONTAINERS_DIR="/var/home/core/.config/containers"
    mkdir -p "$CORE_CONTAINERS_DIR" 2>/dev/null || true
    cat > "$CORE_CONTAINERS_DIR/containers.conf" << 'CEOF'
[containers]
netns="bridge"
pids_limit=0
env = ["FEX_APP_DATA_LOCATION=/tmp/fex-data/", "FEX_APP_CONFIG_LOCATION=/tmp/fex-data/", "FEX_APP_CACHE_LOCATION=/tmp/fex-data/cache/"]

[engine]
hooks_dir = ["/etc/containers/oci/hooks.d"]
CEOF
    chown -R core:core "$CORE_CONTAINERS_DIR"

    # Rootful config: hooks_dir + FEX_APP_* env
    mkdir -p /root/.config/containers 2>/dev/null || true
    cat > /root/.config/containers/containers.conf << 'CEOF'
[containers]
env = ["FEX_APP_DATA_LOCATION=/tmp/fex-data/", "FEX_APP_CONFIG_LOCATION=/tmp/fex-data/", "FEX_APP_CACHE_LOCATION=/tmp/fex-data/cache/"]

[engine]
hooks_dir = ["/etc/containers/oci/hooks.d"]
CEOF

    echo "FEX: containers.conf configured (rootless + rootful, FEX_APP_* env for all containers)"

    # Restart podman API service to pick up new containers.conf
    # The podman socket-activated service may have started before this script
    # created containers.conf, causing remote API containers (from macOS host)
    # to miss FEX volume mounts and environment variables.
    if sudo -u core XDG_RUNTIME_DIR=/run/user/501 systemctl --user is-active podman.service &>/dev/null; then
        sudo -u core XDG_RUNTIME_DIR=/run/user/501 systemctl --user restart podman.socket &>/dev/null || true
        echo "FEX: Restarted podman service to pick up containers.conf"
    fi
fi

# Step 3: Unregister x86/x86_64 QEMU and FEX handlers (will re-register with FEX below)
# Other arch QEMU handlers (s390x, ppc64le, riscv64, etc.) are preserved for multi-arch support.
# (system fex-emu RPM may register /usr/bin/FEX which is dynamic, not our static-pie build)
for handler in qemu-i386 qemu-i486 qemu-x86_64 FEX-x86 FEX-x86_64; do
    if [ -f "/proc/sys/fs/binfmt_misc/$handler" ]; then
        echo -1 > "/proc/sys/fs/binfmt_misc/$handler"
        echo "FEX: Unregistered $handler"
    fi
done

# Step 4: Register FEX binfmt_misc handlers
# Strategy C uses POCF flags:
# - P: preserve argv[0]
# - O: open binary at exec time
# - C: credentials — use binary's credentials
# - F: fix binary — pre-open FEXInterpreter at registration time so the kernel
#   doesn't need to find it inside the container rootfs at exec time
#   (crun applies volume mounts AFTER resolving the init binary, so without F
#   the kernel can't find /usr/bin/FEXInterpreter in the container)
echo ":FEX-x86:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/FEXInterpreter:POCF" > /proc/sys/fs/binfmt_misc/register
echo ":FEX-x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/FEXInterpreter:POCF" > /proc/sys/fs/binfmt_misc/register
echo "FEX: Registered x86 and x86_64 binfmt handlers (Strategy C: POCF flags)"

# Step 5: Log multi-arch coexistence status
# FEX handles x86/x86_64; QEMU handles all other architectures (s390x, ppc64le, riscv64, etc.)
QEMU_HANDLERS=$(ls /proc/sys/fs/binfmt_misc/qemu-* 2>/dev/null | grep -v 'x86\|i386\|i486' | xargs -I{} basename {} | tr '\n' ' ')
if [ -n "$QEMU_HANDLERS" ]; then
    echo "FEX: QEMU handlers preserved for other architectures: $QEMU_HANDLERS"
else
    echo "FEX: No QEMU handlers for other architectures found"
fi
