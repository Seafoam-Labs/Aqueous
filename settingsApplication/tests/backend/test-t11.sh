#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d /tmp/aqueous-t11-bus.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
mkdir -m700 "$scratch/home" "$scratch/runtime" "$scratch/config" "$scratch/state"
env -u DBUS_SESSION_BUS_ADDRESS -u DISPLAY -u WAYLAND_DISPLAY -u LD_PRELOAD \
    HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/runtime" \
    XDG_CONFIG_HOME="$scratch/config" XDG_STATE_HOME="$scratch/state" \
    dbus-run-session -- python3 "$root/tests/backend/test-t11.py" "$@"
