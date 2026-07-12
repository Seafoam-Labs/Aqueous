#!/usr/bin/env bash
set -euo pipefail

# End-to-end smoke/regression test for the opt-in canvas path. It maps real
# Wayland clients, changes camera scale through compositor keybindings, and
# verifies reset restores logical placement without destabilizing the session.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURES="$here/scripts/fixtures"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
for tool in ghostty grim wlrctl; do have "$tool" || die "$tool is required for the canvas integration test"; done

TEST_ROOT=$(mktemp -d /tmp/aqueous-canvas.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
CLIENT_PIDS=()
cleanup() {
    for pid in "${CLIENT_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"
WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$FIXTURES/canvas-wm.toml" \
AQUEOUS_MOD=Super \
GDK_BACKEND=wayland \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -log-level info -c true >"$LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 160); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || { tail -80 "$LOG" >&2; die "compositor exited during startup"; }
    socket=$(find "$RUNTIME" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"
export XDG_RUNTIME_DIR="$RUNTIME" XDG_CONFIG_HOME="$RUNTIME/config" HOME="$RUNTIME/home"
export WAYLAND_DISPLAY="$socket" GDK_BACKEND=wayland

trace_line() { grep 'source=internal phase=render_finish' "$LOG" 2>/dev/null | tail -1; }
trace_field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; }
wait_windows() {
    local wanted=$1
    for _ in $(seq 1 200); do
        local value
        value=$(trace_field "$(trace_line || true)" windows)
        [ "$value" = "$wanted" ] && return 0
        sleep 0.05
    done
    die "timed out waiting for windows=$wanted"
}
wait_geometry() {
    local relation=$1 wanted=$2
    for _ in $(seq 1 160); do
        local value
        value=$(trace_field "$(trace_line || true)" geometry)
        if { [ "$relation" = eq ] && [ "$value" = "$wanted" ]; } ||
           { [ "$relation" = ne ] && [ -n "$value" ] && [ "$value" != "$wanted" ]; }; then return 0; fi
        sleep 0.05
    done
    local final
    final=$(trace_field "$(trace_line || true)" geometry)
    tail -40 "$LOG" >&2
    die "timed out waiting for geometry $relation $wanted (last=${final:-none})"
}
stable_geometry() {
    local previous="" stable=0 value
    for _ in $(seq 1 160); do
        value=$(trace_field "$(trace_line || true)" geometry)
        if [ -n "$value" ] && [ "$value" = "$previous" ]; then
            stable=$((stable + 1))
            if [ "$stable" -ge 3 ]; then echo "$value"; return 0; fi
        else
            previous=$value
            stable=0
        fi
        sleep 0.05
    done
    die "geometry did not settle"
}

for identity in aq-canvas-one aq-canvas-two; do
    ghostty \
        --config-file="$FIXTURES/ghostty.conf" \
        --config-default-files=false \
        --gtk-single-instance=false \
        --window-decoration=false \
        --class="$identity,$identity" \
        --title="$identity" \
        -e sh -c 'i=0; while :; do printf "\rframe %d" "$i"; i=$((i + 1)); sleep 0.1; done' >/dev/null 2>&1 &
    CLIENT_PIDS+=("$!")
done
wait_windows 2

baseline=$(stable_geometry)
grim "$TEST_ROOT/pre-0.png"
sleep 0.4
grim "$TEST_ROOT/pre-1.png"
cmp -s "$TEST_ROOT/pre-0.png" "$TEST_ROOT/pre-1.png" && die "animated test clients did not repaint before zoom"
wlrctl keyboard type o modifiers SUPER
wait_geometry ne "$baseline"
kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited after canvas zoom"

wlrctl pointer move 500 350
kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited during scaled hit testing"

# The test terminals print a changing frame counter. A surface that stops
# receiving frame callbacks produces identical captures indefinitely.
grim "$TEST_ROOT/frame-0.png"
repainted=false
for frame in $(seq 1 12); do
    sleep 0.2
    grim "$TEST_ROOT/frame-$frame.png"
    if ! cmp -s "$TEST_ROOT/frame-0.png" "$TEST_ROOT/frame-$frame.png"; then
        repainted=true
        break
    fi
done
if [ "$repainted" != true ]; then
    tail -80 "$LOG" >&2
    die "scaled clients stopped repainting after zoom"
fi

wlrctl keyboard type p modifiers SUPER
wait_geometry eq "$baseline"

if grep -Eq 'panic|segmentation fault|use-after-free' "$LOG"; then
    tail -80 "$LOG" >&2
    die "fatal error reported by canvas session"
fi

echo "canvas integration passed: real clients mapped, zoomed, hit-tested, and reset"
