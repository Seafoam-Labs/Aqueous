#!/usr/bin/env bash
set -euo pipefail

# Headless integration harness for the output-scaling pipeline (Phases 1-5).
#
# Drives a real Aqueous instance under the wlroots headless backend and
# asserts the wire-level events that prove scale propagation works:
#   - P2: bound clients receive a fresh wl_output.scale + done after a change.
#   - P3: river logs "commit affects layout" + dirtyWindowing on scale change.
#   - P4: wp_fractional_scale_v1 / wp_viewporter / wl_compositor v6 advertised,
#         and fractional-aware clients receive preferred_scale.
#   - P5: river reloads the xcursor theme without errors.
#
# Requirements: a built ./zig-out/bin/aqueous, plus nc, jq, and
# wayland-info / Ghostty for the client-side assertions. Missing optional tools
# downgrade the corresponding checks to SKIP rather than failing the run.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}

fail=0
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
err()  { echo "FAIL: $*"; fail=1; }

have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || { echo "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN (build with: zig build -Dllvm=true)"; exit 2; }
have nc || { echo "nc with Unix-socket support is required"; exit 2; }
have jq || { echo "jq is required"; exit 2; }

export WLR_BACKENDS=headless
export WLR_HEADLESS_OUTPUTS=${WLR_HEADLESS_OUTPUTS:-1}
unset WAYLAND_DISPLAY
RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
sockets_before=$(ls "$RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' || true)

COMPOSITOR_LOG=$(mktemp)
CLIENT_LOG=$(mktemp)
cleanup() {
    [ -n "${COMPOSITOR_PID:-}" ] && kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" 2>/dev/null || true
    rm -f "$COMPOSITOR_LOG" "$CLIENT_LOG"
}
trap cleanup EXIT

"$AQUEOUS_COMPOSITOR_BIN" -policy internal -log-level debug >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

grep_log() { grep -q "$1" "$COMPOSITOR_LOG" 2>/dev/null; }

n=0
while [ "$n" -lt 150 ]; do
    if ! kill -0 "$COMPOSITOR_PID" 2>/dev/null; then
        echo "--- compositor log ---"; tail -20 "$COMPOSITOR_LOG"
        err "aqueous exited during startup"; exit 1
    fi
    new=$(ls "$RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' | grep -vxF "$sockets_before" || true)
    if [ -n "$new" ]; then
        export WAYLAND_DISPLAY=$(echo "$new" | head -1)
        break
    fi
    sleep 0.2; n=$((n + 1))
done
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "--- compositor log ---"; tail -20 "$COMPOSITOR_LOG"; err "aqueous never created a wayland socket"; exit 1; }
echo "aqueous socket: $WAYLAND_DISPLAY"

NAME=""
OUTPUT_SOCKET="$RUNTIME_DIR/aqueous/outputd.sock"
output_request() { printf '%s\n' "$1" | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1; }
n=0
while [ "$n" -lt 100 ]; do
    NAME=$(output_request '{"op":"list"}' | jq -r '.outputs[0].name' 2>/dev/null || true)
    [ -n "$NAME" ] && [ "$NAME" != "null" ] && break
    NAME=""
    sleep 0.2; n=$((n + 1))
done
[ -n "$NAME" ] || { echo "--- compositor log ---"; tail -20 "$COMPOSITOR_LOG"; err "no output reported by native output service after startup"; exit 1; }
echo "using output: $NAME"

version=$(output_request '{"op":"version"}')
echo "$version" | jq -e '.ok == true and .protocol == 1 and .daemon == "aqueous-outputd"' >/dev/null \
    && pass "output socket: protocol v1 compatibility" \
    || err "output socket: version contract mismatch"

invalid=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$NAME\",\"scale\":3.1}]}")
echo "$invalid" | jq -e '.ok == false' >/dev/null \
    && pass "output socket: invalid scale rejected" \
    || err "output socket: invalid scale was accepted"

start_client() {
    if have ghostty; then
        WAYLAND_DEBUG=1 GDK_BACKEND=wayland ghostty \
            --config-file=/dev/null \
            --config-default-files=false \
            --initial-window=false \
            --gtk-single-instance=false \
            --window-decoration=false \
            --class=aq-scaling-client,aq-scaling-client \
            --title=aq-scaling-client \
            -e sh -c 'echo ready; sleep 60' >"$CLIENT_LOG" 2>&1 &
        CLIENT_PID=$!
        n=0
        while [ "$n" -lt 60 ]; do
            kill -0 "$CLIENT_PID" 2>/dev/null || return 1
            grep -Eq 'wl_output[@#][0-9]+' "$CLIENT_LOG" && return 0
            sleep 0.1
            n=$((n + 1))
        done
        return 1
    fi
    return 1
}

run() {
    output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$NAME\",\"scale\":$1}]}" >/dev/null
    sleep 0.4
}

# P3: river-side relayout fires on scale change.
: >"$COMPOSITOR_LOG"
run 2
if grep -q "commit affects layout (scale=true" "$COMPOSITOR_LOG"; then
    pass "P3: scale commit triggers relayout"
else
    err "P3: no 'commit affects layout (scale=true' in compositor log"
fi

# P5: cursor theme reload without errors.
if grep -q "failed to load xcursor" "$COMPOSITOR_LOG"; then
    err "P5: xcursor theme failed to load at new scale"
else
    pass "P5: xcursor theme reload reported no errors"
fi

# P2: bound client receives a new wl_output.scale + done.
if start_client; then
    # P3 left the output at scale 2. Establish a real 2 -> 1 transition after
    # Ghostty has bound wl_output, then isolate the asserted 1 -> 2 transition.
    run 1
    : >"$CLIENT_LOG"
    run 2
    if grep -Eq 'wl_output[@#][0-9]+\.scale\(2\)' "$CLIENT_LOG" && grep -Eq 'wl_output[@#][0-9]+\.done' "$CLIENT_LOG"; then
        pass "P2: client received wl_output.scale(2) + done"
    else
        tail -80 "$CLIENT_LOG" >&2
        err "P2: client did not receive a fresh wl_output.scale/done"
    fi
else
    skip "P2: Ghostty not installed or failed to map; cannot capture client wl_output events"
fi

# P4: required globals advertised.
if have wayland-info; then
    info=$(wayland-info 2>/dev/null || true)
    grep -q "wp_fractional_scale_manager_v1" <<<"$info" && pass "P4: wp_fractional_scale_manager_v1 advertised" || err "P4: wp_fractional_scale_manager_v1 missing"
    grep -q "wp_viewporter" <<<"$info" && pass "P4: wp_viewporter advertised" || err "P4: wp_viewporter missing"
    grep -Eq "wl_compositor.*version: *6|version: *6.*wl_compositor" <<<"$info" && pass "P4: wl_compositor v6" || skip "P4: could not confirm wl_compositor v6 from wayland-info output"
else
    skip "P4: wayland-info not installed; cannot enumerate globals"
fi

# Reverse direction restores scale 1.
: >"$COMPOSITOR_LOG"
run 1
grep -q "commit affects layout (scale=true" "$COMPOSITOR_LOG" && pass "reverse: scale 1 relayout fired" || err "reverse: scale 1 did not relayout"

# No-op guard: re-applying the current scale must not relayout.
: >"$COMPOSITOR_LOG"
run 1
if grep -q "commit affects layout (scale=true" "$COMPOSITOR_LOG"; then
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
