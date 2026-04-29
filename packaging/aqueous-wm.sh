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

# Required by Aqueous to attach to River as the window manager. Without
# this the compositor refuses to attach (see RiverWindowManagerClient)
# and the session ends up as a black screen under sddm/greetd.
export AQUEOUS_RIVER_WM=1
export AQUEOUS_NESTED=0

# Ensure XDG_RUNTIME_DIR exists (greetd normally provides this).
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
[ -d "$XDG_RUNTIME_DIR" ] || mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Redirect stdout/stderr to a per-user log so failures launching from
# sddm/greetd (where there is no attached terminal) are diagnosable.
# `journalctl --user` typically won't capture this since the session is
# not started by systemd --user; the file is the source of truth.
exec >>"$XDG_RUNTIME_DIR/aqueous-wm.log" 2>&1
echo "[aqueous-wm] $(date -Is) starting (uid=$(id -u) DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-})"

# Seed user config from the system default if missing. Never overwrite.
cfg="$HOME/.config/aqueous/wm.toml"
if [ ! -f "$cfg" ] && [ -f /etc/xdg/aqueous/wm.toml ]; then
    # Non-fatal: a quirky $HOME/.config (e.g. odd ownership during a
    # greetd autologin handoff) must not abort the whole session. Aqueous
    # will fall back to /etc/xdg/aqueous/wm.toml at runtime.
    install -Dm644 /etc/xdg/aqueous/wm.toml "$cfg" || true
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
