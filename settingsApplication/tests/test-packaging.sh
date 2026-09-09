#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stage=$(mktemp -d /tmp/aqueous-settings-package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
DESTDIR="$stage" PREFIX=/usr "$root/packaging/install.sh"
"$stage/usr/bin/aqueous-settings" --version
for file in bin/aqueous-settings share/applications/org.aqueous.Settings.desktop share/icons/hicolor/scalable/apps/org.aqueous.Settings.svg share/aqueous/dms-plugins/aqueousSettingsAppearance/Daemon.qml share/licenses/aqueous-settings/quark-LICENSE; do
    test -f "$stage/usr/$file"
done
test ! -e "$stage/usr/bin/aqueous-config"
test ! -e "$stage/usr/bin/aqueous-backend-test"
test ! -e "$stage/usr/share/aqueous/dms-plugins/aqueousSettings"
test ! -e "$stage/usr/share/aqueous/noctalia-plugins"
for file in dms.json.in noctalia.json.in dms.toml.example noctalia.toml.example README.md; do
    test -s "$stage/usr/share/aqueous/settings-application/themes/$file"
done
test "$(readlink "$stage/etc/xdg/quickshell/dms-plugins/aqueousSettingsAppearance")" = /usr/share/aqueous/dms-plugins/aqueousSettingsAppearance
if command -v desktop-file-validate >/dev/null; then desktop-file-validate "$stage/usr/share/applications/org.aqueous.Settings.desktop"; fi
printf '%s\n' 'Settings package staging passed.'
