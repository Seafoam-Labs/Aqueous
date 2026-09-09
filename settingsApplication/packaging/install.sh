#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${PREFIX:-/usr}
destination=${DESTDIR:-}
app=${AQUEOUS_SETTINGS_BINARY:-$root/zig-out/bin/aqueous-settings}
[[ -x "$app" ]] || { echo 'Build aqueous-settings before installing.' >&2; exit 1; }
install -Dm755 "$app" "$destination$prefix/bin/aqueous-settings"
install -Dm644 "$root/packaging/org.aqueous.Settings.desktop" "$destination$prefix/share/applications/org.aqueous.Settings.desktop"
install -Dm644 "$root/assets/org.aqueous.Settings.svg" "$destination$prefix/share/icons/hicolor/scalable/apps/org.aqueous.Settings.svg"
bridge="$destination$prefix/share/aqueous/dms-plugins/aqueousSettingsAppearance"
install -dm755 "$bridge"
install -m644 "$root/packaging/dms-appearance/"* "$bridge/"
# Stage optional shell integration; enabling it remains a user preference.
discovery=${AQUEOUS_SETTINGS_BRIDGE_DISCOVERY:-${SYSCONFDIR:-/etc}/xdg/quickshell/dms-plugins}
install -dm755 "$destination$discovery"
ln -sfn "$prefix/share/aqueous/dms-plugins/aqueousSettingsAppearance" "$destination$discovery/aqueousSettingsAppearance"
install -Dm644 "$root/quark/LICENSE" "$destination$prefix/share/licenses/aqueous-settings/quark-LICENSE"
install -Dm644 "$root/quark/README.md" "$destination$prefix/share/licenses/aqueous-settings/quark-SOURCE.md"
install -Dm644 "$root/quark/prepare.py" "$destination$prefix/share/aqueous/settings-application/quark/prepare.py"
