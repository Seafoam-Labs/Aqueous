#!/bin/bash
# Launches a nested River session running Aqueous with Noctalia as the bar.
#
# Logs:
#   /tmp/river_log.txt   – River compositor + WAYLAND_DEBUG trace
#   /tmp/aqueous_wm.log  – Aqueous stdout/stderr
#   /tmp/noctalia.log    – Noctalia bar stdout/stderr
dotnet build Aqueous/Aqueous.csproj

# Kill any stale instances from a previous session.
pkill -9 -f 'Aqueous/bin/Debug/net10.0/aqueous' 2>/dev/null
pkill -9 -f 'qs -c noctalia-shell'                    2>/dev/null
pkill -9 -f '^riverdelta '                             2>/dev/null
sleep 0.3

# Ensure RiverDelta is available
if ! command -v riverdelta &>/dev/null && [ ! -f "./bin/riverdelta" ]; then
    echo "[launch_river] riverdelta not found in PATH or ./bin/. Attempting to build..."
    RD_SRC="../RiverDelta"
    if [ ! -d "$RD_SRC" ]; then
        echo "[launch_river] Cloning RiverDelta to $RD_SRC..."
        git clone https://github.com/Seafoam-Labs/RiverDelta.git "$RD_SRC"
    fi

    echo "[launch_river] Building RiverDelta..."
    (cd "$RD_SRC" && zig build -Doptimize=ReleaseSafe -Dxwayland)

    mkdir -p ./bin
    cp "$RD_SRC/zig-out/bin/river" ./bin/riverdelta
    echo "[launch_river] RiverDelta built and placed in ./bin/riverdelta"
fi

RIVER_BIN=$(command -v riverdelta || echo "$(pwd)/bin/riverdelta")
echo "[launch_river] Using compositor: $RIVER_BIN"

WM_BIN="$(pwd)/Aqueous/bin/Debug/net10.0/aqueous"
# NOTE: the bar (qs -c noctalia-shell) is now launched by Aqueous itself
# via the [[exec]] section in wm.toml. The pre-kill above stays — Aqueous
# is not running yet at that point, so a stale Noctalia from a previous
# crash still needs to be reaped before Aqueous claims ownership.

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

# XWayland session env. xwayland-satellite is started by Aqueous itself via
# the [[exec]] block in wm.toml; here we only export the env vars that X11
# clients need to find the bridge and that toolkits read at startup. In a
# nested run we do NOT clobber a pre-existing DISPLAY (that would point X11
# clients spawned inside the nested River at the host's X server, which is
# almost never what we want for testing).
if [ "$AQUEOUS_NESTED" = "0" ]; then
    export DISPLAY=":0"
fi
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
export GDK_BACKEND="${GDK_BACKEND:-wayland,x11}"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland,x11}"
export MOZ_ENABLE_WAYLAND="${MOZ_ENABLE_WAYLAND:-1}"
export _JAVA_AWT_WM_NONREPARENTING=1

INNER="exec '$WM_BIN' >/tmp/aqueous_wm.log 2>&1"
AQUEOUS_RIVER_WM=1 AQUEOUS_MOD="$AQUEOUS_MOD" AQUEOUS_NESTED="$AQUEOUS_NESTED" WAYLAND_DEBUG=1 \
    "$RIVER_BIN" -c "sh -c \"$INNER\"" &>/tmp/river_log.txt
