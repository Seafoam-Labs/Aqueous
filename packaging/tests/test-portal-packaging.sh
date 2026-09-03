#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
portal_dir="$repo_root/packaging/portal"
binary=${1:-}
portal_exec=${AQUEOUS_PORTAL_EXEC:-/usr/lib/aqueous/xdg-desktop-portal-aqueous}

grep -Fx 'org.freedesktop.impl.portal.ScreenCast=aqueous' \
    "$repo_root/packaging/aqueous-portals.conf" >/dev/null
grep -Fx 'org.freedesktop.impl.portal.Screenshot=aqueous' \
    "$repo_root/packaging/aqueous-portals.conf" >/dev/null
grep -Fx 'DBusName=org.freedesktop.impl.portal.desktop.aqueous' \
    "$portal_dir/aqueous.portal" >/dev/null
grep -Fx 'UseIn=Aqueous' "$portal_dir/aqueous.portal" >/dev/null
grep -Fx 'Name=org.freedesktop.impl.portal.desktop.aqueous' \
    "$portal_dir/org.freedesktop.impl.portal.desktop.aqueous.service" >/dev/null
grep -Fx 'BusName=org.freedesktop.impl.portal.desktop.aqueous' \
    "$portal_dir/xdg-desktop-portal-aqueous.service" >/dev/null
grep -Fx "Exec=$portal_exec" \
    "$portal_dir/org.freedesktop.impl.portal.desktop.aqueous.service" >/dev/null
grep -Fx 'SystemdService=xdg-desktop-portal-aqueous.service' \
    "$portal_dir/org.freedesktop.impl.portal.desktop.aqueous.service" >/dev/null
grep -Fx "ExecStart=$portal_exec" \
    "$portal_dir/xdg-desktop-portal-aqueous.service" >/dev/null

if grep -R -E 'desktop\.wlr|ScreenCast=wlr|Screenshot=wlr' \
    "$repo_root/packaging/aqueous-portals.conf" \
    "$portal_dir/aqueous.portal" \
    "$portal_dir/org.freedesktop.impl.portal.desktop.aqueous.service" \
    "$portal_dir/xdg-desktop-portal-aqueous.service"; then
    echo 'Aqueous portal metadata still refers to the wlr backend identity' >&2
    exit 1
fi

if [[ -n $binary ]]; then
    [[ -x $binary ]] || {
        echo "portal binary is not executable: $binary" >&2
        exit 1
    }
    strings "$binary" | grep -F \
        'org.freedesktop.impl.portal.desktop.aqueous' >/dev/null
    strings "$binary" | grep -F \
        'XDG_CONFIG_HOME/xdg-desktop-portal-aqueous/config' >/dev/null
    if strings "$binary" | grep -E \
        'org\.freedesktop\.impl\.portal\.desktop\.wlr|XDG_CONFIG_HOME/xdg-desktop-portal-wlr/config'; then
        echo 'portal binary still contains the wlr backend identity' >&2
        exit 1
    fi
fi

echo 'Aqueous portal packaging tests passed'
