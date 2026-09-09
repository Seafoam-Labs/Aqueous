#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ZIG_GLOBAL_CACHE_DIR=${AQUEOUS_SETTINGS_CACHE:-/tmp/aqueous-settings-build}/global
export ZIG_LOCAL_CACHE_DIR=${AQUEOUS_SETTINGS_CACHE:-/tmp/aqueous-settings-build}/local
zig build --build-file "$root/build.zig" -Doptimize=ReleaseSafe
# A user install never writes /etc or changes shell plugin enablement.
PREFIX="${HOME}/.local" AQUEOUS_SETTINGS_BRIDGE_DISCOVERY="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins" "$root/packaging/install.sh"
