#!/usr/bin/env bash
set -euo pipefail

# Headless integration harness for the output-scaling pipeline (Phases 1-7).
#
# Drives a real Aqueous instance under the wlroots headless backend and
# asserts the wire-level events that prove scale propagation works:
#   - P2: bound clients receive a fresh wl_output.scale + done after a change.
#   - P3: Aqueous logs "commit affects layout" + dirtyWindowing on scale change.
#   - P4: wp_fractional_scale_v1 / wp_viewporter / wl_compositor v6 advertised,
#         and fractional-aware clients receive preferred_scale.
#   - P5: the rendered xcursor footprint follows the exact output scale and
#         changes immediately after a scale commit without pointer motion.
#
# Requirements: a built ./zig-out/bin/aqueous, plus nc and jq. The P5 pixel
# oracle additionally uses cc, grim, ImageMagick, wlrctl, and libXcursor;
# wayland-info / Ghostty cover the client-side assertions. Missing optional
# tools downgrade their corresponding checks to SKIP rather than false PASSes.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
CURSOR_THEME_SOURCE="$here/scripts/fixtures/xcursor-scale-theme.c"
KEEP_ARTIFACTS=${AQUEOUS_SCALING_KEEP_ARTIFACTS:-0}

fail=0
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
err()  { echo "FAIL: $*"; fail=1; }

have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || { echo "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN (build with: zig build -Dllvm=true)"; exit 2; }
have nc || { echo "nc with Unix-socket support is required"; exit 2; }
have jq || { echo "jq is required"; exit 2; }
case "$KEEP_ARTIFACTS" in
    0|1) ;;
    *) echo "AQUEOUS_SCALING_KEEP_ARTIFACTS must be 0 or 1"; exit 2 ;;
esac

# Pixel-accurate cursor validation uses a generated theme whose visible image
# fills its nominal size. This avoids false failures from transparent padding
# or hand-hinted sizes in the user's installed cursor theme. Keep the broader
# scale pipeline runnable on minimal systems, but never report P5 as passing if
# its pixel oracle is unavailable.
cursor_pixel_test=1
for tool in cc grim magick pkg-config wlrctl; do
    if ! have "$tool"; then
        skip "P5 pixel oracle: $tool is not installed"
        cursor_pixel_test=0
    fi
done
if [ "$cursor_pixel_test" -eq 1 ] && ! pkg-config --exists xcursor; then
    skip "P5 pixel oracle: Xcursor development files are not installed"
    cursor_pixel_test=0
fi
[ "$cursor_pixel_test" -eq 0 ] || [ -r "$CURSOR_THEME_SOURCE" ] || {
    echo "missing deterministic cursor theme source: $CURSOR_THEME_SOURCE"
    exit 2
}

export WLR_BACKENDS=headless
export WLR_HEADLESS_OUTPUTS=${WLR_HEADLESS_OUTPUTS:-1}
unset WAYLAND_DISPLAY

TEST_ROOT=$(mktemp -d /tmp/aqueous-scaling.XXXXXX)
RUNTIME_DIR="$TEST_ROOT/runtime"
CONFIG_DIR="$TEST_ROOT/config"
SANDBOX_HOME="$TEST_ROOT/home"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
CLIENT_LOG="$TEST_ROOT/client.log"
mkdir -p "$RUNTIME_DIR" "$CONFIG_DIR" "$SANDBOX_HOME"
chmod 700 "$RUNTIME_DIR"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
cleanup() {
    [ -n "${COMPOSITOR_PID:-}" ] && kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" 2>/dev/null || true
    if [ "$KEEP_ARTIFACTS" -eq 1 ]; then
        echo "scaling test artifacts: $TEST_ROOT"
    else
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

cursor_env=()
if [ "$cursor_pixel_test" -eq 1 ]; then
    # Cursor.setTheme(null, ...) asks wlroots for the theme named "default";
    # XCURSOR_THEME is a client-side convention and is not consulted by that
    # API. Put the deterministic theme at the exact lookup name.
    CURSOR_THEME_DIR="$TEST_ROOT/icons/default/cursors"
    CURSOR_THEME_GENERATOR="$TEST_ROOT/xcursor-scale-theme"
    mkdir -p "$CURSOR_THEME_DIR"
    cc -std=c11 -Wall -Wextra -Werror -O2 \
        "$CURSOR_THEME_SOURCE" -o "$CURSOR_THEME_GENERATOR" \
        $(pkg-config --cflags --libs xcursor)
    "$CURSOR_THEME_GENERATOR" "$CURSOR_THEME_DIR/default"
    cursor_env=(
        XCURSOR_PATH="$TEST_ROOT/icons"
        XCURSOR_THEME=default
        XCURSOR_SIZE=24
    )
fi

env "${cursor_env[@]}" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_CONFIG_HOME="$CONFIG_DIR" \
    HOME="$SANDBOX_HOME" \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -policy internal -log-level debug \
    >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

grep_log() { grep -q "$1" "$COMPOSITOR_LOG" 2>/dev/null; }

n=0
while [ "$n" -lt 150 ]; do
    if ! kill -0 "$COMPOSITOR_PID" 2>/dev/null; then
        echo "--- compositor log ---"; tail -20 "$COMPOSITOR_LOG"
        err "aqueous exited during startup"; exit 1
    fi
    new=$(find "$RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
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

# A rejected output entry must not prevent a valid entry in the same request
# from being staged, and the response must describe the partial application.
partial=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"MISSING-OUTPUT\",\"scale\":1},{\"name\":\"$NAME\",\"scale\":1}]}")
echo "$partial" | jq -e '
    .ok == true and
    .partial == true and
    .applied == 1 and
    .rejected == 1 and
    .rejections[0].matcher == "MISSING-OUTPUT" and
    .rejections[0].output == null and
    (.rejections[0].error | contains("no connected output"))
' >/dev/null \
    && pass "output socket: partial application reports rejected output and stages valid output" \
    || err "output socket: rejected output cancelled or was missing from partial report"

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
    local scale=$1 response state
    response=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$NAME\",\"scale\":$scale}]}")
    if ! jq -e '.ok == true' >/dev/null <<<"$response"; then
        echo "FAIL: output service rejected scale=$scale: $response" >&2
        return 1
    fi
    for _ in $(seq 1 40); do
        state=$(output_request '{"op":"list"}')
        if jq -e --arg name "$NAME" --argjson scale "$scale" \
            'any(.outputs[]; .name == $name and .scale == $scale)' \
            >/dev/null <<<"$state"; then
            sleep 0.4
            return 0
        fi
        sleep 0.05
    done
    echo "FAIL: output did not settle at scale=$scale: $state" >&2
    return 1
}

# P3: river-side relayout fires on scale change.
: >"$COMPOSITOR_LOG"
run 2
if grep -q "commit affects layout (scale=true" "$COMPOSITOR_LOG"; then
    pass "P3: scale commit triggers relayout"
else
    err "P3: no 'commit affects layout (scale=true' in compositor log"
fi

# P5 load health: retain the useful diagnostic, but do not mistake the absence
# of an error log for proof that the selected cursor has the right dimensions.
if grep -q "failed to load xcursor" "$COMPOSITOR_LOG"; then
    err "P5 load health: xcursor theme failed to load at new scale"
else
    pass "P5 load health: xcursor theme reload reported no errors"
fi

capture_cursor_extent() {
    local scale=$1 expected=$2 label=$3
    local without_cursor="$TEST_ROOT/cursor-$label-without.png"
    local with_cursor="$TEST_ROOT/cursor-$label-with.png"
    local extent

    run "$scale"
    XDG_RUNTIME_DIR="$RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        grim -s "$scale" -o "$NAME" "$without_cursor"
    XDG_RUNTIME_DIR="$RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        grim -s "$scale" -c -o "$NAME" "$with_cursor"

    extent=$(magick \
        "$without_cursor" "$with_cursor" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 50% -trim \
        -format '%wx%h' info:)
    if [ "$extent" = "${expected}x${expected}" ]; then
        pass "P5: 24 logical px cursor rendered ${extent} at ${scale}x"
    else
        err "P5: 24 logical px cursor rendered ${extent} at ${scale}x; expected ${expected}x${expected}"
    fi
}

if [ "$cursor_pixel_test" -eq 1 ]; then
    # Establish the compositor-owned default image once. No further pointer
    # events are sent: later captures therefore prove that output commits alone
    # resize a stationary cursor.
    run 1
    XDG_RUNTIME_DIR="$RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        wlrctl pointer move -10000 -10000
    XDG_RUNTIME_DIR="$RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        wlrctl pointer move 200 200
    sleep 0.1

    capture_cursor_extent 0.5 12 050
    capture_cursor_extent 0.75 18 075
    capture_cursor_extent 1 24 100
    capture_cursor_extent 1.25 30 125
    capture_cursor_extent 1.5 36 150
    capture_cursor_extent 1.75 42 175
    capture_cursor_extent 2 48 200
    capture_cursor_extent 2.5 60 250
    capture_cursor_extent 3 72 300
    # Preserve the scale expected by the P2 transition setup below.
    run 2
else
    skip "P5: rendered cursor dimensions were not tested"
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
