#!/usr/bin/env bash
set -euo pipefail

# Regression for workspace floating-layout ownership. Ordinary policy-tiled
# windows must cascade, remember client move/resize geometry across layout
# switches, and only become persistent overlays after an explicit toggle.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/xdg-floating-request.c"
CONFIG="$here/scripts/fixtures/floating-layout-wm.toml"
RULES="$here/scripts/fixtures/floating-layout-rules.toml"
PROTOCOLS="$(pkg-config --variable=pkgdatadir wayland-protocols)"
XDG_SHELL_PROTOCOL="$PROTOCOLS/stable/xdg-shell/xdg-shell.xml"
VIRTUAL_POINTER_PROTOCOL="$here/protocol/upstream/wlr-virtual-pointer-unstable-v1.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for file in "$FIXTURE_SOURCE" "$CONFIG" "$RULES" "$VIRTUAL_POINTER_PROTOCOL"; do
    [ -r "$file" ] || die "missing fixture input $file"
done
for tool in cc jq pkg-config timeout wayland-scanner wlrctl; do
    have "$tool" || die "$tool is required for floating-layout integration tests"
done
pkg-config --exists wayland-client wayland-protocols ||
    die "Wayland client development files and protocols are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-floating-layout.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
FIXTURE_BIN="$TEST_ROOT/xdg-floating-request"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
CLIENT_PIDS=()
CLIENT_SYNCS=()
CLIENT_LOGS=()
STARTED_PID=""

cleanup() {
    for sync_dir in "${CLIENT_SYNCS[@]}"; do touch "$sync_dir/finish" 2>/dev/null || true; done
    for pid in "${CLIENT_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${CLIENT_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    if [ "${AQUEOUS_KEEP_TEST_ROOT:-0}" = 1 ]; then
        echo "kept floating-layout test artifacts at $TEST_ROOT" >&2
    else
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT

wayland-scanner client-header "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-client-protocol.h"
wayland-scanner private-code "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-protocol.c"
wayland-scanner client-header "$VIRTUAL_POINTER_PROTOCOL" \
    "$TEST_ROOT/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code "$VIRTUAL_POINTER_PROTOCOL" \
    "$TEST_ROOT/wlr-virtual-pointer-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" \
    "$TEST_ROOT/xdg-shell-protocol.c" \
    "$TEST_ROOT/wlr-virtual-pointer-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"
WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$CONFIG" \
AQUEOUS_RULES="$RULES" \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -policy internal -log-level debug -c true \
    >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -120 "$COMPOSITOR_LOG" >&2
        die "compositor failed during startup"
    }
    socket=$(find "$RUNTIME" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -n "$socket" ] && break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"

wayland_env=(env XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket")

window_json() {
    local app_id=$1
    "${wayland_env[@]}" "$AQUEOUSCTL_BIN" windows --json |
        jq -c --arg app_id "$app_id" '.[] | select(.app_id == $app_id)'
}

geometry() {
    jq -r '[.geometry.x, .geometry.y, .geometry.width, .geometry.height] | @tsv'
}

wait_marker() {
    local pid=$1 sync_dir=$2 marker=$3 log_file=$4
    for _ in $(seq 1 200); do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited while waiting for $marker"
        kill -0 "$pid" 2>/dev/null || {
            cat "$log_file" >&2
            die "fixture exited before $marker"
        }
        [ -f "$sync_dir/$marker" ] && return 0
        sleep 0.05
    done
    tail -120 "$COMPOSITOR_LOG" >&2
    cat "$log_file" >&2
    die "timed out waiting for $marker"
}

wait_window() {
    local app_id=$1 json=""
    for _ in $(seq 1 200); do
        json=$(window_json "$app_id")
        [ -n "$json" ] && {
            printf '%s\n' "$json"
            return 0
        }
        sleep 0.05
    done
    "${wayland_env[@]}" "$AQUEOUSCTL_BIN" windows --json >&2 || true
    tail -120 "$COMPOSITOR_LOG" >&2
    die "timed out waiting for $app_id"
}

wait_geometry() {
    local app_id=$1 expected=$2 json=""
    for _ in $(seq 1 200); do
        json=$(window_json "$app_id")
        [ -n "$json" ] && [ "$(geometry <<<"$json")" = "$expected" ] && return 0
        sleep 0.05
    done
    die "timed out restoring $app_id geometry $expected; got $(geometry <<<"$json")"
}

wait_maximized_state() {
    local app_id=$1 wanted=$2 json=""
    for _ in $(seq 1 200); do
        json=$(window_json "$app_id")
        if [ "$wanted" = true ]; then
            jq -e '.states | index("maximized") != null' <<<"$json" >/dev/null && return 0
        else
            jq -e '.states | index("maximized") == null' <<<"$json" >/dev/null && return 0
        fi
        sleep 0.05
    done
    die "timed out waiting for $app_id maximized=$wanted"
}

wait_floating_state() {
    local app_id=$1 wanted=$2 json=""
    for _ in $(seq 1 200); do
        json=$(window_json "$app_id")
        if [ "$wanted" = true ]; then
            jq -e '.states | index("floating") != null' <<<"$json" >/dev/null && return 0
        else
            jq -e '.states | index("floating") == null' <<<"$json" >/dev/null && return 0
        fi
        sleep 0.05
    done
    die "timed out waiting for $app_id floating=$wanted"
}

wait_minimized_state() {
    local app_id=$1 wanted=$2 json=""
    for _ in $(seq 1 200); do
        json=$(window_json "$app_id")
        if [ "$wanted" = true ]; then
            jq -e '.states | index("minimized") != null' <<<"$json" >/dev/null && return 0
        else
            jq -e '.states | index("minimized") == null' <<<"$json" >/dev/null && return 0
        fi
        sleep 0.05
    done
    die "timed out waiting for $app_id minimized=$wanted"
}

start_fixture() {
    local app_id=$1 mode=$2
    local sync_dir="$TEST_ROOT/$app_id-sync"
    local log_file="$TEST_ROOT/$app_id.log"
    mkdir -p "$sync_dir"
    "${wayland_env[@]}" timeout 45 "$FIXTURE_BIN" "$sync_dir" "$app_id" "$mode" \
        >"$log_file" 2>&1 &
    STARTED_PID=$!
    CLIENT_PIDS+=("$STARTED_PID")
    CLIENT_SYNCS+=("$sync_dir")
    CLIENT_LOGS+=("$log_file")
    wait_marker "$STARTED_PID" "$sync_dir" ready "$log_file"
}

press() {
    local modifiers="${*:2}"
    modifiers=${modifiers// /,}
    "${wayland_env[@]}" wlrctl keyboard type "$1" modifiers "$modifiers"
}

click_at() {
    "${wayland_env[@]}" wlrctl pointer move -10000 -10000
    "${wayland_env[@]}" wlrctl pointer move "$1" "$2"
    "${wayland_env[@]}" wlrctl pointer click left
}

APP_ONE=aqueous.layout-one
APP_TWO=aqueous.layout-two
APP_THREE=aqueous.layout-three

start_fixture "$APP_ONE" move-resize
PID_ONE=$STARTED_PID
SYNC_ONE="${CLIENT_SYNCS[0]}"
LOG_ONE="${CLIENT_LOGS[0]}"
wait_window "$APP_ONE" >/dev/null
start_fixture "$APP_TWO" idle
wait_window "$APP_TWO" >/dev/null
start_fixture "$APP_THREE" idle
wait_window "$APP_THREE" >/dev/null

read -r one_x one_y one_w one_h < <(geometry <<<"$(window_json "$APP_ONE")")
read -r two_x two_y two_w two_h < <(geometry <<<"$(window_json "$APP_TWO")")
read -r three_x three_y three_w three_h < <(geometry <<<"$(window_json "$APP_THREE")")
[ "$two_x" -eq $((one_x + 32)) ] && [ "$two_y" -eq $((one_y + 32)) ] &&
    [ "$three_x" -eq $((two_x + 32)) ] && [ "$three_y" -eq $((two_y + 32)) ] ||
    die "new floating-layout windows were not cascaded"
[ "$one_w $one_h" = "$two_w $two_h" ] && [ "$two_w $two_h" = "$three_w $three_h" ] ||
    die "cascade unexpectedly changed initial window sizes"

printf '%d %d %d %d\n' \
    $((one_x + 5)) $((one_y + 5)) \
    $((one_x + 65)) $((one_y + 45)) >"$SYNC_ONE/move"
wait_marker "$PID_ONE" "$SYNC_ONE" move-done "$LOG_ONE"
read -r moved_x moved_y moved_w moved_h < <(geometry <<<"$(window_json "$APP_ONE")")
[ "$moved_x" -ne "$one_x" ] || [ "$moved_y" -ne "$one_y" ] ||
    die "client move did not update floating-layout geometry"

printf '%d %d %d %d\n' \
    $((moved_x + 10)) $((moved_y + 10)) \
    $((moved_x - 10)) $((moved_y - 5)) >"$SYNC_ONE/resize"
wait_marker "$PID_ONE" "$SYNC_ONE" resize-done "$LOG_ONE"
read -r final_x final_y final_w final_h < <(geometry <<<"$(window_json "$APP_ONE")")
[ "$final_x" -eq $((moved_x - 20)) ] &&
    [ "$final_y" -eq $((moved_y - 15)) ] &&
    [ "$final_w" -eq $((moved_w + 20)) ] &&
    [ "$final_h" -eq $((moved_h + 15)) ] ||
    die "client resize did not update floating-layout geometry"

# The stacking alias exposes the same remembered geometry plus keyboard
# movement and snap/restore behavior. Snapping reports tiled-edge state to the
# client but keeps workspace floating ownership.
click_at $((final_x + 5)) $((final_y + 5))
press d SUPER CTRL
final_x=$((final_x + 10))
wait_geometry "$APP_ONE" "$final_x"$'\t'"$final_y"$'\t'"$final_w"$'\t'"$final_h"
press h SUPER CTRL
wait_geometry "$APP_ONE" $'0\t0\t640\t720'
press u SUPER CTRL
wait_geometry "$APP_ONE" "$final_x"$'\t'"$final_y"$'\t'"$final_w"$'\t'"$final_h"

# Named snap layouts are stacking-only. Padding is applied after resolving the
# normalized zone, and unsnap restores the exact previous stacking geometry.
press j SUPER CTRL
wait_geometry "$APP_ONE" $'648\t8\t624\t704'
press u SUPER CTRL
wait_geometry "$APP_ONE" "$final_x"$'\t'"$final_y"$'\t'"$final_w"$'\t'"$final_h"

ONE_FLOAT="$final_x"$'\t'"$final_y"$'\t'"$final_w"$'\t'"$final_h"
TWO_FLOAT="$two_x"$'\t'"$two_y"$'\t'"$two_w"$'\t'"$two_h"
THREE_FLOAT="$three_x"$'\t'"$three_y"$'\t'"$three_w"$'\t'"$three_h"

press c SUPER
press c SUPER
wait_geometry "$APP_ONE" "$ONE_FLOAT"

press t SUPER
wait_floating_state "$APP_ONE" false
wait_floating_state "$APP_TWO" false
wait_floating_state "$APP_THREE" false
[ "$(geometry <<<"$(window_json "$APP_ONE")")" != "$ONE_FLOAT" ] ||
    die "tile switch did not rearrange ordinary workspace-owned window"
TILED_BEFORE=$(geometry <<<"$(window_json "$APP_ONE")")
click_at $(jq -r '.geometry.x + 5' <<<"$(window_json "$APP_ONE")") $(jq -r '.geometry.y + 5' <<<"$(window_json "$APP_ONE")")
press j SUPER CTRL
wait_geometry "$APP_ONE" "$TILED_BEFORE"

press f SUPER
wait_geometry "$APP_ONE" "$ONE_FLOAT"
wait_geometry "$APP_TWO" "$TWO_FLOAT"
wait_geometry "$APP_THREE" "$THREE_FLOAT"

# Toggling on in a floating workspace deliberately promotes the focused
# window to a persistent per-window overlay.
click_at $((final_x + 5)) $((final_y + 5))
press v SUPER
press t SUPER
wait_floating_state "$APP_ONE" true
wait_floating_state "$APP_TWO" false
wait_floating_state "$APP_THREE" false
wait_geometry "$APP_ONE" "$ONE_FLOAT"

# Toggling it off returns ownership to the workspace layout while preserving
# the remembered rectangle for the next floating-layout activation.
press f SUPER
wait_geometry "$APP_ONE" "$ONE_FLOAT"
click_at $((final_x + 5)) $((final_y + 5))
press v SUPER
press t SUPER
wait_floating_state "$APP_ONE" false
press f SUPER
wait_geometry "$APP_ONE" "$ONE_FLOAT"

# Workspace-owned floating windows retain tiled policy state. Their titlebar
# minimize request must still be honored because the active layout presents
# them as floating windows.
APP_MINIMIZE=aqueous.layout-minimize
start_fixture "$APP_MINIMIZE" minimize
PID_MINIMIZE=$STARTED_PID
SYNC_MINIMIZE="${CLIENT_SYNCS[3]}"
LOG_MINIMIZE="${CLIENT_LOGS[3]}"
wait_window "$APP_MINIMIZE" >/dev/null
touch "$SYNC_MINIMIZE/minimize"
wait_marker "$PID_MINIMIZE" "$SYNC_MINIMIZE" minimize-done "$LOG_MINIMIZE"
wait_minimized_state "$APP_MINIMIZE" true

# A workspace-owned floating window retains tiled policy ownership, but its
# titlebar maximize request must temporarily cover the usable output and then
# restore the floating layout's exact remembered rectangle.
APP_MAXIMIZE=aqueous.layout-maximize
MAXIMIZE_INDEX=${#CLIENT_PIDS[@]}
start_fixture "$APP_MAXIMIZE" maximize
PID_MAXIMIZE=$STARTED_PID
SYNC_MAXIMIZE="${CLIENT_SYNCS[$MAXIMIZE_INDEX]}"
LOG_MAXIMIZE="${CLIENT_LOGS[$MAXIMIZE_INDEX]}"
MAXIMIZE_FLOAT=$(geometry <<<"$(window_json "$APP_MAXIMIZE")")
touch "$SYNC_MAXIMIZE/maximize"
wait_marker "$PID_MAXIMIZE" "$SYNC_MAXIMIZE" maximize-done "$LOG_MAXIMIZE"
wait_maximized_state "$APP_MAXIMIZE" true
wait_geometry "$APP_MAXIMIZE" $'0\t0\t1280\t720'
touch "$SYNC_MAXIMIZE/unmaximize"
wait_marker "$PID_MAXIMIZE" "$SYNC_MAXIMIZE" unmaximize-done "$LOG_MAXIMIZE"
wait_maximized_state "$APP_MAXIMIZE" false
wait_geometry "$APP_MAXIMIZE" "$MAXIMIZE_FLOAT"
jq -e '.layout == "tiled" and (.states | index("floating") == null)' \
    <<<"$(window_json "$APP_MAXIMIZE")" >/dev/null ||
    die "unmaximize did not return workspace-floating window to layout ownership"

# A titlebar move from maximized state restores the remembered floating size
# beneath the pointer and continues the same client move operation.
APP_MAXIMIZE_MOVE=aqueous.layout-maximize-move
MAXIMIZE_MOVE_INDEX=${#CLIENT_PIDS[@]}
start_fixture "$APP_MAXIMIZE_MOVE" maximize-move
PID_MAXIMIZE_MOVE=$STARTED_PID
SYNC_MAXIMIZE_MOVE="${CLIENT_SYNCS[$MAXIMIZE_MOVE_INDEX]}"
LOG_MAXIMIZE_MOVE="${CLIENT_LOGS[$MAXIMIZE_MOVE_INDEX]}"
read -r maximize_move_x maximize_move_y maximize_move_w maximize_move_h \
    < <(geometry <<<"$(window_json "$APP_MAXIMIZE_MOVE")")
touch "$SYNC_MAXIMIZE_MOVE/maximize"
wait_marker "$PID_MAXIMIZE_MOVE" "$SYNC_MAXIMIZE_MOVE" maximize-done "$LOG_MAXIMIZE_MOVE"
wait_maximized_state "$APP_MAXIMIZE_MOVE" true
wait_geometry "$APP_MAXIMIZE_MOVE" $'0\t0\t1280\t720'
printf '%d %d %d %d\n' 640 20 700 120 >"$SYNC_MAXIMIZE_MOVE/move"
wait_marker "$PID_MAXIMIZE_MOVE" "$SYNC_MAXIMIZE_MOVE" move-done "$LOG_MAXIMIZE_MOVE"
wait_maximized_state "$APP_MAXIMIZE_MOVE" false
read -r restored_x restored_y restored_w restored_h \
    < <(geometry <<<"$(window_json "$APP_MAXIMIZE_MOVE")")
[ "$restored_w" -eq "$maximize_move_w" ] &&
    [ "$restored_h" -eq "$maximize_move_h" ] &&
    [ $((restored_x - (640 - maximize_move_w / 2 + 60))) -ge -12 ] &&
    [ $((restored_x - (640 - maximize_move_w / 2 + 60))) -le 12 ] &&
    [ "$restored_y" -eq 100 ] ||
    die "maximized titlebar move did not restore and track floating geometry: original=${maximize_move_x},${maximize_move_y},${maximize_move_w},${maximize_move_h} restored=${restored_x},${restored_y},${restored_w},${restored_h}"
jq -e '.layout == "tiled" and (.states | index("floating") == null)' \
    <<<"$(window_json "$APP_MAXIMIZE_MOVE")" >/dev/null ||
    die "maximized titlebar move changed floating-layout ownership"

# Moving a stacking-owned window to an output edge activates the named-zone
# overlay. The live window remains freely movable until release, then commits
# the highlighted right zone including layout padding.
APP_ZONE_DRAG=aqueous.layout-zone-drag
ZONE_DRAG_INDEX=${#CLIENT_PIDS[@]}
start_fixture "$APP_ZONE_DRAG" move-only
PID_ZONE_DRAG=$STARTED_PID
SYNC_ZONE_DRAG="${CLIENT_SYNCS[$ZONE_DRAG_INDEX]}"
LOG_ZONE_DRAG="${CLIENT_LOGS[$ZONE_DRAG_INDEX]}"
read -r zone_x zone_y zone_w zone_h < <(geometry <<<"$(window_json "$APP_ZONE_DRAG")")
click_at $((zone_x + 5)) $((zone_y + 5))
printf '%d %d %d %d\n' $((zone_x + 5)) $((zone_y + 5)) 1279 360 >"$SYNC_ZONE_DRAG/move"
wait_marker "$PID_ZONE_DRAG" "$SYNC_ZONE_DRAG" move-done "$LOG_ZONE_DRAG"
wait_geometry "$APP_ZONE_DRAG" $'648\t8\t624\t704'

for sync_dir in "${CLIENT_SYNCS[@]}"; do touch "$sync_dir/finish"; done
for index in "${!CLIENT_PIDS[@]}"; do
    if ! wait "${CLIENT_PIDS[$index]}"; then
        cat "${CLIENT_LOGS[$index]}" >&2
        tail -120 "$COMPOSITOR_LOG" >&2
        die "floating-layout fixture failed"
    fi
done
CLIENT_PIDS=()

echo "PASS: stacking alias, named snap zones, stacking-only guards, cascade, snap/restore, ownership, switching, maximize-drag, and toggle semantics"
