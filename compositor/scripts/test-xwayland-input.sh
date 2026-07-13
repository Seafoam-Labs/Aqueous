#!/usr/bin/env bash
set -euo pipefail

# End-to-end regression for X11 game input. The fixture uses an active X11
# keyboard grab and a pointer grab confined to its window. Xwayland translates
# those into zwp_xwayland_keyboard_grab_v1 and zwp_pointer_constraints_v1.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/xwayland-input-grab.c"
VIRTUAL_KEYBOARD_PROTOCOL="$here/protocol/upstream/virtual-keyboard-unstable-v1.xml"
VIRTUAL_POINTER_PROTOCOL="$here/protocol/upstream/wlr-virtual-pointer-unstable-v1.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || \
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN (build with: zig build -Dxwayland)"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing X11 input-grab fixture"
for tool in cc pkg-config wayland-scanner Xwayland wlrctl; do
    have "$tool" || die "$tool is required for Xwayland input integration tests"
done
pkg-config --exists x11 || die "X11 development files are required"
pkg-config --exists wayland-client xkbcommon || \
    die "Wayland client and xkbcommon development files are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-xwayland-input.XXXXXX)
FIXTURE_BIN="$TEST_ROOT/xwayland-input-grab"
COMPOSITOR_PID=""

cleanup_session() {
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    COMPOSITOR_PID=""
}
cleanup() {
    cleanup_session
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

wayland-scanner client-header "$VIRTUAL_KEYBOARD_PROTOCOL" \
    "$TEST_ROOT/virtual-keyboard-unstable-v1-client-protocol.h"
wayland-scanner private-code "$VIRTUAL_KEYBOARD_PROTOCOL" \
    "$TEST_ROOT/virtual-keyboard-unstable-v1-protocol.c"
wayland-scanner client-header "$VIRTUAL_POINTER_PROTOCOL" \
    "$TEST_ROOT/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code "$VIRTUAL_POINTER_PROTOCOL" \
    "$TEST_ROOT/wlr-virtual-pointer-unstable-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" \
    "$TEST_ROOT/virtual-keyboard-unstable-v1-protocol.c" \
    "$TEST_ROOT/wlr-virtual-pointer-unstable-v1-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs x11 wayland-client xkbcommon)

wait_for_text() {
    local file=$1 text=$2 description=$3 n=0
    while [ "$n" -lt 200 ]; do
        if grep -Fq "$text" "$file" 2>/dev/null; then
            return 0
        fi
        if [ -n "$COMPOSITOR_PID" ] && ! kill -0 "$COMPOSITOR_PID" 2>/dev/null; then
            tail -120 "$COMPOSITOR_LOG" >&2 || true
            tail -80 "$CLIENT_LOG" >&2 || true
            die "compositor exited while waiting for $description"
        fi
        sleep 0.05
        n=$((n + 1))
    done
    tail -120 "$COMPOSITOR_LOG" >&2 || true
    tail -80 "$CLIENT_LOG" >&2 || true
    die "timed out waiting for $description"
}

run_case() {
    local mode=$1
    local runtime="$TEST_ROOT/$mode-runtime"
    local socket="" n=0
    mkdir -p "$runtime/config" "$runtime/home"
    chmod 700 "$runtime"
    COMPOSITOR_LOG="$TEST_ROOT/$mode-compositor.log"
    CLIENT_LOG="$TEST_ROOT/$mode-client.log"

    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    WLR_RENDERER=pixman \
    XDG_RUNTIME_DIR="$runtime" \
    XDG_CONFIG_HOME="$runtime/config" \
    HOME="$runtime/home" \
        "$AQUEOUS_COMPOSITOR_BIN" -policy internal -log-level debug \
        -c "$FIXTURE_BIN $mode >$CLIENT_LOG 2>&1" \
        >"$COMPOSITOR_LOG" 2>&1 &
    COMPOSITOR_PID=$!

    while [ "$n" -lt 200 ]; do
        if ! kill -0 "$COMPOSITOR_PID" 2>/dev/null; then
            tail -120 "$COMPOSITOR_LOG" >&2 || true
            die "compositor failed during $mode startup"
        fi
        socket=$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
        [ -n "$socket" ] && break
        sleep 0.05
        n=$((n + 1))
    done
    [ -n "$socket" ] || die "$mode compositor did not create a Wayland socket"
    export XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$socket"

    wait_for_text "$CLIENT_LOG" "READY mode=$mode" "$mode X11 window to map"

    if [ "$mode" = managed ]; then
        local info_json rule_snippet
        info_json=$("$AQUEOUSCTL_BIN" windows --json)
        grep -q '"backend":"xwayland"' <<<"$info_json" || die "aqueousctl omitted the XWayland backend"
        grep -q '"class":"AqueousXwaylandGrabTest"' <<<"$info_json" || die "aqueousctl omitted WM_CLASS"
        rule_snippet=$("$AQUEOUSCTL_BIN" inspect --rule)
        grep -q 'class = "AqueousXwaylandGrabTest"' <<<"$rule_snippet" || die "aqueousctl did not generate an XWayland class rule"
    fi

    wait_for_text "$CLIENT_LOG" "GRABBED pointer=0 keyboard=0" "$mode X11 grabs"
    # Override-redirect MapNotify can precede the compositor's scene-map
    # callback. A post-map motion establishes pointer focus in that ordering.
    wlrctl pointer move 1 1
    wait_for_text "$COMPOSITOR_LOG" "honoring Xwayland keyboard grab" "$mode Wayland keyboard grab"
    if [ "$mode" = managed ]; then
        wait_for_text "$COMPOSITOR_LOG" "activating pointer constraint" "$mode pointer constraint"
    else
        wait_for_text "$COMPOSITOR_LOG" "Xwayland grab-focus override-redirect" \
            "$mode grab-focus synchronization"
    fi

    wlrctl keyboard type x
    wait_for_text "$CLIENT_LOG" "KEY keycode=" "$mode keyboard delivery"
    wait_for_text "$CLIENT_LOG" "RELEASED" "$mode grab release"
    wait_for_text "$COMPOSITOR_LOG" "released Xwayland keyboard grab" "$mode protocol grab cleanup"

    kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor crashed after the $mode grab"
    cleanup_session
    if [ "$mode" = managed ]; then
        echo "PASS: managed X11 keyboard and confined-pointer grabs"
    else
        echo "PASS: override-redirect X11 keyboard grab and grab-focus"
    fi
}

run_case managed
run_case override
echo "ALL XWAYLAND INPUT CHECKS PASSED"
