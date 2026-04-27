#!/bin/bash
# Launches a nested River session running Aqueous.WM with Noctalia as the bar.
#
# Logs:
#   /tmp/river_log.txt   – River compositor + WAYLAND_DEBUG trace
#   /tmp/aqueous_wm.log  – Aqueous.WM stdout/stderr
#   /tmp/noctalia.log    – Noctalia bar stdout/stderr
dotnet build Aqueous.WM/Aqueous.WM.csproj

# Kill any stale instances from a previous session.
pkill -9 -f 'Aqueous.WM/bin/Debug/net10.0/Aqueous.WM' 2>/dev/null
pkill -9 -f 'qs -c noctalia-shell'                    2>/dev/null
pkill -9 -f '^river '                                  2>/dev/null
sleep 0.3

WM_BIN="$(pwd)/Aqueous.WM/bin/Debug/net10.0/Aqueous.WM"
BAR_CMD="qs -c noctalia-shell"

# Detect "nested" run: if a host Wayland/X session is already visible, fall
# back to Alt for Aqueous.WM bindings so drag-to-move / resize still work
# while developing from Rider. On a real TTY we keep Super.
if [ -n "$WAYLAND_DISPLAY" ] || [ -n "$DISPLAY" ]; then
    export AQUEOUS_MOD="Alt"
    export AQUEOUS_NESTED=1
else
    export AQUEOUS_MOD="Super"
    export AQUEOUS_NESTED=0
fi
echo "[launch_river] AQUEOUS_NESTED=$AQUEOUS_NESTED AQUEOUS_MOD=$AQUEOUS_MOD"

INNER="'$WM_BIN' >/tmp/aqueous_wm.log 2>&1 & sleep 1; exec $BAR_CMD >/tmp/noctalia.log 2>&1"
AQUEOUS_RIVER_WM=1 AQUEOUS_MOD="$AQUEOUS_MOD" AQUEOUS_NESTED="$AQUEOUS_NESTED" WAYLAND_DEBUG=1 \
    river -c "sh -c \"$INNER\"" &>/tmp/river_log.txt
