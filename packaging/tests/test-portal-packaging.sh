#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
portal_dir="$repo_root/packaging/portal"
binary=${1:-}
stage=${2:-}
shell=${3:-noctalia}
portal_exec=${AQUEOUS_PORTAL_EXEC:-/usr/lib/aqueous/xdg-desktop-portal-aqueous}

python3 - "$portal_dir" "$stage" "$shell" <<'PY'
import configparser, json, pathlib, shlex, sys
root, stage, shell = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
assert shell in ('noctalia', 'dms')
for variant in ('noctalia', 'dms'):
    config = configparser.ConfigParser(interpolation=None)
    config.read(root / (variant + '.conf'))
    assert config['screencast']['chooser_type'] == 'dmenu'
    command = shlex.split(config['screencast']['chooser_cmd'])
    if variant == 'noctalia':
        assert command == ['noctalia', 'dmenu', '-p', 'Select a source to share:']
    else:
        assert command == ['/usr/lib/aqueous/aqueous-dms-portal-chooser']
if stage:
    stage = pathlib.Path(stage)
    config_path = stage / 'etc/xdg/xdg-desktop-portal-aqueous/config'
    assert config_path.read_bytes() == (root / (shell + '.conf')).read_bytes()
    if shell == 'dms':
        runtime = 'usr/share/aqueous/dms-plugins/aqueousPortal'
        manifest = json.loads((stage / runtime / 'plugin.json').read_text())
        assert manifest['id'] == 'aqueousPortal' and manifest['type'] == 'daemon'
        assert manifest['requires_dms'] == '>=1.7.0'
        assert (stage / runtime / manifest['component']).is_file()
        assert (stage / 'usr/lib/aqueous/aqueous-dms-portal-chooser').stat().st_mode & 0o111
        link = stage / 'etc/xdg/quickshell/dms-plugins/aqueousPortal'
        assert str(link.readlink()) == '/' + runtime
        assert not (stage / 'usr/share/aqueous/dms-plugins/aqueousSettings').exists()
print('Portal chooser configuration checks passed')
PY

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
    python3 "$repo_root/packaging/tests/test-portal-config.py" "$binary"
fi

echo 'Aqueous portal packaging tests passed'
