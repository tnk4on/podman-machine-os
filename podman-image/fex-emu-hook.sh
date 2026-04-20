#!/bin/bash
# OCI precreate hook: add FEX-Emu bind mounts to container OCI config.
# Requires: jq (included in Fedora CoreOS base)
#
# Precreate hooks receive the full OCI config.json on stdin and output the
# (potentially modified) config on stdout. crun processes the modified config
# and handles all bind mounts — no nsenter or special privileges needed.
#
# Filtered by when.annotations in fex-emu-hook.json: only containers with
# io.podman.image.arch=amd64 trigger this hook (zero overhead for ARM64).
#
# FEX_APP_* env vars are set in containers.conf (not here) so they are
# available to both `podman run` and `podman exec` processes.
set -euo pipefail

CONFIG=$(cat)

# Add FEX-Emu bind mounts to the OCI config.
# FEX_APP_* env vars are set in containers.conf (injected for all containers;
# harmless for ARM64 since FEX is only invoked via binfmt_misc for x86/x86_64).
echo "$CONFIG" | jq '
  .mounts += [
    {"destination": "/usr/bin/FEXInterpreter", "type": "bind", "source": "/usr/bin/FEXInterpreter", "options": ["bind", "ro"]},
    {"destination": "/usr/bin/FEXServer", "type": "bind", "source": "/usr/bin/FEXServer", "options": ["bind", "ro"]},
    {"destination": "/usr/bin/FEXOfflineCompiler", "type": "bind", "source": "/usr/bin/FEXOfflineCompiler", "options": ["bind", "ro"]},
    {"destination": "/etc/fex-emu", "type": "bind", "source": "/etc/fex-emu", "options": ["bind", "ro"]},
    {"destination": "/var/lib/fex-emu-rootfs", "type": "bind", "source": "/var/lib/fex-emu-rootfs", "options": ["bind", "ro"]}
  ]
' 2>/dev/null || echo "$CONFIG"
