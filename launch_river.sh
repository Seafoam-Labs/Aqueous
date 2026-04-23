#!/bin/bash
# Automatically generated launch script for Rider
dotnet build

# This script launches a nested River session running Aqueous.WM and Aqueous.
#
# WAYLAND_DEBUG=1 floods stderr. When this script is run from a terminal or
# Rider's Run console that drains stderr slowly, the kernel pipe fills up and
# every client — including the Aqueous bar — blocks inside write(2) on its
# log path. That stalls surface commits and the nested River window stays
# black. Route the protocol trace to a file so nothing ever blocks, and give
# the WM and bar their own logs so a noisy client can't wedge the other.
#
# Logs:
#   /tmp/river_log.txt    – River compositor + full WAYLAND_DEBUG trace
#   /tmp/aqueous_wm.log   – Aqueous.WM stdout/stderr
#   /tmp/aqueous_bar.log  – Aqueous bar stdout/stderr (look here for GTK errors)

# Kill any stale Aqueous / River instances from a previous session before
# launching. If a previous bar is still alive on the host session bus, it owns
# the `com.example.aqueous` GApplication name; the new (nested) bar then
# deduplicates into it via D-Bus, forwards its Activate call to the stale
# process, and exits cleanly without ever running OnActivate — which is
# exactly the "nested River window stays black" symptom. Clearing stale
# instances here guarantees the nested bar always becomes its own primary.
pkill -9 -f 'Aqueous.WM/bin/Debug/net10.0/Aqueous.WM' 2>/dev/null
pkill -9 -f 'Aqueous/bin/Debug/net10.0/Aqueous$'      2>/dev/null
pkill -9 -f '^river '                                  2>/dev/null
sleep 0.3

WM_BIN="$(pwd)/Aqueous.WM/bin/Debug/net10.0/Aqueous.WM"
BAR_BIN="$(pwd)/Aqueous/bin/Debug/net10.0/Aqueous"

INNER="'$WM_BIN' >/tmp/aqueous_wm.log 2>&1 & sleep 1; exec '$BAR_BIN' >/tmp/aqueous_bar.log 2>&1"

AQUEOUS_RIVER_WM=1 WAYLAND_DEBUG=1 \
    river -c "sh -c \"$INNER\"" &>/tmp/river_log.txt
