#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper=${1:-"$root/../plugin/helper/zig-out/bin/aqueous-config"}
qml_runner=${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}
qml_format=${QMLFORMAT:-/usr/lib/qt6/bin/qmlformat}
quickshell=${QUICKSHELL:-quickshell}
python3 "$root/tests/test-helper.py" "$helper"
python3 "$root/../plugin/tests/test-modes.py" "$helper"
"$root/tests/test-packaging.sh" "$helper"
python3 - "$root" "$qml_format" <<'PY'
import json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]); manifest=json.loads((root/'plugin.json').read_text())
assert manifest['id']=='aqueousSettings'
assert manifest['type']=='composite'
assert set(manifest['components'])=={'widget','daemon'}
assert 'settings_write' in manifest['permissions']
for path in root.rglob('*.qml'):
    subprocess.run([sys.argv[2],str(path)],stdout=subprocess.DEVNULL,check=True)
print('DMS manifest and QML syntax checks passed.')
PY
QT_QPA_PLATFORM=offscreen "$qml_runner" -input "$root/tests/tst_DraftModel.qml"
# Quickshell's Io plugin is linked into its executable, so run process tests
# through Quickshell instead of qmltestrunner. Stage a self-contained config.
test_root=$(mktemp -d /tmp/aqueous-dms-client.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/services" "$test_root/runtime"
chmod 700 "$test_root/runtime"
cp "$root/services/ConfigClient.qml" "$root/services/Draft.js" "$test_root/services/"
cp "$root/tests/fake-helper.py" "$test_root/"
sed 's|"../services"|"./services"|' "$root/tests/tst_ConfigClient.qml" > "$test_root/shell.qml"
QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR="$test_root/runtime" \
    timeout 20 "$quickshell" -p "$test_root" > "$test_root/log" 2>&1
if ! rg -q 'AQUEOUS_CLIENT_PASS' "$test_root/log" || rg -q 'AQUEOUS_CLIENT_FAIL' "$test_root/log"; then
    cat "$test_root/log" >&2
    exit 1
fi
printf '%s\n' 'DMS asynchronous helper client checks passed.'
