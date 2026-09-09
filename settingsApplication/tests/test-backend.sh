#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
driver=${1:-$root/zig-out/bin/aqueous-backend-test}
[[ -x "$driver" ]] || { echo 'Build the test-driver target before running backend regressions.' >&2; exit 1; }
export GSETTINGS_BACKEND=memory
bash "$root/tests/backend/test-config.sh" "$driver"
python3 "$root/tests/backend/test-dms.py" "$driver"
python3 "$root/tests/test-integration.py" "$driver"
python3 "$root/tests/test-reload.py" "$driver"
