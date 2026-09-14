#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stage=$(mktemp -d /tmp/aqueous-config-package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
DESTDIR="$stage" PREFIX=/usr "$root/packaging/install.sh"
"$stage/usr/bin/aqueous-config" version --json | python3 -c 'import json,sys; v=json.load(sys.stdin); assert v["ok"] and v["protocol"] == 1 and "shell_none" in v["capabilities"] and "shell_dms" in v["capabilities"]'
for file in bin/aqueous-config bin/aqueousctl share/licenses/aqueous-config/GPL-3.0-only.txt share/doc/aqueous-config/HELPER.md share/doc/aqueous-config/PROTECTED_COLLECTIONS.md share/doc/aqueous-config/DISPLAY_MUTATIONS.md share/doc/aqueous-config/aqueous-config-additions-v1.schema.json; do
    test -s "$stage/usr/$file"
done
for file in bin/aqueous-settings bin/aqueous-backend-test share/applications share/icons share/aqueous share/licenses/aqueous-settings; do
    test ! -e "$stage/usr/$file"
done
test ! -e "$stage/etc"
# Shell compatibility is an explicit backend-only package option.
DESTDIR="$stage/custom" PREFIX=/opt/aqueous SYSCONFDIR=/etc "$root/packaging/install.sh" --with-dms-appearance
test -x "$stage/custom/opt/aqueous/bin/aqueous-config"
test -s "$stage/custom/opt/aqueous/share/aqueous/dms-plugins/aqueousSettingsAppearance/Daemon.qml"
test "$(readlink "$stage/custom/etc/xdg/quickshell/dms-plugins/aqueousSettingsAppearance")" = /opt/aqueous/share/aqueous/dms-plugins/aqueousSettingsAppearance
test ! -e "$stage/custom/opt/aqueous/share/applications"
test ! -e "$stage/custom/opt/aqueous/share/aqueous/settings-application"
printf '%s\n' 'Canonical helper package staging passed (neutral default and optional DMS bridge).'
