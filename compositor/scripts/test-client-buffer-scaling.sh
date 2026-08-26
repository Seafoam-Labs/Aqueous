#!/usr/bin/env bash
set -euo pipefail

# Verifies that Aqueous publishes its client-buffer scale policy before the
# first xdg configure and inherits through popups and subsurfaces. The
# app-specific integer-ceil rules used here are an explicit test fixture and
# are not part of the default configuration.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURE_SOURCE="$here/scripts/fixtures/client-buffer-scaling.c"
RULES="$here/scripts/fixtures/client-buffer-scaling-rules.toml"
PROTOCOLS_DIR=$(pkg-config --variable=pkgdatadir wayland-protocols)
XDG_SHELL_PROTOCOL="$PROTOCOLS_DIR/stable/xdg-shell/xdg-shell.xml"
FRACTIONAL_SCALE_PROTOCOL="$PROTOCOLS_DIR/staging/fractional-scale/fractional-scale-v1.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing client-buffer scaling fixture"
[ -r "$RULES" ] || die "missing test-only client-buffer scaling rules"
for tool in cc jq nc pkg-config timeout wayland-scanner; do
    have "$tool" || die "$tool is required for client-buffer scaling tests"
done
pkg-config --exists wayland-client wayland-protocols || \
    die "Wayland client development files and protocols are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-client-buffer-scaling.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
FIXTURE_BIN="$TEST_ROOT/client-buffer-scaling"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""

cleanup() {
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

wayland-scanner client-header "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-client-protocol.h"
wayland-scanner private-code "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-protocol.c"
wayland-scanner client-header "$FRACTIONAL_SCALE_PROTOCOL" \
    "$TEST_ROOT/fractional-scale-v1-client-protocol.h"
wayland-scanner private-code "$FRACTIONAL_SCALE_PROTOCOL" \
    "$TEST_ROOT/fractional-scale-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" \
    "$TEST_ROOT/xdg-shell-protocol.c" \
    "$TEST_ROOT/fractional-scale-v1-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"
WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=vulkan \
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

OUTPUT_SOCKET="$RUNTIME/aqueous/outputd.sock"
output_request() { printf '%s\n' "$1" | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1; }
output_name=""
for _ in $(seq 1 100); do
    output_name=$(output_request '{"op":"list"}' | jq -r '.outputs[0].name // empty' 2>/dev/null || true)
    [ -n "$output_name" ] && break
    sleep 0.05
done
[ -n "$output_name" ] || die "headless output did not become available"
response=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$output_name\",\"scale\":1.25}]}")
jq -e '.ok == true' >/dev/null <<<"$response" || die "unable to set the headless output to 125%"

set_scale() {
    local scale=$1
    local result
    result=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$output_name\",\"scale\":$scale}]}")
    jq -e '.ok == true' >/dev/null <<<"$result" || die "unable to set the headless output to $scale"
}

run_probe() {
    local app_id=$1
    local expected=$2
    XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        timeout 20 "$FIXTURE_BIN" "$app_id" "$expected"
}

run_probe aqueous.scale-policy-native 150
run_probe aqueous.scale-policy-integer 240

run_transition_probe() {
    local app_id=$1
    local initial=$2
    local next=$3
    local ready="$TEST_ROOT/$app_id.ready"
    local client_log="$TEST_ROOT/$app_id.log"
    XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        timeout 20 "$FIXTURE_BIN" "$app_id" "$initial" "$next" "$ready" \
        >"$client_log" 2>&1 &
    local client_pid=$!
    for _ in $(seq 1 200); do
        kill -0 "$client_pid" 2>/dev/null || {
            cat "$client_log" >&2
            die "$app_id transition probe exited before its ready marker"
        }
        [ -f "$ready" ] && break
        sleep 0.05
    done
    [ -f "$ready" ] || die "$app_id transition probe did not become ready"
    set_scale 2.5
    if ! wait "$client_pid"; then
        cat "$client_log" >&2
        die "$app_id transition probe failed"
    fi
    cat "$client_log"
    set_scale 1.25
}

run_transition_probe aqueous.scale-policy-native 150 300
run_transition_probe aqueous.scale-policy-integer 240 360

kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
    tail -120 "$COMPOSITOR_LOG" >&2
    die "compositor exited during client-buffer scale probes"
}

echo "PASS: native remains the default; integer-ceil is enabled only by the test rule"
