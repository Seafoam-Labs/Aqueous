#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD
plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${PREFIX:-/usr}
destination=${DESTDIR:-}
sysconfdir=${SYSCONFDIR:-/etc}
helper=${AQUEOUS_CONFIG_BINARY:-}
if [[ -z "$helper" ]]; then
    cache_root=${AQUEOUS_PLUGIN_CACHE_ROOT:-/tmp/aqueous-dms-package-cache}
    env -u DESTDIR ZIG_GLOBAL_CACHE_DIR="$cache_root/global" ZIG_LOCAL_CACHE_DIR="$cache_root/local" \
        zig build --build-file "$plugin_root/../plugin/helper/build.zig" -Doptimize=ReleaseSafe
    helper="$plugin_root/../plugin/helper/zig-out/bin/aqueous-config"
fi
install -Dm755 "$helper" "$destination$prefix/bin/aqueous-config"
runtime="$destination$prefix/share/aqueous/dms-plugins/aqueousSettings"
install -dm755 "$runtime"
install -m644 "$plugin_root/plugin.json" "$plugin_root/"*.qml "$runtime/"
for dir in components controls pages services translations; do
    install -dm755 "$runtime/$dir"
    while IFS= read -r -d '' file; do install -m644 "$file" "$runtime/$dir/"; done < <(find "$plugin_root/$dir" -maxdepth 1 -type f -print0)
done
# DMS 1.6.0 discovers system plugins here. The link target excludes DESTDIR.
install -dm755 "$destination$sysconfdir/xdg/quickshell/dms-plugins"
ln -sfn "$prefix/share/aqueous/dms-plugins/aqueousSettings" \
    "$destination$sysconfdir/xdg/quickshell/dms-plugins/aqueousSettings"
