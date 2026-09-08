#!/bin/bash
# Launches a nested single-process Aqueous session with DankMaterialShell.
#
# Logs:
#   /tmp/aqueous.log     – Aqueous compositor/policy log
#   /tmp/dms.log         – DMS stdout/stderr

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
        echo "[launch_aqueous] Building in-tree Aqueous from compositor/..."
        AQUEOUS_OPTIMIZE="${AQUEOUS_OPTIMIZE:-Debug}" "$HERE/scripts/build-compositor.sh"
    fi
    COMPOSITOR_BIN="$LOCAL_COMPOSITOR"
fi
echo "[launch_aqueous] Using compositor: $COMPOSITOR_BIN"

# Packaged sessions start DMS through a systemd user unit. Launch it directly
# for this development session so it receives the nested compositor's display.

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
echo "[launch_aqueous] AQUEOUS_NESTED=$AQUEOUS_NESTED AQUEOUS_MOD=$AQUEOUS_MOD"

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
echo "[launch_aqueous] Aqueous logs -> $AQ_SINK"
# Aqueous runs -c through sh after exporting the inner WAYLAND_DISPLAY and
# AQUEOUS_SOCKET. Pass the command through the environment to preserve quoting
# and arguments in overrides. --session is reserved for service-managed DMS.
export AQUEOUS_DMS_CMD="${AQUEOUS_DMS_CMD:-dms run}"
echo "[launch_aqueous] DMS logs -> /tmp/dms.log"
AQUEOUS_MOD="$AQUEOUS_MOD" AQUEOUS_NESTED="$AQUEOUS_NESTED" \
    "$COMPOSITOR_BIN" -log-level debug -c 'exec sh -c "$AQUEOUS_DMS_CMD" >/tmp/dms.log 2>&1' >"$AQ_SINK" 2>&1
