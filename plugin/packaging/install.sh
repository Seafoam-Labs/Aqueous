#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${PREFIX:-/usr}
destination=${DESTDIR:-}
cache_root=${AQUEOUS_PLUGIN_CACHE_ROOT:-/tmp/aqueous-plugin-package-cache}

env -u DESTDIR \
    ZIG_GLOBAL_CACHE_DIR="$cache_root/global" \
    ZIG_LOCAL_CACHE_DIR="$cache_root/local" \
    zig build \
    --build-file "$plugin_root/helper/build.zig" \
    -Doptimize=ReleaseSafe \
    --prefix "$plugin_root/helper/zig-out"

install -Dm755 \
    "$plugin_root/helper/zig-out/bin/aqueous-config" \
    "$destination$prefix/bin/aqueous-config"

source_root="$destination$prefix/share/aqueous/noctalia-plugins"
runtime_root="$source_root/settings"
install -dm755 "$runtime_root/translations"
install -m644 "$plugin_root/catalog.toml" "$source_root/catalog.toml"
install -m644 "$plugin_root/settings/plugin.toml" "$runtime_root/plugin.toml"
install -m644 "$plugin_root/settings/widget.luau" "$runtime_root/widget.luau"
install -m644 "$plugin_root/settings/panel.luau" "$runtime_root/panel.luau"
install -m644 "$plugin_root/settings/translations/en.json" "$runtime_root/translations/en.json"
