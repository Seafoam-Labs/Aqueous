#!/bin/bash
# Launches a nested single-process Aqueous session with Noctalia as the bar.
#
# Logs:
#   /tmp/aqueous.log     – Aqueous compositor/policy log
#   /tmp/noctalia.log    – Noctalia bar stdout/stderr

# Ensure Aqueous is available. Prefer an explicit override, then the
# locally-built ./bin/aqueous (built from compositor/ in this repo).
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCAL_COMPOSITOR="$HERE/bin/aqueous"
if [ -n "${AQUEOUS_COMPOSITOR_BIN:-}" ] && [ -x "$AQUEOUS_COMPOSITOR_BIN" ]; then
    COMPOSITOR_BIN="$AQUEOUS_COMPOSITOR_BIN"
else
    needs_build=0
    if [ ! -x "$LOCAL_COMPOSITOR" ]; then
        needs_build=1
    else
        # Rebuild if any compositor source is newer than the staged binary.
        if [ -n "$(find "$HERE/compositor" \( -name '*.zig' -o -name 'build.zig.zon' \) -newer "$LOCAL_COMPOSITOR" -print -quit 2>/dev/null)" ]; then
            needs_build=1
        fi
    fi
    if [ "$needs_build" = "1" ]; then
        echo "[launch_river] Building in-tree Aqueous from compositor/..."
        AQUEOUS_OPTIMIZE="${AQUEOUS_OPTIMIZE:-Debug}" "$HERE/scripts/build-compositor.sh"
    fi
    COMPOSITOR_BIN="$LOCAL_COMPOSITOR"
fi
echo "[launch_river] Using compositor: $COMPOSITOR_BIN"

# NOTE: in a packaged session Noctalia is launched as a systemd user unit
# (packaging/noctalia.service, ordered Before=xdg-desktop-autostart.target) so
# its SNI tray watcher is up before any autostart tray app — it is no longer an
# [[exec]] block in wm.toml. There is no user systemd manager inside this nested
# dev run, so we launch the bar here instead. The pre-kill above stays — Aqueous
# is not running yet at that point, so a stale Noctalia from a previous crash
# still needs to be reaped before Aqueous claims ownership.

# Detect "nested" run: if a host Wayland/X session is already visible, fall
# back to Alt for Aqueous bindings so drag-to-move / resize still work
# while developing from Rider. On a real TTY we keep Super.
if [ -n "$WAYLAND_DISPLAY" ] || [ -n "$DISPLAY" ]; then
    export AQUEOUS_MOD="Alt"
    export AQUEOUS_NESTED=1
else
    export AQUEOUS_MOD="Super"
    export AQUEOUS_NESTED=0
fi
echo "[launch_river] AQUEOUS_NESTED=$AQUEOUS_NESTED AQUEOUS_MOD=$AQUEOUS_MOD"

# Aqueous creates XWayland through wlroots and exports its allocated DISPLAY
# to the session init command and all compositor-spawned children. Preserve a
# host DISPLAY here only when it is needed to run Aqueous nested on an X11
# backend; never guess :0 for the inner session.
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
export GDK_BACKEND="${GDK_BACKEND:-wayland,x11}"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland,x11}"
export MOZ_ENABLE_WAYLAND="${MOZ_ENABLE_WAYLAND:-1}"
export _JAVA_AWT_WM_NONREPARENTING=1
# Decide where Aqueous logs go.
if [ -n "${AQUEOUS_LOG_SINK:-}" ]; then
    AQ_SINK="$AQUEOUS_LOG_SINK"
else
    AQ_SINK="/tmp/aqueous.log"
fi
echo "[launch_river] Aqueous logs -> $AQ_SINK"
# Launch the bar inside the nested compositor (WAYLAND_DISPLAY is only valid
# in River's -c context). Mirrors packaging/noctalia.service's ExecStart for the
# dev workflow, where no systemd user manager is available to start the unit.
NOCTALIA_CMD="${AQUEOUS_NOCTALIA_CMD:-noctalia}"
INNER="'$NOCTALIA_CMD' >/tmp/noctalia.log 2>&1 & wait"
AQUEOUS_MOD="$AQUEOUS_MOD" AQUEOUS_NESTED="$AQUEOUS_NESTED" \
    "$COMPOSITOR_BIN" -log-level debug -c "sh -c \"$INNER\"" >"$AQ_SINK" 2>&1
