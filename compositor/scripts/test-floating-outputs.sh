#!/usr/bin/env bash
set -euo pipefail

# Multi-output floating regression:
#   1. client-side move crosses into a rotated, scale-2 output;
#   2. logical window size and destination active-workspace ownership persist;
#   3. disabling the source during another active move recovers that float into
#      the destination's effective (dynamic + configured strut) usable area.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/xdg-floating-request.c"
WM_CONFIG="$here/scripts/fixtures/floating-outputs-wm.toml"
RULES="$here/scripts/fixtures/floating-outputs-rules.toml"
PROTOCOLS="$(pkg-config --variable=pkgdatadir wayland-protocols)"
XDG_SHELL_PROTOCOL="$PROTOCOLS/stable/xdg-shell/xdg-shell.xml"
VIRTUAL_POINTER_PROTOCOL="$here/protocol/upstream/wlr-virtual-pointer-unstable-v1.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for tool in cc jq nc pkg-config timeout wayland-scanner wlrctl; do
    have "$tool" || die "$tool is required for floating output integration tests"
done
pkg-config --exists wayland-client wayland-protocols ||
    die "Wayland client development files and protocols are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-floating-outputs.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
FIXTURE_BIN="$TEST_ROOT/xdg-floating-request"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
CLIENT_PIDS=()

cleanup() {
    for pid in "${CLIENT_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${CLIENT_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
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
WLR_HEADLESS_OUTPUTS=2 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$WM_CONFIG" \
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

OUTPUT_SOCKET="$RUNTIME/aqueous/outputd.sock"
output_request() {
    printf '%s\n' "$1" | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1
}

outputs=""
for _ in $(seq 1 160); do
    outputs=$(output_request '{"op":"list"}' || true)
    [ "$(jq '.outputs | length' <<<"$outputs" 2>/dev/null || echo 0)" -eq 2 ] && break
    sleep 0.05
done
[ "$(jq '.outputs | length' <<<"$outputs")" -eq 2 ] || die "output service did not report two outputs"

SOURCE=$(jq -r '.outputs | sort_by(.name) | .[0].name' <<<"$outputs")
DEST=$(jq -r '.outputs | sort_by(.name) | .[1].name' <<<"$outputs")
SOURCE_WIDTH=$(jq -r --arg name "$SOURCE" '.outputs[] | select(.name == $name) | (.current_mode.width / .scale | floor)' <<<"$outputs")
SOURCE_HEIGHT=$(jq -r --arg name "$SOURCE" '.outputs[] | select(.name == $name) | (.current_mode.height / .scale | floor)' <<<"$outputs")
DEST_PHYSICAL_WIDTH=$(jq -r --arg name "$DEST" '.outputs[] | select(.name == $name) | .current_mode.width' <<<"$outputs")
DEST_PHYSICAL_HEIGHT=$(jq -r --arg name "$DEST" '.outputs[] | select(.name == $name) | .current_mode.height' <<<"$outputs")
for value in "$SOURCE_WIDTH" "$SOURCE_HEIGHT" "$DEST_PHYSICAL_WIDTH" "$DEST_PHYSICAL_HEIGHT"; do
    [ "$value" -gt 0 ] || die "headless output mode dimensions were unavailable"
done

DEST_X=$SOURCE_WIDTH
DEST_Y=-120
DEST_WIDTH=$((DEST_PHYSICAL_HEIGHT / 2))
DEST_HEIGHT=$((DEST_PHYSICAL_WIDTH / 2))
LAYOUT_MIN_Y=$DEST_Y
LAYOUT_MAX_Y=$SOURCE_HEIGHT
[ $((DEST_Y + DEST_HEIGHT)) -le "$LAYOUT_MAX_Y" ] || LAYOUT_MAX_Y=$((DEST_Y + DEST_HEIGHT))
POINTER_X_EXTENT=$((DEST_X + DEST_WIDTH))
POINTER_Y_EXTENT=$((LAYOUT_MAX_Y - LAYOUT_MIN_Y))

configure=$(jq -cn \
    --arg source "$SOURCE" \
    --arg dest "$DEST" \
    --argjson dest_x "$DEST_X" \
    --argjson dest_y "$DEST_Y" \
    '{
        op: "set",
        changes: [
            {name: $source, enabled: true, scale: 1, transform: "normal", position: [0, 0]},
            {name: $dest, enabled: true, scale: 2, transform: "90", position: [$dest_x, $dest_y]}
        ]
    }')
configured=$(output_request "$configure")
jq -e '.ok == true and .applied == 2' <<<"$configured" >/dev/null ||
    die "mixed-scale output configuration was rejected: $configured"

for _ in $(seq 1 160); do
    outputs=$(output_request '{"op":"list"}')
    jq -e --arg name "$DEST" --argjson x "$DEST_X" --argjson y "$DEST_Y" '
        .outputs[] | select(.name == $name) |
        .enabled == true and .scale == 2 and .transform == "90" and .x == $x and .y == $y
    ' <<<"$outputs" >/dev/null && break
    sleep 0.05
done
jq -e --arg name "$DEST" '.outputs[] | select(.name == $name) | .scale == 2 and .transform == "90"' \
    <<<"$outputs" >/dev/null || die "destination scale/transform did not commit"

window_json() {
    local app_id=$1
    XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        "$AQUEOUSCTL_BIN" windows --json |
        jq -c --arg app_id "$app_id" '.[] | select(.app_id == $app_id)'
}

wait_window() {
    local app_id=$1 json=""
    for _ in $(seq 1 200); do
        json=$(window_json "$app_id")
        [ -n "$json" ] && { printf '%s\n' "$json"; return 0; }
        sleep 0.05
    done
    tail -120 "$COMPOSITOR_LOG" >&2
    die "timed out waiting for $app_id"
}

wait_owner() {
    local app_id=$1 output=$2 json=""
    for _ in $(seq 1 200); do
        json=$(window_json "$app_id")
        [ "$(jq -r '.output // ""' <<<"$json")" = "$output" ] && {
            printf '%s\n' "$json"
            return 0
        }
        sleep 0.05
    done
    tail -120 "$COMPOSITOR_LOG" >&2
    die "$app_id did not move to $output"
}

wait_marker() {
    local pid=$1 sync_dir=$2 marker=$3 log_file=$4
    for _ in $(seq 1 240); do
        kill -0 "$pid" 2>/dev/null || { cat "$log_file" >&2; die "fixture exited before $marker"; }
        [ -f "$sync_dir/$marker" ] && return 0
        sleep 0.05
    done
    tail -120 "$COMPOSITOR_LOG" >&2
    cat "$log_file" >&2
    die "timed out waiting for $marker"
}

start_fixture() {
    local app_id=$1 mode=$2 sync_dir=$3 log_file=$4
    mkdir -p "$sync_dir"
    XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        timeout 35 "$FIXTURE_BIN" "$sync_dir" "$app_id" "$mode" >"$log_file" 2>&1 &
    STARTED_PID=$!
    CLIENT_PIDS+=("$STARTED_PID")
    wait_marker "$STARTED_PID" "$sync_dir" ready "$log_file"
}

# Put initial surface creation on the source output.
XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" wlrctl pointer move -10000 -10000
XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" wlrctl pointer move 200 200

CROSS_SYNC="$TEST_ROOT/cross-sync"
CROSS_LOG="$TEST_ROOT/cross.log"
start_fixture aqueous.output-cross move-only "$CROSS_SYNC" "$CROSS_LOG"
CROSS_PID=$STARTED_PID
cross_initial=$(wait_window aqueous.output-cross)
[ "$(jq -r '.output' <<<"$cross_initial")" = "$SOURCE" ] ||
    die "crossing fixture did not start on $SOURCE"
cross_width=$(jq -r '.geometry.width' <<<"$cross_initial")
cross_height=$(jq -r '.geometry.height' <<<"$cross_initial")
start_x=$(( $(jq -r '.geometry.x' <<<"$cross_initial") + 40 ))
start_y=$(( $(jq -r '.geometry.y' <<<"$cross_initial") + 40 ))
end_x=$((DEST_X + DEST_WIDTH / 2))
end_y=$((DEST_Y + DEST_HEIGHT / 2))
printf '%d %d %d %d %d %d\n' \
    "$start_x" $((start_y - LAYOUT_MIN_Y)) \
    "$end_x" $((end_y - LAYOUT_MIN_Y)) \
    "$POINTER_X_EXTENT" "$POINTER_Y_EXTENT" >"$CROSS_SYNC/move"
wait_marker "$CROSS_PID" "$CROSS_SYNC" move-done "$CROSS_LOG"
cross_moved=$(wait_owner aqueous.output-cross "$DEST")
[ "$(jq -r '.geometry.width' <<<"$cross_moved")" -eq "$cross_width" ] &&
    [ "$(jq -r '.geometry.height' <<<"$cross_moved")" -eq "$cross_height" ] ||
    die "mixed-scale transfer changed the window's logical size"

# Start a second move on the source, then remove that output before release.
XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" wlrctl pointer move -10000 -10000
XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" wlrctl pointer move 200 200
REMOVE_SYNC="$TEST_ROOT/removal-sync"
REMOVE_LOG="$TEST_ROOT/removal.log"
start_fixture aqueous.output-removal move-hold "$REMOVE_SYNC" "$REMOVE_LOG"
REMOVE_PID=$STARTED_PID
remove_initial=$(wait_window aqueous.output-removal)
[ "$(jq -r '.output' <<<"$remove_initial")" = "$SOURCE" ] ||
    die "removal fixture did not start on $SOURCE"
remove_start_x=$(( $(jq -r '.geometry.x' <<<"$remove_initial") + 40 ))
remove_start_y=$(( $(jq -r '.geometry.y' <<<"$remove_initial") + 40 ))
printf '%d %d %d %d %d %d\n' \
    "$remove_start_x" $((remove_start_y - LAYOUT_MIN_Y)) \
    $((remove_start_x + 40)) $((remove_start_y + 20 - LAYOUT_MIN_Y)) \
    "$POINTER_X_EXTENT" "$POINTER_Y_EXTENT" >"$REMOVE_SYNC/move"
wait_marker "$REMOVE_PID" "$REMOVE_SYNC" dragging "$REMOVE_LOG"

disable=$(jq -cn --arg source "$SOURCE" \
    '{op: "set", changes: [{name: $source, enabled: false}]}')
disabled=$(output_request "$disable")
jq -e '.ok == true and .applied == 1' <<<"$disabled" >/dev/null ||
    die "source disable was rejected: $disabled"
remove_recovered=$(wait_owner aqueous.output-removal "$DEST")
cross_after_disable=$(wait_owner aqueous.output-cross "$DEST")

usable_x=$((DEST_X + 24))
usable_y=$((DEST_Y + 40))
usable_right=$((DEST_X + DEST_WIDTH - 32))
usable_bottom=$((DEST_Y + DEST_HEIGHT - 24))
recovered_x=$(jq -r '.geometry.x' <<<"$remove_recovered")
recovered_y=$(jq -r '.geometry.y' <<<"$remove_recovered")
recovered_width=$(jq -r '.geometry.width' <<<"$remove_recovered")
recovered_height=$(jq -r '.geometry.height' <<<"$remove_recovered")
recovered_right=$(jq -r '.geometry.x + .geometry.width' <<<"$remove_recovered")
recovered_bottom=$(jq -r '.geometry.y + .geometry.height' <<<"$remove_recovered")
usable_width=$((usable_right - usable_x))
usable_height=$((usable_bottom - usable_y))
horizontal_ok=false
vertical_ok=false
if [ "$recovered_width" -le "$usable_width" ]; then
    [ "$recovered_x" -ge "$usable_x" ] && [ "$recovered_right" -le "$usable_right" ] &&
        horizontal_ok=true
else
    [ "$recovered_x" -eq "$usable_x" ] && horizontal_ok=true
fi
if [ "$recovered_height" -le "$usable_height" ]; then
    [ "$recovered_y" -ge "$usable_y" ] && [ "$recovered_bottom" -le "$usable_bottom" ] &&
        vertical_ok=true
else
    [ "$recovered_y" -eq "$usable_y" ] && vertical_ok=true
fi
[ "$horizontal_ok" = true ] && [ "$vertical_ok" = true ] ||
    die "output-removal recovery escaped destination usable area: geometry=$recovered_x,$recovered_y..$recovered_right,$recovered_bottom usable=$usable_x,$usable_y..$usable_right,$usable_bottom output=$remove_recovered"
[ "$(jq -r '.output' <<<"$cross_after_disable")" = "$DEST" ] ||
    die "previously transferred float returned to disabled source"

touch "$REMOVE_SYNC/release"
wait_marker "$REMOVE_PID" "$REMOVE_SYNC" move-done "$REMOVE_LOG"
touch "$REMOVE_SYNC/finish"
wait "$REMOVE_PID" || { cat "$REMOVE_LOG" >&2; die "removal fixture failed"; }
touch "$CROSS_SYNC/finish"
wait "$CROSS_PID" || { cat "$CROSS_LOG" >&2; die "crossing fixture failed"; }

echo "PASS: floating drags cross mixed-scale outputs and recover from source removal"
