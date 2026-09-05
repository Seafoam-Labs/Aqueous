#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper=${1:-"$root/../plugin/helper/zig-out/bin/aqueous-config"}
stage=$(mktemp -d /tmp/aqueous-dms-package-test.XXXXXX)
trap 'rm -rf "$stage"' EXIT
for attempt in 1 2; do
    DESTDIR="$stage" PREFIX=/opt/aqueous AQUEOUS_CONFIG_BINARY="$helper" "$root/packaging/install.sh"
done
test -x "$stage/opt/aqueous/bin/aqueous-config"
test "$(readlink "$stage/etc/xdg/quickshell/dms-plugins/aqueousSettings")" = /opt/aqueous/share/aqueous/dms-plugins/aqueousSettings
python3 - "$stage/opt/aqueous/share/aqueous/dms-plugins/aqueousSettings" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); manifest=json.loads((root/'plugin.json').read_text())
for path in [*manifest['components'].values(),manifest['settings'],manifest['startupCheck']]:
    assert (root/path).is_file(),path
assert not (root/'tests').exists()
assert not (root/'PLAN.md').exists()
assert len(list((root/'pages').glob('*.qml'))) == 8
PY
printf '%s\n' 'DMS packaging checks passed.'
