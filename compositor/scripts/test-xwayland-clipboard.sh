#!/usr/bin/env bash
set -euo pipefail

# End-to-end regression for Seafoam-Labs/Aqueous#174. Copying from an X11 client
# (Steam/CEF) into a Wayland client, and pasting from a Wayland client into an
# X11 client, must both work even when no XWayland surface holds focus. wlroots
# used to gate both directions on xwm->focus_surface, which silently dropped the
# transfer because the selection round-trip completes after focus has moved.
#
# The fixture never takes focus: the X11 owner uses an InputOnly window, the X11
# reader an unmapped window, and the Wayland side uses ext-data-control.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURE_SOURCE="$here/scripts/fixtures/xwayland-clipboard.c"
DATA_CONTROL_PROTOCOL="$here/protocol/upstream/ext-data-control-v1.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || \
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN (build with: zig build -Dxwayland)"
[ -r "$FIXTURE_SOURCE" ] || die "missing X11/Wayland clipboard fixture"
[ -r "$DATA_CONTROL_PROTOCOL" ] || die "missing ext-data-control-v1 protocol"
for tool in cc pkg-config wayland-scanner Xwayland; do
    have "$tool" || die "$tool is required for the Xwayland clipboard integration test"
done
pkg-config --exists x11 || die "X11 development files are required"
pkg-config --exists wayland-client || die "Wayland client development files are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-xwayland-clipboard.XXXXXX)
FIXTURE_BIN="$TEST_ROOT/xwayland-clipboard"
COMPOSITOR_PID=""
COMPOSITOR_LOG=""

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

wayland-scanner client-header "$DATA_CONTROL_PROTOCOL" \
    "$TEST_ROOT/ext-data-control-v1-client-protocol.h"
wayland-scanner private-code "$DATA_CONTROL_PROTOCOL" \
    "$TEST_ROOT/ext-data-control-v1-protocol.c"
cc -std=gnu11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" "$TEST_ROOT/ext-data-control-v1-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs x11 wayland-client)

# Runs as the compositor's -c child (inherits WAYLAND_DISPLAY and DISPLAY).
# Args: direction fixture payload resultfile workdir
cat > "$TEST_ROOT/inner.sh" <<'EOF'
#!/bin/bash
DIRECTION="$1"; FIX="$2"; PAYLOAD="$3"; RESULT="$4"; WORK="$5"
for i in $(seq 1 200); do
    [ -n "$DISPLAY" ] && [ -n "$WAYLAND_DISPLAY" ] && break
    sleep 0.05
done
if [ "$DIRECTION" = incoming ]; then
    "$FIX" x11-own "$PAYLOAD" > "$WORK/owner.log" 2>&1 &
else
    "$FIX" wl-own "$PAYLOAD" > "$WORK/owner.log" 2>&1 &
fi
OWNER=$!
for i in $(seq 1 200); do
    grep -q READY "$WORK/owner.log" 2>/dev/null && break
    sleep 0.05
done
# Let the compositor complete the asynchronous selection bridge.
sleep 0.5
if [ "$DIRECTION" = incoming ]; then
    timeout 10 "$FIX" wl-read > "$RESULT" 2>&1
else
    timeout 10 "$FIX" x11-read > "$RESULT" 2>&1
fi
kill "$OWNER" 2>/dev/null
echo DONE > "$WORK/done"
EOF

run_case() {
    local direction=$1
    local work="$TEST_ROOT/$direction-work"
    local runtime="$TEST_ROOT/$direction-runtime"
    local result="$TEST_ROOT/$direction-result"
    local payload="aqueous-174-$direction"
    mkdir -p "$work" "$runtime/config" "$runtime/home"
    chmod 700 "$runtime"
    local n
    for n in config rules outputs input layout; do : > "$runtime/$n.toml"; done
    COMPOSITOR_LOG="$TEST_ROOT/$direction-compositor.log"

    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman \
    XDG_RUNTIME_DIR="$runtime" XDG_CONFIG_HOME="$runtime/config" HOME="$runtime/home" \
    AQUEOUS_CONFIG="$runtime/config.toml" AQUEOUS_RULES="$runtime/rules.toml" \
    AQUEOUS_OUTPUTS="$runtime/outputs.toml" AQUEOUS_INPUT="$runtime/input.toml" \
    AQUEOUS_LAYOUT="$runtime/layout.toml" \
        "$AQUEOUS_COMPOSITOR_BIN" -policy internal -log-level debug \
        -c "bash $TEST_ROOT/inner.sh $direction $FIXTURE_BIN $payload $result $work" \
        >"$COMPOSITOR_LOG" 2>&1 &
    COMPOSITOR_PID=$!

    local i=0
    while [ "$i" -lt 400 ]; do
        [ -f "$work/done" ] && break
        if ! kill -0 "$COMPOSITOR_PID" 2>/dev/null; then
            tail -120 "$COMPOSITOR_LOG" >&2 || true
            die "$direction compositor exited before the clipboard transfer completed"
        fi
        sleep 0.1
        i=$((i + 1))
    done
    [ -f "$work/done" ] || { tail -120 "$COMPOSITOR_LOG" >&2; die "$direction timed out"; }
    cleanup_session

    local got denial
    got=$(cat "$result" 2>/dev/null || true)
    if [ "$direction" = incoming ]; then
        denial=$(grep -c 'denying write access to clipboard' "$COMPOSITOR_LOG" || true)
    else
        denial=$(grep -c 'denying read access to selection' "$COMPOSITOR_LOG" || true)
    fi
    [ "$denial" = 0 ] || die "$direction focus gate still denied the transfer ($denial denial(s))"
    [ "$got" = "DATA=$payload" ] || \
        die "$direction expected 'DATA=$payload', got '$got' (see $COMPOSITOR_LOG)"
    echo "PASS: $direction clipboard bridge without XWayland focus"
}

run_case incoming
run_case outgoing
echo "ALL XWAYLAND CLIPBOARD CHECKS PASSED"