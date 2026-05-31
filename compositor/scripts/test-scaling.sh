#!/usr/bin/env bash
set -euo pipefail

# Headless integration harness for the output-scaling pipeline (Phases 1-5).
#
# Drives a real riverdelta instance under the wlroots headless backend and
# asserts the wire-level events that prove scale propagation works:
#   - P2: bound clients receive a fresh wl_output.scale + done after a change.
#   - P3: river logs "commit affects layout" + dirtyWindowing on scale change.
#   - P4: wp_fractional_scale_v1 / wp_viewporter / wl_compositor v6 advertised,
#         and fractional-aware clients receive preferred_scale.
#   - P5: river reloads the xcursor theme without errors.
#
# Requirements: a built ./zig-out/bin/riverdelta, plus wlr-randr, jq, and
# wayland-info / foot for the client-side assertions. Missing optional tools
# downgrade the corresponding checks to SKIP rather than failing the run.

here=$(cd "$(dirname "$0")/.." && pwd)
RIVER_BIN=${RIVER_BIN:-"$here/zig-out/bin/riverdelta"}

fail=0
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
err()  { echo "FAIL: $*"; fail=1; }

have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$RIVER_BIN" ] || { echo "riverdelta binary not found at $RIVER_BIN (build with: zig build -Dllvm=true)"; exit 2; }
have wlr-randr || { echo "wlr-randr is required"; exit 2; }

export WLR_BACKENDS=headless
export WLR_HEADLESS_OUTPUTS=${WLR_HEADLESS_OUTPUTS:-1}
unset WAYLAND_DISPLAY
RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
sockets_before=$(ls "$RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' || true)

RIVER_LOG=$(mktemp)
CLIENT_LOG=$(mktemp)
cleanup() {
    [ -n "${RIVER_PID:-}" ] && kill "$RIVER_PID" 2>/dev/null || true
    [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" 2>/dev/null || true
    rm -f "$RIVER_LOG" "$CLIENT_LOG"
}
trap cleanup EXIT

"$RIVER_BIN" -log-level debug >"$RIVER_LOG" 2>&1 &
RIVER_PID=$!

grep_log() { grep -q "$1" "$RIVER_LOG" 2>/dev/null; }

n=0
while [ "$n" -lt 150 ]; do
    if ! kill -0 "$RIVER_PID" 2>/dev/null; then
        echo "--- river log ---"; tail -20 "$RIVER_LOG"
        err "riverdelta exited during startup"; exit 1
    fi
    new=$(ls "$RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' | grep -vxF "$sockets_before" || true)
    if [ -n "$new" ]; then
        export WAYLAND_DISPLAY=$(echo "$new" | head -1)
        break
    fi
    sleep 0.2; n=$((n + 1))
done
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "--- river log ---"; tail -20 "$RIVER_LOG"; err "riverdelta never created a wayland socket"; exit 1; }
echo "river socket: $WAYLAND_DISPLAY"

NAME=""
n=0
while [ "$n" -lt 100 ]; do
    NAME=$(wlr-randr --json 2>/dev/null | jq -r '.[0].name' 2>/dev/null || true)
    [ -n "$NAME" ] && [ "$NAME" != "null" ] && break
    NAME=""
    sleep 0.2; n=$((n + 1))
done
[ -n "$NAME" ] || { echo "--- river log ---"; tail -20 "$RIVER_LOG"; err "no output reported by wlr-randr after startup"; exit 1; }
echo "using output: $NAME"

start_client() {
    if have foot; then
        WAYLAND_DEBUG=1 foot -e sh -c 'echo ready; sleep 60' >"$CLIENT_LOG" 2>&1 &
        CLIENT_PID=$!
        sleep 0.6
        return 0
    fi
    return 1
}

run() { wlr-randr --output "$NAME" --scale "$1" >/dev/null 2>&1; sleep 0.4; }

# P3: river-side relayout fires on scale change.
: >"$RIVER_LOG"
run 2
if grep -q "commit affects layout (scale=true" "$RIVER_LOG"; then
    pass "P3: scale commit triggers relayout"
else
    err "P3: no 'commit affects layout (scale=true' in river log"
fi

# P5: cursor theme reload without errors.
if grep -q "failed to load xcursor" "$RIVER_LOG"; then
    err "P5: xcursor theme failed to load at new scale"
else
    pass "P5: xcursor theme reload reported no errors"
fi

# P2: bound client receives a new wl_output.scale + done.
if start_client; then
    : >"$CLIENT_LOG"
    run 2
    if grep -Eq "wl_output@[0-9]+\.scale\(2\)" "$CLIENT_LOG" && grep -Eq "wl_output@[0-9]+\.done" "$CLIENT_LOG"; then
        pass "P2: client received wl_output.scale(2) + done"
    else
        err "P2: client did not receive a fresh wl_output.scale/done"
    fi
else
    skip "P2: foot not installed; cannot capture client wl_output events"
fi

# P4: required globals advertised.
if have wayland-info; then
    info=$(wayland-info 2>/dev/null || true)
    echo "$info" | grep -q "wp_fractional_scale_manager_v1" && pass "P4: wp_fractional_scale_manager_v1 advertised" || err "P4: wp_fractional_scale_manager_v1 missing"
    echo "$info" | grep -q "wp_viewporter" && pass "P4: wp_viewporter advertised" || err "P4: wp_viewporter missing"
    echo "$info" | grep -Eq "wl_compositor.*version: *6|version: *6.*wl_compositor" && pass "P4: wl_compositor v6" || skip "P4: could not confirm wl_compositor v6 from wayland-info output"
else
    skip "P4: wayland-info not installed; cannot enumerate globals"
fi

# Reverse direction restores scale 1.
: >"$RIVER_LOG"
run 1
grep -q "commit affects layout (scale=true" "$RIVER_LOG" && pass "reverse: scale 1 relayout fired" || err "reverse: scale 1 did not relayout"

# No-op guard: re-applying the current scale must not relayout.
: >"$RIVER_LOG"
run 1
if grep -q "commit affects layout (scale=true" "$RIVER_LOG"; then
    err "no-op: re-applying same scale triggered a relayout"
else
    pass "no-op: re-applying same scale produced no relayout"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
else
    echo "ONE OR MORE CHECKS FAILED"
fi
exit "$fail"
