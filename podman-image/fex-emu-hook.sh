#!/bin/bash
# OCI precreate hook: add FEX-Emu bind mounts and env vars to container OCI config.
# Requires: jq (included in Fedora CoreOS base)
#
# Precreate hooks receive the full OCI config.json on stdin and output the
# (potentially modified) config on stdout. crun processes the modified config
# and handles all bind mounts — no nsenter or special privileges needed.
#
# Filtered by when.annotations in fex-emu-hook.json: only containers with
# io.podman.image.arch=amd64 trigger this hook (zero overhead for ARM64).
#
# FEX_APP_* env vars are injected here (not in containers.conf) so only amd64
# containers receive them. The specFromState fix in podman ensures `podman exec`
# inherits these env vars from the runtime config.json on disk.
set -euo pipefail

CONFIG=$(cat)

# Add FEX-Emu bind mounts and env vars to the OCI config.
# Annotation-based filtering ensures only amd64 containers are modified.
# FEX_APP_* env vars tell FEX where to store data/config/cache inside the container.
echo "$CONFIG" | jq '
  .process.env += [
    "FEX_APP_DATA_LOCATION=/tmp/fex-data/",
    "FEX_APP_CONFIG_LOCATION=/tmp/fex-data/",
    "FEX_APP_CACHE_LOCATION=/tmp/fex-data/cache/"
  ] |
  .mounts += [
    {"destination": "/usr/bin/FEXInterpreter", "type": "bind", "source": "/usr/bin/FEXInterpreter", "options": ["bind", "ro"]},
    {"destination": "/usr/bin/FEXServer", "type": "bind", "source": "/usr/bin/FEXServer", "options": ["bind", "ro"]},
    {"destination": "/usr/bin/FEXOfflineCompiler", "type": "bind", "source": "/usr/bin/FEXOfflineCompiler", "options": ["bind", "ro"]},
    {"destination": "/etc/fex-emu", "type": "bind", "source": "/etc/fex-emu", "options": ["bind", "ro"]},
    {"destination": "/var/lib/fex-emu-rootfs", "type": "bind", "source": "/var/lib/fex-emu-rootfs", "options": ["bind", "ro"]}
  ]
' 2>/dev/null || echo "$CONFIG"
