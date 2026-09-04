#!/usr/bin/env bash
set -euo pipefail

# Regression for application-originated xdg_toplevel move, resize, maximize,
# and minimize requests under integrated policy, plus overlapping-float
# stacking and hit testing. Client requests are exercised against both an
# explicitly floating window and an ordinary tiled window.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/xdg-floating-request.c"
ACTIVATE_SOURCE="$here/scripts/fixtures/foreign-toplevel-activate.c"
RULES="$here/scripts/fixtures/xdg-floating-rules.toml"
INPUT_CONFIG=${AQUEOUS_INPUT_CONFIG:-"$here/scripts/fixtures/xdg-floating-input.toml"}
PROTOCOLS="$(pkg-config --variable=pkgdatadir wayland-protocols)"
XDG_SHELL_PROTOCOL="$PROTOCOLS/stable/xdg-shell/xdg-shell.xml"
VIRTUAL_POINTER_PROTOCOL="$here/protocol/upstream/wlr-virtual-pointer-unstable-v1.xml"
FOREIGN_TOPLEVEL_PROTOCOL="$here/protocol/upstream/wlr-foreign-toplevel-management-unstable-v1.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing xdg floating fixture"
[ -r "$ACTIVATE_SOURCE" ] || die "missing foreign-toplevel activation fixture"
[ -r "$RULES" ] || die "missing xdg floating rules"
[ -r "$INPUT_CONFIG" ] || die "missing xdg floating input config"
[ -r "$VIRTUAL_POINTER_PROTOCOL" ] || die "wlr virtual pointer protocol XML is unavailable"
[ -r "$FOREIGN_TOPLEVEL_PROTOCOL" ] || die "wlr foreign-toplevel protocol XML is unavailable"
for tool in cc jq pkg-config timeout wayland-scanner; do
    have "$tool" || die "$tool is required for xdg floating integration tests"
done
pkg-config --exists wayland-client wayland-protocols || \
    die "Wayland client development files and protocols are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-xdg-floating.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
FIXTURE_BIN="$TEST_ROOT/xdg-floating-request"
ACTIVATE_BIN="$TEST_ROOT/foreign-toplevel-activate"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
CLIENT_LOG="$TEST_ROOT/client.log"
COMPOSITOR_PID=""
CLIENT_PID=""
STACK_PIDS=()

cleanup_client() {
    [ -z "$CLIENT_PID" ] || kill "$CLIENT_PID" 2>/dev/null || true
    [ -z "$CLIENT_PID" ] || wait "$CLIENT_PID" 2>/dev/null || true
    CLIENT_PID=""
}
cleanup() {
    cleanup_client
    for pid in "${STACK_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${STACK_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
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
wayland-scanner client-header "$FOREIGN_TOPLEVEL_PROTOCOL" \
    "$TEST_ROOT/wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
wayland-scanner private-code "$FOREIGN_TOPLEVEL_PROTOCOL" \
    "$TEST_ROOT/wlr-foreign-toplevel-management-unstable-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" \
    "$TEST_ROOT/xdg-shell-protocol.c" \
    "$TEST_ROOT/wlr-virtual-pointer-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$ACTIVATE_SOURCE" \
    "$TEST_ROOT/wlr-foreign-toplevel-management-unstable-v1-protocol.c" \
    -o "$ACTIVATE_BIN" $(pkg-config --cflags --libs wayland-client)

mkdir -p "$RUNTIME/config/aqueous" "$RUNTIME/home"
cp "$INPUT_CONFIG" "$RUNTIME/config/aqueous/input.toml"
chmod 700 "$RUNTIME"
WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
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

wait_marker() {
    local sync_dir=$1 marker=$2
    for _ in $(seq 1 200); do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited while waiting for $marker"
        kill -0 "$CLIENT_PID" 2>/dev/null || {
            cat "$CLIENT_LOG" >&2
            die "fixture exited before $marker"
        }
        [ -f "$sync_dir/$marker" ] && return 0
        sleep 0.05
    done
    tail -120 "$COMPOSITOR_LOG" >&2
    cat "$CLIENT_LOG" >&2
    die "timed out waiting for $marker"
}

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
        [ -n "$json" ] && {
            printf '%s\n' "$json"
            return 0
        }
        sleep 0.05
    done
    XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        "$AQUEOUSCTL_BIN" windows --json >&2 || true
    tail -120 "$COMPOSITOR_LOG" >&2
    cat "$CLIENT_LOG" >&2
    die "timed out waiting for $app_id"
}

wait_state() {
    local app_id=$1 state=$2 wanted=$3 json=""
    for _ in $(seq 1 160); do
        json=$(window_json "$app_id")
        if [ "$wanted" = true ]; then
            jq -e --arg state "$state" '.states | index($state) != null' <<<"$json" >/dev/null && return 0
        else
            jq -e --arg state "$state" '.states | index($state) == null' <<<"$json" >/dev/null && return 0
        fi
        sleep 0.05
    done
    die "timed out waiting for $app_id state $state=$wanted"
}

wait_geometry_changed() {
    local app_id=$1 prior=$2 json=""
    for _ in $(seq 1 160); do
        json=$(window_json "$app_id")
        [ -n "$json" ] && [ "$(geometry <<<"$json")" != "$prior" ] && return 0
        sleep 0.05
    done
    die "timed out waiting for $app_id geometry to change from $prior"
}

wait_focused() {
    local app_id=$1 json=""
    for _ in $(seq 1 160); do
        json=$(window_json "$app_id")
        jq -e '.states | index("focused") != null' <<<"$json" >/dev/null && return 0
        sleep 0.05
    done
    die "timed out waiting for focus on $app_id"
}

expect_focused() {
    local app_id=$1 json=""
    sleep 0.2
    json=$(window_json "$app_id")
    if ! jq -e '.states | index("focused") != null' <<<"$json" >/dev/null; then
        XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
            "$AQUEOUSCTL_BIN" windows --json >&2 || true
        tail -120 "$COMPOSITOR_LOG" >&2
        die "overlap click did not stay on raised float $app_id"
    fi
}

geometry() {
    jq -r '[.geometry.x, .geometry.y, .geometry.width, .geometry.height] | @tsv'
}

run_case() {
    local app_id=$1
    local floating=$2
    local sync_dir="$TEST_ROOT/$app_id-sync"
    mkdir -p "$sync_dir"
    : >"$CLIENT_LOG"
    XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        timeout 30 "$FIXTURE_BIN" "$sync_dir" "$app_id" >"$CLIENT_LOG" 2>&1 &
    CLIENT_PID=$!
    wait_marker "$sync_dir" ready

    local initial_json initial_x initial_y initial_w initial_h
    initial_json=$(wait_window "$app_id")
    read -r initial_x initial_y initial_w initial_h < <(geometry <<<"$initial_json")
    if [ "$floating" = true ]; then
        jq -e '.states | index("floating") != null' <<<"$initial_json" >/dev/null ||
            die "$app_id was not initially floating"
    else
        jq -e '.states | index("floating") == null' <<<"$initial_json" >/dev/null ||
            die "$app_id unexpectedly started floating"
    fi

    printf '%d %d %d %d\n' \
        $((initial_x + 40)) $((initial_y + 40)) \
        $((initial_x + 100)) $((initial_y + 80)) >"$sync_dir/move"
    wait_marker "$sync_dir" move-done
    local moved_json moved_x moved_y moved_w moved_h
    moved_json=$(window_json "$app_id")
    read -r moved_x moved_y moved_w moved_h < <(geometry <<<"$moved_json")
    if [ "$floating" = true ]; then
        [ "$moved_x" -eq $((initial_x + 60)) ] && [ "$moved_y" -eq $((initial_y + 40)) ] ||
            die "floating client move did not track pointer delta"
    else
        [ "$moved_x $moved_y $moved_w $moved_h" = "$initial_x $initial_y $initial_w $initial_h" ] ||
            die "client move changed non-floating geometry"
    fi

    printf '%d %d %d %d\n' \
        $((moved_x + 10)) $((moved_y + 10)) \
        $((moved_x - 10)) $((moved_y - 5)) >"$sync_dir/resize"
    wait_marker "$sync_dir" resize-done
    local resized_json resized_x resized_y resized_w resized_h
    resized_json=$(window_json "$app_id")
    read -r resized_x resized_y resized_w resized_h < <(geometry <<<"$resized_json")
    if [ "$floating" = true ]; then
        [ "$resized_x" -eq $((moved_x - 20)) ] &&
            [ "$resized_y" -eq $((moved_y - 15)) ] &&
            [ "$resized_w" -eq $((moved_w + 20)) ] &&
            [ "$resized_h" -eq $((moved_h + 15)) ] ||
            die "top-left client resize did not preserve its requested edges"
    else
        [ "$resized_x $resized_y $resized_w $resized_h" = "$moved_x $moved_y $moved_w $moved_h" ] ||
            die "client resize changed non-floating geometry"
    fi

    touch "$sync_dir/maximize"
    wait_marker "$sync_dir" maximize-done
    wait_state "$app_id" maximized "$floating"
    if [ "$floating" = true ]; then
        local prior_geometry
        prior_geometry="$resized_x"$'\t'"$resized_y"$'\t'"$resized_w"$'\t'"$resized_h"
        wait_geometry_changed "$app_id" "$prior_geometry"
    fi

    touch "$sync_dir/unmaximize"
    wait_marker "$sync_dir" unmaximize-done
    wait_state "$app_id" maximized false
    if [ "$floating" = true ]; then
        wait_state "$app_id" floating true
        local restored_json
        restored_json=$(window_json "$app_id")
        [ "$(geometry <<<"$restored_json")" = "$resized_x"$'\t'"$resized_y"$'\t'"$resized_w"$'\t'"$resized_h" ] ||
            die "unmaximize did not restore floating geometry"
    fi

    touch "$sync_dir/minimize"
    wait_marker "$sync_dir" minimize-done
    wait_state "$app_id" minimized "$floating"
    if [ "$floating" = true ]; then
        # Docks restore items through foreign-toplevel activation rather than a
        # separate unminimize request. The click must restore the prior floating
        # state and geometry, then raise and focus the target.
        XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
            "$ACTIVATE_BIN" "$app_id"
        wait_state "$app_id" minimized false
        wait_state "$app_id" floating true
        wait_focused "$app_id"
        local activated_json
        activated_json=$(window_json "$app_id")
        [ "$(geometry <<<"$activated_json")" = "$resized_x"$'\t'"$resized_y"$'\t'"$resized_w"$'\t'"$resized_h" ] ||
            die "dock activation did not restore floating geometry"
    fi
    touch "$sync_dir/finish"
    if ! wait "$CLIENT_PID"; then
        CLIENT_PID=""
        tail -120 "$COMPOSITOR_LOG" >&2
        cat "$CLIENT_LOG" >&2
        die "$app_id fixture failed"
    fi
    CLIENT_PID=""
}

run_case aqueous.floating-request true
run_case aqueous.tiled-request false

start_idle_fixture() {
    local app_id=$1 sync_dir=$2 log_file=$3 mode=${4:-idle} pid=""
    mkdir -p "$sync_dir"
    XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        timeout 30 "$FIXTURE_BIN" "$sync_dir" "$app_id" "$mode" >"$log_file" 2>&1 &
    pid=$!
    STACK_PIDS+=("$pid")
    for _ in $(seq 1 200); do
        kill -0 "$pid" 2>/dev/null || {
            cat "$log_file" >&2
            die "$app_id idle fixture exited before ready"
        }
        [ -f "$sync_dir/ready" ] && return 0
        sleep 0.05
    done
    die "timed out waiting for $app_id idle fixture"
}

wait_stack_marker() {
    local pid=$1 sync_dir=$2 marker=$3 log_file=$4
    for _ in $(seq 1 200); do
        kill -0 "$pid" 2>/dev/null || {
            cat "$log_file" >&2
            die "stacking fixture exited before $marker"
        }
        [ -f "$sync_dir/$marker" ] && return 0
        sleep 0.05
    done
    cat "$log_file" >&2
    tail -160 "$COMPOSITOR_LOG" >&2
    die "timed out waiting for stacking fixture marker $marker"
}

STACK_CLICK_INDEX=0
stack_click_at() {
    local x=$1 y=$2
    STACK_CLICK_INDEX=$((STACK_CLICK_INDEX + 1))
    printf '%d %d %d %d %d %d\n' \
        "$x" "$y" "$x" "$y" 1280 720 \
        >"$STACK_ONE_SYNC/click-$STACK_CLICK_INDEX"
    wait_stack_marker \
        "${STACK_PIDS[0]}" \
        "$STACK_ONE_SYNC" \
        "click-$STACK_CLICK_INDEX-done" \
        "$TEST_ROOT/stack-one.log"
}

STACK_ONE_SYNC="$TEST_ROOT/stack-one-sync"
STACK_TWO_SYNC="$TEST_ROOT/stack-two-sync"
start_idle_fixture aqueous.stack-one "$STACK_ONE_SYNC" "$TEST_ROOT/stack-one.log" clicks
start_idle_fixture aqueous.stack-two "$STACK_TWO_SYNC" "$TEST_ROOT/stack-two.log"

stack_one=$(wait_window aqueous.stack-one)
stack_two=$(wait_window aqueous.stack-two)
read -r one_x one_y one_w one_h < <(geometry <<<"$stack_one")
read -r two_x two_y two_w two_h < <(geometry <<<"$stack_two")

overlap_x=$(( (one_x > two_x ? one_x : two_x) + 30 ))
overlap_y=$(( (one_y > two_y ? one_y : two_y) + 30 ))

# Focus the lower-left-only portion of the first float. The following overlap
# click must still hit it after the focus-triggered raise.
stack_click_at $((one_x + 20)) $((one_y + 20))
wait_stack_marker "${STACK_PIDS[0]}" "$STACK_ONE_SYNC" button-1 "$TEST_ROOT/stack-one.log"
wait_focused aqueous.stack-one
stack_click_at "$overlap_x" "$overlap_y"
wait_stack_marker "${STACK_PIDS[0]}" "$STACK_ONE_SYNC" button-2 "$TEST_ROOT/stack-one.log"
expect_focused aqueous.stack-one

# Repeat in the opposite direction from the second float's exposed right edge.
stack_click_at $((two_x + two_w - 20)) $((two_y + 20))
wait_stack_marker "${STACK_PIDS[1]}" "$STACK_TWO_SYNC" button-1 "$TEST_ROOT/stack-two.log"
wait_focused aqueous.stack-two
stack_click_at "$overlap_x" "$overlap_y"
wait_stack_marker "${STACK_PIDS[1]}" "$STACK_TWO_SYNC" button-2 "$TEST_ROOT/stack-two.log"
expect_focused aqueous.stack-two

touch "$STACK_ONE_SYNC/finish" "$STACK_TWO_SYNC/finish"
for pid in "${STACK_PIDS[@]}"; do
    wait "$pid" || die "idle stacking fixture failed"
done
STACK_PIDS=()

echo "PASS: xdg floating requests, dock restoration, and overlap focus work"
