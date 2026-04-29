#!/bin/bash
# Launches a nested River session running Aqueous with Noctalia as the bar.
#
# Logs:
#   /tmp/river_log.txt   – River compositor + WAYLAND_DEBUG trace
#   /tmp/aqueous_wm.log  – Aqueous stdout/stderr
#   /tmp/noctalia.log    – Noctalia bar stdout/stderr
dotnet build Aqueous/Aqueous.csproj

# Kill any stale instances from a previous session.
pkill -9 -f 'Aqueous/bin/Debug/net10.0/Aqueous' 2>/dev/null
pkill -9 -f 'qs -c noctalia-shell'                    2>/dev/null
pkill -9 -f '^river '                                  2>/dev/null
sleep 0.3

WM_BIN="$(pwd)/Aqueous/bin/Debug/net10.0/Aqueous"
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

INNER="exec '$WM_BIN' >/tmp/aqueous_wm.log 2>&1"
AQUEOUS_RIVER_WM=1 AQUEOUS_MOD="$AQUEOUS_MOD" AQUEOUS_NESTED="$AQUEOUS_NESTED" WAYLAND_DEBUG=1 \
    river -c "sh -c \"$INNER\"" &>/tmp/river_log.txt
