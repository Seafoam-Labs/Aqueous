#!/bin/sh
# Aqueous session launcher.
# Installed as /usr/bin/aqueous-wm and referenced by the Wayland
# session entry at /usr/share/wayland-sessions/aqueous.desktop.
set -e

export XDG_CURRENT_DESKTOP=Aqueous
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=Aqueous

# Toolkit backend hints. Apps prefer Wayland and only fall back to X11 (via
# xwayland-satellite, which Aqueous spawns from wm.toml's [[exec]] block) when
# the native Wayland path is unavailable.
export QT_QPA_PLATFORM="wayland;xcb"
export GDK_BACKEND="wayland,x11"
export SDL_VIDEODRIVER="wayland,x11"
export CLUTTER_BACKEND=wayland
export MOZ_ENABLE_WAYLAND=1
# Fixes the grey-blob / non-reparenting Java/Swing/JetBrains bug under any
# non-reparenting WM (RiverDelta + xwayland-satellite included).
export _JAVA_AWT_WM_NONREPARENTING=1

# DISPLAY for the rootless XWayland bridge. xwayland-satellite is launched by
# Aqueous via [[exec]] in wm.toml; X11 clients spawned by the session connect
# to this socket. Keep in sync with the satellite's command-line argument.
export DISPLAY="${DISPLAY:-:0}"

# XWayland reads cursor settings only at server startup — set them here so
# X11 apps get a sane cursor on first map.
export XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}"
export XCURSOR_SIZE="${XCURSOR_SIZE:-24}"

export AQUEOUS_MOD="${AQUEOUS_MOD:-Super}"

# Required by Aqueous to attach to RiverDelta as the window manager. Without
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

# RiverDelta runs the compositor; aqueous-init is its `-c` child. The init
# wrapper then runs `aqueous-outputd --apply-once` (fixes greetd's
# inability to set the render size before the session starts) and
# spawns the long-running daemon, before exec'ing Aqueous itself.
exec riverdelta -c '/usr/bin/aqueous-init'
