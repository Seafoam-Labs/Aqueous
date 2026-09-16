#!/bin/bash
# Launches an in-tree Aqueous session with the Pearl shell integration.
#
# Logs:
#   /tmp/aqueous.log     – Aqueous compositor/policy log
#   /tmp/pearl.log       – Pearl stdout/stderr
set -euo pipefail

fail() { echo "[launch_aqueous] $*" >&2; exit 1; }

# The Pearl connector package is an integration preset, not a separate daemon.
# Start Pearl directly as the compositor's init child for this development
# session. Packaged systemd units deliberately skip nested sessions.
if [ -z "${AQUEOUS_PEARL_CMD:-}" ]; then
    if command -v pearl >/dev/null 2>&1; then
        AQUEOUS_PEARL_CMD='exec pearl'
    elif command -v pearl-git >/dev/null 2>&1; then
        AQUEOUS_PEARL_CMD='exec pearl-git'
    else
        fail 'Pearl is missing. Install pearl or pearl-git, or set AQUEOUS_PEARL_CMD.'
    fi
fi
export AQUEOUS_PEARL_CMD

# Ensure Aqueous is available. Prefer an explicit override, then the
# locally-built ./bin/aqueous (built from compositor/ in this repo).
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCAL_COMPOSITOR="$HERE/bin/aqueous"
if [ -n "${AQUEOUS_COMPOSITOR_BIN:-}" ]; then
    [ -x "$AQUEOUS_COMPOSITOR_BIN" ] || fail "Compositor is not executable: $AQUEOUS_COMPOSITOR_BIN"
    COMPOSITOR_BIN="$AQUEOUS_COMPOSITOR_BIN"
else
    needs_build=0
    if [ ! -x "$LOCAL_COMPOSITOR" ] || [ ! -f "$HERE/lib/aqueous/libwlroots-0.20.so" ]; then
        needs_build=1
    else
        # Include native sources, protocols and dependency patches. Ignore
        # generated output and caches when deciding whether staging is stale.
        if [ "$HERE/scripts/build-compositor.sh" -nt "$LOCAL_COMPOSITOR" ] ||
            [ -n "$(find "$HERE/compositor" \
                \( -name .deps -o -name .zig-cache -o -name zig-out \) -prune -o \
                -type f \( -name '*.zig' -o -name '*.zon' -o -name '*.c' -o -name '*.h' \
                    -o -name '*.xml' -o -name '*.patch' -o -name '*.sh' \) \
                -newer "$LOCAL_COMPOSITOR" -print -quit)" ]; then
            needs_build=1
        fi
    fi
    if [ "$needs_build" = "1" ]; then
        echo "[launch_aqueous] Building in-tree Aqueous from compositor/..."
        AQUEOUS_OPTIMIZE="${AQUEOUS_OPTIMIZE:-Debug}" "$HERE/scripts/build-compositor.sh"
    fi
    COMPOSITOR_BIN="$LOCAL_COMPOSITOR"
fi
COMPOSITOR_BIN="$(readlink -f -- "$COMPOSITOR_BIN")"
echo "[launch_aqueous] Using compositor: $COMPOSITOR_BIN"

# Keep control commands and wlroots paired with the selected compositor. The
# host session may export LD_LIBRARY_PATH pointing at an older installed build.
COMPOSITOR_DIR="$(dirname -- "$COMPOSITOR_BIN")"
export PATH="$COMPOSITOR_DIR:$PATH"
if [ -f "$COMPOSITOR_DIR/../lib/aqueous/libwlroots-0.20.so" ]; then
    export LD_LIBRARY_PATH="$COMPOSITOR_DIR/../lib/aqueous${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Detect "nested" run: if a host Wayland/X session is already visible, fall
# back to Alt for Aqueous bindings so drag-to-move / resize still work
# while developing from Rider. On a real TTY we keep Super.
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
    export AQUEOUS_MOD="Alt"
    export AQUEOUS_NESTED=1
else
    export AQUEOUS_MOD="Super"
    export AQUEOUS_NESTED=0
fi
echo "[launch_aqueous] AQUEOUS_NESTED=$AQUEOUS_NESTED AQUEOUS_MOD=$AQUEOUS_MOD"

# Pearl validates the desktop identity as well as the compositor's live IPC
# endpoint. These exports affect only this session and its children.
export XDG_CURRENT_DESKTOP=Aqueous
export XDG_SESSION_DESKTOP=aqueous
export XDG_SESSION_TYPE=wayland

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
# and arguments in overrides. Pearl connects using this live environment.
export AQUEOUS_PEARL_LOG_SINK="${AQUEOUS_PEARL_LOG_SINK:-/tmp/pearl.log}"
echo "[launch_aqueous] Pearl command: $AQUEOUS_PEARL_CMD"
echo "[launch_aqueous] Pearl logs -> $AQUEOUS_PEARL_LOG_SINK"
exec "$COMPOSITOR_BIN" -log-level debug \
    -c 'exec sh -c "$AQUEOUS_PEARL_CMD" >"$AQUEOUS_PEARL_LOG_SINK" 2>&1' >"$AQ_SINK" 2>&1
