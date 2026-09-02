#!/usr/bin/env bash
set -euo pipefail

# Keeps one compositor-owned cursor alive while it crosses between two outputs
# with different fractional scales. This catches stale per-output images and
# selecting the scale from the previous output after an enter/leave sequence.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
THEME_SOURCE="$here/scripts/fixtures/xcursor-scale-theme.c"
POINTER_SOURCE="$here/scripts/fixtures/virtual-pointer-position.c"
POINTER_PROTOCOL="$here/protocol/upstream/wlr-virtual-pointer-unstable-v1.xml"
KEEP_ARTIFACTS=${AQUEOUS_SCALING_KEEP_ARTIFACTS:-0}

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -r "$THEME_SOURCE" ] || die "missing deterministic Xcursor theme fixture"
[ -r "$POINTER_SOURCE" ] || die "missing absolute virtual-pointer fixture"
for tool in cc grim jq magick nc pkg-config wayland-scanner; do
    have "$tool" || die "$tool is required for mixed-scale cursor tests"
done
pkg-config --exists wayland-client xcursor || \
    die "Wayland client and Xcursor development files are required"
[[ "$KEEP_ARTIFACTS" = 0 || "$KEEP_ARTIFACTS" = 1 ]] || \
    die "AQUEOUS_SCALING_KEEP_ARTIFACTS must be 0 or 1"

TEST_ROOT=$(mktemp -d /tmp/aqueous-mixed-cursor-scale.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
POINTER_PID=""

cleanup() {
    [ -z "$POINTER_PID" ] || kill "$POINTER_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$POINTER_PID" ] || wait "$POINTER_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    if [ "$KEEP_ARTIFACTS" = 1 ]; then
        echo "mixed-scale cursor artifacts: $TEST_ROOT"
    else
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT

mkdir -p "$RUNTIME/config" "$RUNTIME/home" "$TEST_ROOT/icons/default/cursors"
chmod 700 "$RUNTIME"
cc -std=c11 -Wall -Wextra -Werror -O2 "$THEME_SOURCE" \
    -o "$TEST_ROOT/theme-generator" $(pkg-config --cflags --libs xcursor)
"$TEST_ROOT/theme-generator" "$TEST_ROOT/icons/default/cursors/default"
wayland-scanner client-header "$POINTER_PROTOCOL" \
    "$TEST_ROOT/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code "$POINTER_PROTOCOL" \
    "$TEST_ROOT/wlr-virtual-pointer-unstable-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$POINTER_SOURCE" "$TEST_ROOT/wlr-virtual-pointer-unstable-v1-protocol.c" \
    -o "$TEST_ROOT/pointer-position" $(pkg-config --cflags --libs wayland-client)

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=2 \
WLR_RENDERER=pixman \
XCURSOR_PATH="$TEST_ROOT/icons" \
XCURSOR_THEME=default \
XCURSOR_SIZE=24 \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -policy internal -log-level debug \
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
output_request() { printf '%s\n' "$1" | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1; }
outputs=""
for _ in $(seq 1 100); do
    outputs=$(output_request '{"op":"list"}')
    [ "$(jq '.outputs | length' 2>/dev/null <<<"$outputs")" = 2 ] && break
    sleep 0.05
done
[ "$(jq '.outputs | length' <<<"$outputs")" = 2 ] || die "two headless outputs did not become available"
first=$(jq -r '.outputs[0].name' <<<"$outputs")
second=$(jq -r '.outputs[1].name' <<<"$outputs")

# A 1280px headless output is 1024 logical pixels wide at 1.25x. Place the
# second output exactly at that boundary and give it a substantially different
# fractional scale so stale-scale bugs cannot hide in rounding tolerance.
response=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$first\",\"scale\":1.25,\"position\":[0,0]},{\"name\":\"$second\",\"scale\":2.5,\"position\":[1024,0]}]}")
jq -e '.ok == true and .applied == 2' >/dev/null <<<"$response" || \
    die "unable to configure mixed-scale outputs: $response"

client_env=(env XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket")
mkfifo "$TEST_ROOT/pointer.commands"
"${client_env[@]}" "$TEST_ROOT/pointer-position" \
    "$TEST_ROOT/pointer.commands" 1536 576 >"$TEST_ROOT/pointer.log" 2>&1 &
POINTER_PID=$!
for _ in $(seq 1 100); do
    grep -Fq READY "$TEST_ROOT/pointer.log" 2>/dev/null && break
    sleep 0.05
done
grep -Fq READY "$TEST_ROOT/pointer.log" || die "persistent virtual pointer did not start"

position_pointer() {
    local x=$1 y=$2 state
    printf '%s %s\n' "$x" "$y" >"$TEST_ROOT/pointer.commands"
    for _ in $(seq 1 100); do
        state=$(output_request '{"op":"cursor_state"}')
        if jq -e --argjson x "$x" --argjson y "$y" \
            '((.x - $x) | fabs) < 0.01 and ((.y - $y) | fabs) < 0.01' \
            >/dev/null <<<"$state"; then
            return
        fi
        kill -0 "$POINTER_PID" 2>/dev/null || break
        sleep 0.05
    done
    cat "$TEST_ROOT/pointer.log" >&2
    die "virtual pointer did not reach $x,$y: $state"
}
position_pointer 200 200
sleep 0.15

capture_extent() {
    local output=$1 scale=$2 expected=$3 label=$4
    local cursor="$TEST_ROOT/$label-cursor.png"
    local extent
    "${client_env[@]}" grim -s "$scale" -c -o "$output" "$cursor"
    # This session has no application surfaces and the deterministic cursor is
    # the only white content. Inspect it directly: taking a cursor-excluding
    # capture first can itself transition wlroots between hardware/software
    # cursor paths and is not part of the boundary behavior under test.
    extent=$(magick "$cursor" -alpha off -colorspace gray -threshold 50% \
        -trim -format '%wx%h' info:)
    [ "$extent" = "${expected}x${expected}" ] || \
        die "$label cursor extent was $extent; expected ${expected}x${expected}"
    pass "$label rendered ${extent}"
}

capture_extent "$first" 1.25 30 "first output before crossing (1.25x)"
position_pointer 1200 200
sleep 0.15
capture_extent "$second" 2.5 60 "second output after crossing (2.5x)"
position_pointer 200 200
sleep 0.15
capture_extent "$first" 1.25 30 "first output after return crossing (1.25x)"

kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited during mixed-scale crossings"
echo "ALL MIXED-SCALE CURSOR CROSSING CHECKS PASSED"
