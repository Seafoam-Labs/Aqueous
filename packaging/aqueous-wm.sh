#!/bin/sh
# Aqueous session launcher.
# Installed as /usr/bin/aqueous-wm and referenced by the Wayland
# session entry at /usr/share/wayland-sessions/aqueous.desktop.
set -e

export XDG_CURRENT_DESKTOP=Aqueous
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=Aqueous
export QT_QPA_PLATFORM=wayland
export MOZ_ENABLE_WAYLAND=1
export AQUEOUS_MOD="${AQUEOUS_MOD:-Super}"

# Ensure XDG_RUNTIME_DIR exists (greetd normally provides this).
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
[ -d "$XDG_RUNTIME_DIR" ] || mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Seed user config from the system default if missing. Never overwrite.
cfg="$HOME/.config/aqueous/wm.toml"
if [ ! -f "$cfg" ] && [ -f /etc/xdg/aqueous/wm.toml ]; then
    install -Dm644 /etc/xdg/aqueous/wm.toml "$cfg"
fi

# Start the input daemon sidecar if a systemd user unit isn't already
# managing it.
INPUTD_PID=""
cleanup() {
    if [ -n "$INPUTD_PID" ]; then
        kill "$INPUTD_PID" 2>/dev/null || true
    fi
    # Best-effort: kill stragglers spawned by Aqueous via [[exec]] blocks.
    pkill -u "$(id -u)" -x "qs" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if ! systemctl --user is-active --quiet aqueous-inputd.service 2>/dev/null; then
    if [ -x /usr/bin/aqueous-inputd ]; then
        /usr/bin/aqueous-inputd &
        INPUTD_PID=$!
    fi
fi

# River runs the compositor; Aqueous is its init child.
exec river -c '/usr/bin/aqueous'
