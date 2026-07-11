#!/bin/sh
# Aqueous session launcher.
# Installed as /usr/bin/aqueous-wm and referenced by the Wayland
# session entry at /usr/share/wayland-sessions/aqueous.desktop.
#
# NOTE: deliberately *not* using `set -e` — a single non-fatal failure
# (e.g. mkdir on an already-correct XDG_RUNTIME_DIR under SDDM) must not
# abort the whole session.

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
# non-reparenting WM (Aqueous + xwayland-satellite included).
export _JAVA_AWT_WM_NONREPARENTING=1

# DO NOT set DISPLAY here — xwayland-satellite owns it and will export the
# correct value once the bridge is up. Setting DISPLAY=:0 collides with
# SDDM's greeter X server and breaks X11 client auth.
unset DISPLAY

# XWayland reads cursor settings only at server startup — set them here so
# X11 apps get a sane cursor on first map.
export XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}"
export XCURSOR_SIZE="${XCURSOR_SIZE:-24}"

export AQUEOUS_MOD="${AQUEOUS_MOD:-Super}"

# Required by the transitional client to attach to Aqueous as the window manager. Without
# this the compositor refuses to attach (see RiverWindowManagerClient)
# and the session ends up as a black screen under sddm/greetd.
export AQUEOUS_RIVER_WM=1
export AQUEOUS_NESTED=0

# Ensure XDG_RUNTIME_DIR exists (greetd/sddm normally provide this via
# pam_systemd). Tolerate failures: under SDDM the directory may already
# exist with strict ownership we cannot chmod.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
[ -d "$XDG_RUNTIME_DIR" ] || mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Redirect stdout/stderr to a per-user log so failures launching from
# sddm/greetd (where there is no attached terminal) are diagnosable.
# Truncate (not append) — XDG_RUNTIME_DIR is tmpfs but auto-login +
# systemd lingering can otherwise grow this without bound.
LOG="$XDG_RUNTIME_DIR/aqueous-wm.log"
exec >"$LOG" 2>&1
echo "[aqueous-wm] $(date -Is) starting uid=$(id -u) greeter=${XDG_GREETER_DATA_DIR:-unknown}"

# NOTE: the Wayland environment (WAYLAND_DISPLAY etc.) is NOT exported into
# systemd --user / D-Bus here — at this point Aqueous has not started yet,
# so WAYLAND_DISPLAY is not valid. That export now happens from
# /usr/bin/aqueous-init once the compositor is up, via `uwsm finalize` (when
# launched under uwsm) or a dbus/systemctl fallback otherwise. This avoids
# pinning a stale/empty WAYLAND_DISPLAY into the user manager.

# Seed user config from the system default if missing. Never overwrite.
cfg="$HOME/.config/aqueous/wm.toml"
if [ ! -f "$cfg" ] && [ -f /etc/xdg/aqueous/wm.toml ]; then
    # Non-fatal: a quirky $HOME/.config (e.g. odd ownership during a
    # greetd autologin handoff) must not abort the whole session. Aqueous
    # will fall back to /etc/xdg/aqueous/wm.toml at runtime.
    install -Dm644 /etc/xdg/aqueous/wm.toml "$cfg" 2>/dev/null || true
fi

# Input configuration (pointer accel, tap-to-click, natural scroll, …)
# is now applied by Aqueous itself over the river_libinput_config_v1
# Wayland protocol; the formerly-required `aqueous-inputd` sidecar has
# been retired.

# Aqueous runs the compositor and applies output configuration natively;
# aqueous-init is its `-c` child and execs `aqueous-wm-client` after exporting
# the live session environment.
#
# Run (not exec) so the EXIT trap fires and we can clean up the input
# daemon. Use absolute path because SDDM session PATH is minimal.
systemctl --user stop aqueous-outputd.service 2>/dev/null || true
/usr/bin/aqueous -c /usr/bin/aqueous-init
status=$?
echo "[aqueous-wm] $(date -Is) aqueous exited status=$status"

# Tear down the graphical session wrapper so everything PartOf/BindsTo
# graphical-session.target (including the portals) stops cleanly.
# BindsTo should already do this, but stop it explicitly for robustness.
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop aqueous-session.target 2>/dev/null || true
fi

exit $status
