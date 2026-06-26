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
#pkill -9 -f 'noctalia'                                 2>/dev/null
#pkill -9 -f '^riverdelta '                             2>/dev/null
sleep 0.3

# Ensure RiverDelta is available. Prefer an explicit override, then the
# locally-built ./bin/riverdelta (built from compositor/ in this repo).
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCAL_RIVER="$HERE/bin/riverdelta"
if [ -n "${AQUEOUS_RIVER_BIN:-}" ] && [ -x "$AQUEOUS_RIVER_BIN" ]; then
    RIVER_BIN="$AQUEOUS_RIVER_BIN"
else
    needs_build=0
    if [ ! -x "$LOCAL_RIVER" ]; then
        needs_build=1
    else
        # Rebuild if any compositor source is newer than the staged binary.
        if [ -n "$(find "$HERE/compositor" \( -name '*.zig' -o -name 'build.zig.zon' \) -newer "$LOCAL_RIVER" -print -quit 2>/dev/null)" ]; then
            needs_build=1
        fi
    fi
    if [ "$needs_build" = "1" ]; then
        echo "[launch_river] Building in-tree RiverDelta from compositor/..."
        RIVERDELTA_OPTIMIZE="${RIVERDELTA_OPTIMIZE:-Debug}" "$HERE/scripts/build-compositor.sh"
    fi
    RIVER_BIN="$LOCAL_RIVER"
fi
echo "[launch_river] Using compositor: $RIVER_BIN"

WM_BIN="$(pwd)/Aqueous/bin/Debug/net10.0/aqueous"
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
# Decide where Aqueous logs go. The file sink is forced so a run always
# produces /tmp/aqueous_wm.log (the WM-side log needed to diagnose the pump
# stall) regardless of how the script was launched. AQUEOUS_LOG_SINK still
# overrides if a caller explicitly wants a different destination.
if [ -n "${AQUEOUS_LOG_SINK:-}" ]; then
    AQ_SINK="$AQUEOUS_LOG_SINK"
else
    AQ_SINK="/tmp/aqueous_wm.log"
fi
echo "[launch_river] Aqueous logs -> $AQ_SINK"
# Surface snap-zone + dispatcher diagnostics by default during smoke runs.
export AQUEOUS_LOG="${AQUEOUS_LOG:-trace}"
# Capture a full managed (CoreCLR) minidump on crash so the off-pump
# wl_proxy_marshal_flags caller can be resolved with `dotnet-dump analyze`
# (clrstack/clrthreads). MiniDumpType=4 = "Full".
export DOTNET_DbgEnableMiniDump=1
export DOTNET_DbgMiniDumpType=4
export DOTNET_DbgMiniDumpName="/tmp/aqueous_coredump.%d.dmp"
# Launch the bar inside the nested compositor (WAYLAND_DISPLAY is only valid
# in River's -c context). Mirrors packaging/noctalia.service's ExecStart for the
# dev workflow, where no systemd user manager is available to start the unit.
NOCTALIA_CMD="${AQUEOUS_NOCTALIA_CMD:-noctalia}"
INNER="setsid -f sh -c '$NOCTALIA_CMD' >/tmp/noctalia.log 2>&1; exec '$WM_BIN' >'$AQ_SINK' 2>&1"
AQUEOUS_RIVER_WM=1 AQUEOUS_MOD="$AQUEOUS_MOD" AQUEOUS_NESTED="$AQUEOUS_NESTED" WAYLAND_DEBUG=1 \
    "$RIVER_BIN" -c "sh -c \"$INNER\"" &>/tmp/river_log.txt
