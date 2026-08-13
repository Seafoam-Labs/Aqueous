#!/bin/sh
# Confirm or register and enable the packaged Aqueous Settings plugin once per user.
# Runs as ExecStartPost of noctalia.service, after Noctalia's IPC is ready.
set -u

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/aqueous"
marker="$state_dir/noctalia-settings-enabled-v1"
source_root="/usr/share/aqueous/noctalia-plugins"

mark_enabled() {
    mkdir -p "$state_dir"
    : >"$marker"
    chmod 600 "$marker"
}

plugin_is_enabled() {
    noctalia msg plugins list 2>/dev/null | awk '
        $1 == "aqueous/settings" {
            for (field = 1; field <= NF; field += 1) {
                if ($field == "enabled") {
                    found = 1
                }
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

if [ -e "$marker" ]; then
    exit 0
fi

attempt=0
while [ "$attempt" -lt 20 ]; do
    # Fresh Aqueous profiles enable the plugin in their seeded Noctalia config.
    # Record that state without copying the effective source/plugin lists into
    # Noctalia's GUI-owned settings.toml.
    if plugin_is_enabled; then
        mark_enabled
        exit 0
    fi

    # Compatibility path for profiles created before the packaged defaults
    # included the source and plugin.
    if noctalia msg plugins source add aqueous path "$source_root" >/dev/null 2>&1 &&
        noctalia msg plugins enable aqueous/settings >/dev/null 2>&1; then
        mark_enabled
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

echo "aqueous: could not enable the packaged Noctalia plugin; it will retry next session" >&2
exit 0
