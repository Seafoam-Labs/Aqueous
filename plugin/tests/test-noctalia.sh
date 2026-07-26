#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

noctalia plugins lint "$plugin_root/settings"

if [[ ${AQUEOUS_NOCTALIA_LIVE_TEST:-0} != 1 ]]; then
    echo "Noctalia offline validation passed (set AQUEOUS_NOCTALIA_LIVE_TEST=1 for a live source test)"
    exit 0
fi

noctalia msg plugins source add aqueous-test path "$plugin_root"
noctalia msg plugins enable aqueous/settings

enabled=0
for _ in $(seq 1 50); do
    if noctalia msg plugins list | rg -q '^aqueous/settings .* enabled(?: |$)'; then
        enabled=1
        break
    fi
    sleep 0.1
done
if [[ $enabled != 1 ]]; then
    echo "Aqueous plugin was discovered but did not finish enabling" >&2
    exit 1
fi

noctalia msg panel-toggle aqueous/settings:panel

echo "Noctalia live source test passed; the settings panel was toggled."
