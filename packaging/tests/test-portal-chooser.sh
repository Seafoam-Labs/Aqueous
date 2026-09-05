#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bridge=${1:?Pass the built aqueous-dms-portal-chooser}
python3 "$root/packaging/tests/test-portal-bridge.py" "$bridge"
QT_QPA_PLATFORM=offscreen "${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}" \
    -input "$root/packaging/tests/tst_PortalModel.qml"
for file in "$root/packaging/portal/dms/"*.qml; do
    "${QMLFORMAT:-/usr/lib/qt6/bin/qmlformat}" "$file" >/dev/null
done
stage=$(mktemp -d /tmp/aqueous-portal-package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
AQUEOUS_PORTAL_CHOOSER_BINARY="$bridge" DESTDIR="$stage" \
    sh "$root/packaging/portal/install-dms-chooser.sh"
"$root/packaging/tests/test-portal-packaging.sh" '' "$stage" dms
# Exercise relocation separately: build roots must not leak into installed paths.
AQUEOUS_PORTAL_CHOOSER_BINARY="$bridge" DESTDIR="$stage/relocated" PREFIX=/opt/aqueous SYSCONFDIR=/etc \
    sh "$root/packaging/portal/install-dms-chooser.sh"
test "$(readlink "$stage/relocated/etc/xdg/quickshell/dms-plugins/aqueousPortal")" = \
    /opt/aqueous/share/aqueous/dms-plugins/aqueousPortal
test -x "$stage/relocated/opt/aqueous/lib/aqueous/aqueous-dms-portal-chooser"
grep -Fx 'chooser_cmd=/opt/aqueous/lib/aqueous/aqueous-dms-portal-chooser' \
    "$stage/relocated/etc/xdg/xdg-desktop-portal-aqueous/config" >/dev/null
echo 'DMS portal chooser packaging and relocation passed'
