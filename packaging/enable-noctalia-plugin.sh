#!/bin/sh
# Register and enable the packaged Aqueous Settings plugin once per user.
# Runs as ExecStartPost of noctalia.service, after Noctalia's IPC is ready.
set -u

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/aqueous"
marker="$state_dir/noctalia-settings-enabled-v1"
source_root="/usr/share/aqueous/noctalia-plugins"

if [ -e "$marker" ]; then
    exit 0
fi

attempt=0
while [ "$attempt" -lt 20 ]; do
    if noctalia msg plugins source add aqueous path "$source_root" >/dev/null 2>&1 &&
        noctalia msg plugins enable aqueous/settings >/dev/null 2>&1; then
        mkdir -p "$state_dir"
        : >"$marker"
        chmod 600 "$marker"
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

echo "aqueous: could not enable the packaged Noctalia plugin; it will retry next session" >&2
exit 0
