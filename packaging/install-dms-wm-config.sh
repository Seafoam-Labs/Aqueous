#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${DESTDIR:-}
prefix=${PREFIX:-/usr}
sysconfdir=${SYSCONFDIR:-/etc}

# Only transform package defaults. Existing user configuration stays user-owned.
for target in "$destination$sysconfdir/xdg/aqueous/wm.toml" \
    "$destination$prefix/share/aqueous/wm.toml"; do
    install -d "$(dirname -- "$target")"
    sed -e 's/noctalia msg panel-toggle launcher/dms ipc call spotlight toggle/g' \
        -e 's/noctalia msg screenshot-region/dms screenshot region/g' \
        -e 's/Noctalia bar height/DMS bar height/g' \
        "$root/wm.toml" > "$target"
    chmod 644 "$target"
done
