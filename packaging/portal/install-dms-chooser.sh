#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${PREFIX:-/usr}
sysconfdir=${SYSCONFDIR:-/etc}
destination=${DESTDIR:-}
bridge=${AQUEOUS_PORTAL_CHOOSER_BINARY:?Set AQUEOUS_PORTAL_CHOOSER_BINARY to the built chooser}

install -Dm755 "$bridge" "$destination$prefix/lib/aqueous/aqueous-dms-portal-chooser"
runtime="$prefix/share/aqueous/dms-plugins/aqueousPortal"
install -d "$destination$runtime"
install -m644 "$root/dms/"*.qml "$root/dms/plugin.json" "$destination$runtime/"
install -d "$destination$sysconfdir/xdg/quickshell/dms-plugins"
ln -sfn "$runtime" "$destination$sysconfdir/xdg/quickshell/dms-plugins/aqueousPortal"
install -d "$destination$sysconfdir/xdg/xdg-desktop-portal-aqueous"
sed "s|/usr/lib/aqueous/aqueous-dms-portal-chooser|$prefix/lib/aqueous/aqueous-dms-portal-chooser|" \
    "$root/dms.conf" > "$destination$sysconfdir/xdg/xdg-desktop-portal-aqueous/config"
chmod 644 "$destination$sysconfdir/xdg/xdg-desktop-portal-aqueous/config"
