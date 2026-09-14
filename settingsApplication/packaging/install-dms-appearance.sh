#!/usr/bin/env bash
# Optional backend typography bridge. No settings UI or palette templates.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${PREFIX:-/usr}
destination=${DESTDIR:-}
bridge="$destination$prefix/share/aqueous/dms-plugins/aqueousSettingsAppearance"
install -dm755 "$bridge"
install -m644 "$root/packaging/dms-appearance/"* "$bridge/"
discovery=${AQUEOUS_CONFIG_BRIDGE_DISCOVERY:-${SYSCONFDIR:-/etc}/xdg/quickshell/dms-plugins}
install -dm755 "$destination$discovery"
ln -sfn "$prefix/share/aqueous/dms-plugins/aqueousSettingsAppearance" "$destination$discovery/aqueousSettingsAppearance"
