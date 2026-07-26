#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bin_root=${XDG_BIN_HOME:-"$HOME/.local/bin"}
cache_root=${AQUEOUS_PLUGIN_CACHE_ROOT:-/tmp/aqueous-plugin-dev-cache}

env \
    ZIG_GLOBAL_CACHE_DIR="$cache_root/global" \
    ZIG_LOCAL_CACHE_DIR="$cache_root/local" \
    zig build \
    --build-file "$plugin_root/helper/build.zig" \
    -Doptimize=ReleaseSafe \
    --prefix "$plugin_root/helper/zig-out"

install -Dm755 "$plugin_root/helper/zig-out/bin/aqueous-config" "$bin_root/aqueous-config"

noctalia msg plugins source add aqueous-dev path "$plugin_root"
noctalia msg plugins enable aqueous/settings

echo "Aqueous Settings is enabled from $plugin_root"
echo "Add it from Noctalia Settings → Bar → Add widget."

