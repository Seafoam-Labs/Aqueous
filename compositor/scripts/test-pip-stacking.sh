#!/usr/bin/env bash
set -euo pipefail

# Regression for picture-in-picture stacking (issue #161). A browser video
# pop-out is a plain xdg_toplevel titled "Picture-in-Picture" with no protocol
# hint. The built-in fallback rule must float it, mark it always-above, and
# promote it into the dedicated PiP scene layer so neither a focused floating
# peer nor a fullscreen peer can cover it.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/pip-stacking.c"
ACTIVATE_SOURCE="$here/scripts/fixtures/foreign-toplevel-activate.c"
INPUT_CONFIG="$here/scripts/fixtures/pip-stacking-input.toml"
LAYOUT_CONFIG="$here/scripts/fixtures/pip-stacking-layout.toml"
RULES_CONFIG="$here/scripts/fixtures/pip-stacking-rules.toml"
PROTOCOLS="$(pkg-config --variable=pkgdatadir wayland-protocols)"
XDG_SHELL_PROTOCOL="$PROTOCOLS/stable/xdg-shell/xdg-shell.xml"
FOREIGN_TOPLEVEL_PROTOCOL="$here/protocol/upstream/wlr-foreign-toplevel-management-unstable-v1.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing pip stacking fixture"
[ -r "$ACTIVATE_SOURCE" ] || die "missing foreign-toplevel activation fixture"
[ -r "$INPUT_CONFIG" ] || die "missing pip stacking input config"
[ -r "$LAYOUT_CONFIG" ] || die "missing pip stacking layout config"
[ -r "$RULES_CONFIG" ] || die "missing pip stacking rules config"
[ -r "$FOREIGN_TOPLEVEL_PROTOCOL" ] || die "wlr foreign-toplevel protocol XML is unavailable"
for tool in cc jq pkg-config timeout wayland-scanner; do
    have "$tool" || die "$tool is required for the pip stacking integration test"
done
pkg-config --exists wayland-client wayland-protocols || \
    die "Wayland client development files and protocols are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-pip-stacking.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
FIXTURE_BIN="$TEST_ROOT/pip-stacking"
ACTIVATE_BIN="$TEST_ROOT/foreign-toplevel-activate"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
PIP_PID=""
PEER_PID=""

cleanup() {
    for pid in "$PIP_PID" "$PEER_PID"; do
        [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    done
    for pid in "$PIP_PID" "$PEER_PID"; do
        [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
    done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

wayland-scanner client-header "$XDG_SHELL_PROTOCOL" "$TEST_ROOT/xdg-shell-client-protocol.h"
wayland-scanner private-code "$XDG_SHELL_PROTOCOL" "$TEST_ROOT/xdg-shell-protocol.c"
wayland-scanner client-header "$FOREIGN_TOPLEVEL_PROTOCOL" \
    "$TEST_ROOT/wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
wayland-scanner private-code "$FOREIGN_TOPLEVEL_PROTOCOL" \
    "$TEST_ROOT/wlr-foreign-toplevel-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" "$TEST_ROOT/xdg-shell-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$ACTIVATE_SOURCE" "$TEST_ROOT/wlr-foreign-toplevel-protocol.c" \
    -o "$ACTIVATE_BIN" $(pkg-config --cflags --libs wayland-client)

mkdir -p "$RUNTIME/config/aqueous" "$RUNTIME/home"
cp "$INPUT_CONFIG" "$RUNTIME/config/aqueous/input.toml"
cp "$LAYOUT_CONFIG" "$RUNTIME/config/aqueous/layout.toml"
chmod 700 "$RUNTIME"
# The peer is floated by an explicit rule; the PiP pop-out has no user rule, so
# the built-in picture-in-picture fallback must classify and float it.
WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_RULES="$RULES_CONFIG" \
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

ctl() {
    XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" "$AQUEOUSCTL_BIN" "$@"
}

window_json() {
    local app_id=$1
    ctl windows --json | jq -c --arg app_id "$app_id" '.[] | select(.app_id == $app_id)'
}

wait_window() {
    local app_id=$1 json=""
    for _ in $(seq 1 200); do
        json=$(window_json "$app_id")
        [ -n "$json" ] && { printf '%s\n' "$json"; return 0; }
        sleep 0.05
    done
    ctl windows --json >&2 || true
    tail -120 "$COMPOSITOR_LOG" >&2
    die "timed out waiting for $app_id"
}

wait_marker() {
    local dir=$1 marker=$2
    for _ in $(seq 1 200); do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited while waiting for $marker"
        [ -f "$dir/$marker" ] && return 0
        sleep 0.05
    done
    tail -120 "$COMPOSITOR_LOG" >&2
    die "timed out waiting for marker $marker"
}

has_state() {
    local json=$1 state=$2
    jq -e --arg state "$state" '.states | index($state) != null' <<<"$json" >/dev/null
}

# Poll until a window's state reaches the wanted value; rule/layout effects can
# land a manage cycle or two after the window first appears.
wait_state() {
    local app_id=$1 state=$2 wanted=$3 json=""
    for _ in $(seq 1 160); do
        json=$(window_json "$app_id")
        if [ -n "$json" ]; then
            if [ "$wanted" = true ]; then
                has_state "$json" "$state" && return 0
            else
                has_state "$json" "$state" || return 0
            fi
        fi
        sleep 0.05
    done
    ctl windows --json >&2 || true
    die "timed out waiting for $app_id state $state=$wanted"
}

# scene_line LABEL -> line number of the first scene node carrying LABEL.
scene_line() {
    ctl scene | grep -n -F "$1" | head -1 | cut -d: -f1
}

# The scene dump is a pre-order traversal with siblings ordered bottom-to-top, so
# a higher window appears on a later line. Poll until the PiP window is above the
# peer window; scene reparenting lands on a render transaction after the state.
wait_pip_above_peer() {
    local reason=$1 pip_line peer_line
    for _ in $(seq 1 100); do
        pip_line=$(scene_line "window: Picture-in-Picture")
        peer_line=$(scene_line "window: Peer window")
        if [ -n "$pip_line" ] && [ -n "$peer_line" ] && [ "$pip_line" -gt "$peer_line" ]; then
            return 0
        fi
        sleep 0.05
    done
    ctl scene >&2
    die "$reason (pip=${pip_line:-missing} peer=${peer_line:-missing})"
}

start_fixture() {
    local sync_dir=$1 app_id=$2 title=$3 mode=$4 pid_var=$5 log=$6
    mkdir -p "$sync_dir"
    XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        timeout 60 "$FIXTURE_BIN" "$sync_dir" "$app_id" "$title" "$mode" >"$log" 2>&1 &
    printf -v "$pid_var" '%s' "$!"
}

PIP_SYNC="$TEST_ROOT/pip-sync"
PEER_SYNC="$TEST_ROOT/peer-sync"

# The pop-out: browser PiP title, distinct app id, idles once mapped. The tiling
# default must not prevent the built-in fallback from floating and elevating it.
start_fixture "$PIP_SYNC" aqueous.pip-video "Picture-in-Picture" idle PIP_PID "$TEST_ROOT/pip.log"
wait_marker "$PIP_SYNC" ready
wait_window aqueous.pip-video >/dev/null
wait_state aqueous.pip-video floating true
wait_state aqueous.pip-video always_above true

# The peer: an ordinary floating window (explicit rule) which can go fullscreen.
start_fixture "$PEER_SYNC" aqueous.pip-peer "Peer window" fullscreen PEER_PID "$TEST_ROOT/peer.log"
wait_marker "$PEER_SYNC" ready
wait_window aqueous.pip-peer >/dev/null
wait_state aqueous.pip-peer floating true
wait_state aqueous.pip-peer always_above false

# Focus/raise the peer. It shares the floating band, but the PiP scene layer must
# keep the pop-out on top regardless of raise-on-focus.
XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" "$ACTIVATE_BIN" aqueous.pip-peer
wait_state aqueous.pip-peer focused true
wait_pip_above_peer "focused floating peer covered the PiP pop-out"

# Now make the peer fullscreen. Fullscreen windows live in their own scene layer
# above ordinary windows; the PiP layer must still sit above it.
touch "$PEER_SYNC/fullscreen"
wait_marker "$PEER_SYNC" fullscreen-done
wait_state aqueous.pip-peer fullscreen true
wait_state aqueous.pip-video always_above true

# The PiP scene layer must sit above the fullscreen layer, and the pop-out above
# the fullscreen peer. Poll: reparenting lands on a render transaction.
for _ in $(seq 1 100); do
    pip_layer=$(scene_line "layer: picture-in-picture")
    fullscreen_layer=$(scene_line "layer: fullscreen")
    if [ -n "$pip_layer" ] && [ -n "$fullscreen_layer" ] && [ "$pip_layer" -gt "$fullscreen_layer" ]; then
        break
    fi
    sleep 0.05
done
[ -n "$pip_layer" ] || { ctl scene >&2; die "PiP scene layer is absent"; }
[ -n "$fullscreen_layer" ] || { ctl scene >&2; die "fullscreen scene layer is absent"; }
[ "$pip_layer" -gt "$fullscreen_layer" ] || {
    ctl scene >&2
    die "PiP layer is not above the fullscreen layer (pip=$pip_layer fullscreen=$fullscreen_layer)"
}
wait_pip_above_peer "fullscreen peer covered the PiP pop-out"

touch "$PIP_SYNC/finish" "$PEER_SYNC/finish"
wait "$PIP_PID" || { cat "$TEST_ROOT/pip.log" >&2; die "PiP fixture failed"; }
wait "$PEER_PID" || { cat "$TEST_ROOT/peer.log" >&2; die "peer fixture failed"; }
PIP_PID=""
PEER_PID=""

echo "PASS: picture-in-picture stays above focused and fullscreen peers"