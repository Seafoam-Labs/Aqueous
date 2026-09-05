#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD
plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cache_root=${AQUEOUS_PLUGIN_CACHE_ROOT:-/tmp/aqueous-dms-dev-cache}
env ZIG_GLOBAL_CACHE_DIR="$cache_root/global" ZIG_LOCAL_CACHE_DIR="$cache_root/local" \
    zig build --build-file "$plugin_root/../plugin/helper/build.zig"
bin_dir=${XDG_BIN_HOME:-"$HOME/.local/bin"}
install -Dm755 "$plugin_root/../plugin/helper/zig-out/bin/aqueous-config" "$bin_dir/aqueous-config"
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins"
mkdir -p "$plugin_dir"
target="$plugin_dir/aqueousSettings"
if [[ -e "$target" || -L "$target" ]]; then
    if [[ ! -L "$target" || $(readlink "$target") != "$plugin_root" ]]; then
        echo "Existing plugin at $target; move it aside before installing this development link." >&2
        exit 1
    fi
else
    ln -s "$plugin_root" "$target"
fi
printf '%s\n' "Installed helper in $bin_dir and plugin in $target." \
    'Enable Aqueous Settings in DMS Settings → Plugins, then add it to DankBar.' \
    'Open without a widget: dms ipc call aqueousSettings open'
