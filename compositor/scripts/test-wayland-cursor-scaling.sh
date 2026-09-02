#!/usr/bin/env bash
set -euo pipefail

# Pixel-accurate validation for cursor surfaces supplied by a native Wayland
# application. The fixture follows the normal fractional-scale + viewporter
# path: it renders a ceil-scaled buffer and keeps a 24x24 logical destination.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURE_SOURCE="$here/scripts/fixtures/wayland-cursor-scale.c"
PROTOCOLS_DIR=$(pkg-config --variable=pkgdatadir wayland-protocols)
KEEP_ARTIFACTS=${AQUEOUS_SCALING_KEEP_ARTIFACTS:-0}

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing Wayland cursor fixture"
for tool in cc grim jq magick nc pkg-config wayland-scanner wlrctl; do
    have "$tool" || die "$tool is required for Wayland cursor scaling tests"
done
pkg-config --exists wayland-client wayland-protocols || \
    die "Wayland client development files and protocols are required"
[[ "$KEEP_ARTIFACTS" = 0 || "$KEEP_ARTIFACTS" = 1 ]] || \
    die "AQUEOUS_SCALING_KEEP_ARTIFACTS must be 0 or 1"

TEST_ROOT=$(mktemp -d /tmp/aqueous-wayland-cursor-scale.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
FIXTURE_BIN="$TEST_ROOT/wayland-cursor-scale"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
CLIENT_LOG="$TEST_ROOT/client.log"
COMPOSITOR_PID=""
CLIENT_PID=""

cleanup() {
    [ -z "$CLIENT_PID" ] || kill "$CLIENT_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$CLIENT_PID" ] || wait "$CLIENT_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    if [ "$KEEP_ARTIFACTS" = 1 ]; then
        echo "Wayland cursor scaling artifacts: $TEST_ROOT"
    else
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT

generate_protocol() {
    local xml=$1 name=$2
    wayland-scanner client-header "$xml" "$TEST_ROOT/$name-client-protocol.h"
    wayland-scanner private-code "$xml" "$TEST_ROOT/$name-protocol.c"
}
generate_protocol "$PROTOCOLS_DIR/stable/xdg-shell/xdg-shell.xml" xdg-shell
generate_protocol "$PROTOCOLS_DIR/staging/fractional-scale/fractional-scale-v1.xml" fractional-scale-v1
generate_protocol "$PROTOCOLS_DIR/stable/viewporter/viewporter.xml" viewporter
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" \
    "$TEST_ROOT/xdg-shell-protocol.c" \
    "$TEST_ROOT/fractional-scale-v1-protocol.c" \
    "$TEST_ROOT/viewporter-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"
WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
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
output_name=""
for _ in $(seq 1 100); do
    output_name=$(output_request '{"op":"list"}' | jq -r '.outputs[0].name // empty' 2>/dev/null || true)
    [ -n "$output_name" ] && break
    sleep 0.05
done
[ -n "$output_name" ] || die "headless output did not become available"

XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
    "$FIXTURE_BIN" >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!
for _ in $(seq 1 200); do
    kill -0 "$CLIENT_PID" 2>/dev/null || {
        cat "$CLIENT_LOG" >&2
        die "Wayland fixture exited before mapping"
    }
    grep -Fq MAPPED "$CLIENT_LOG" 2>/dev/null && break
    sleep 0.05
done
grep -Fq MAPPED "$CLIENT_LOG" || die "Wayland fixture did not map"

client_env=(env XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket")
"${client_env[@]}" wlrctl pointer move -10000 -10000
"${client_env[@]}" wlrctl pointer move 200 200
for _ in $(seq 1 100); do
    grep -Fq ENTER "$CLIENT_LOG" 2>/dev/null && break
    sleep 0.05
done
grep -Fq ENTER "$CLIENT_LOG" || die "pointer did not enter the Wayland fixture"

set_scale() {
    local scale=$1 response
    response=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$output_name\",\"scale\":$scale}]}")
    jq -e '.ok == true' >/dev/null <<<"$response" || die "unable to set output scale to $scale: $response"
}

wait_for_cursor_buffer() {
    local preferred=$1 pixels=$2
    local text="CURSOR preferred=$preferred buffer=${pixels}x${pixels} logical=24x24"
    for _ in $(seq 1 100); do
        grep -Fq "$text" "$CLIENT_LOG" 2>/dev/null && return 0
        kill -0 "$CLIENT_PID" 2>/dev/null || break
        sleep 0.05
    done
    cat "$CLIENT_LOG" >&2
    die "client did not render the expected cursor buffer: $text"
}

capture_extent() {
    local scale=$1 preferred=$2 backing=$3 expected=$4 label=$5
    local plain="$TEST_ROOT/$label-plain.png"
    local cursor="$TEST_ROOT/$label-cursor.png"
    local extent
    set_scale "$scale"
    wait_for_cursor_buffer "$preferred" "$backing"
    sleep 0.15
    "${client_env[@]}" grim -s "$scale" -o "$output_name" "$plain"
    "${client_env[@]}" grim -s "$scale" -c -o "$output_name" "$cursor"
    extent=$(magick "$plain" "$cursor" -compose difference -composite \
        -alpha off -colorspace gray -threshold 50% -trim -format '%wx%h' info:)
    [ "$extent" = "${expected}x${expected}" ] || \
        die "24 logical px client cursor rendered $extent at ${scale}x; expected ${expected}x${expected}"
    pass "Wayland client cursor: preferred=$preferred/120, backing=${backing}px, rendered=${extent} at ${scale}x"
}

# wlroots never asks client surfaces to render below 1x; the compositor
# downsamples the 24px buffer on sub-1x outputs. Above 1x, this checks the exact
# fractional preferred scale and the app-style ceil-sized backing buffer.
capture_extent 0.5 120 24 12 050
capture_extent 0.75 120 24 18 075
capture_extent 1 120 24 24 100
capture_extent 1.25 150 30 30 125
capture_extent 1.5 180 36 36 150
capture_extent 1.75 210 42 42 175
capture_extent 2 240 48 48 200
capture_extent 2.5 300 60 60 250
capture_extent 3 360 72 72 300

kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited during Wayland cursor checks"
echo "ALL WAYLAND CLIENT CURSOR SCALING CHECKS PASSED"
