#!/usr/bin/env bash
set -euo pipefail

# Regression for application-originated xdg_toplevel fullscreen requests under
# integrated policy. This deliberately does not use a rule or compositor
# keybinding: it follows the same xdg-shell path as Firefox video fullscreen.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/xdg-fullscreen-request.c"
XDG_SHELL_PROTOCOL="$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing xdg fullscreen fixture"
for tool in cc pkg-config timeout wayland-scanner; do
    have "$tool" || die "$tool is required for xdg fullscreen integration tests"
done
pkg-config --exists wayland-client wayland-protocols || \
    die "Wayland client development files and protocols are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-xdg-fullscreen.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
SYNC_DIR="$TEST_ROOT/sync"
FIXTURE_BIN="$TEST_ROOT/xdg-fullscreen-request"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
CLIENT_LOG="$TEST_ROOT/client.log"
COMPOSITOR_PID=""
CLIENT_PID=""

cleanup() {
    [ -z "$CLIENT_PID" ] || kill "$CLIENT_PID" 2>/dev/null || true
    [ -z "$CLIENT_PID" ] || wait "$CLIENT_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

wayland-scanner client-header "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-client-protocol.h"
wayland-scanner private-code "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" "$TEST_ROOT/xdg-shell-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)

mkdir -p "$RUNTIME/config" "$RUNTIME/home" "$SYNC_DIR"
chmod 700 "$RUNTIME"
WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
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

XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
    timeout 20 "$FIXTURE_BIN" "$SYNC_DIR" >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

wait_marker() {
    local marker=$1
    for _ in $(seq 1 200); do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
            tail -120 "$COMPOSITOR_LOG" >&2
            die "compositor exited while waiting for $marker"
        }
        kill -0 "$CLIENT_PID" 2>/dev/null || {
            cat "$CLIENT_LOG" >&2
            die "fullscreen fixture exited before $marker"
        }
        [ -f "$SYNC_DIR/$marker" ] && return 0
        sleep 0.05
    done
    tail -120 "$COMPOSITOR_LOG" >&2
    cat "$CLIENT_LOG" >&2
    die "timed out waiting for $marker"
}

wait_marker fullscreen-ready
read -r fullscreen_width fullscreen_height <"$SYNC_DIR/fullscreen-ready"
[[ "$fullscreen_width" =~ ^[1-9][0-9]*$ && "$fullscreen_height" =~ ^[1-9][0-9]*$ ]] || \
    die "fixture reported invalid fullscreen dimensions"
fullscreen_json=$(XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
    "$AQUEOUSCTL_BIN" windows --json)
grep -q '"app_id":"aqueous.fullscreen-request"' <<<"$fullscreen_json" || \
    die "aqueousctl did not enumerate the fullscreen fixture"
grep -q '"states":\[[^]]*"fullscreen"' <<<"$fullscreen_json" || \
    die "aqueousctl did not report fullscreen state"
grep -q "\"width\":$fullscreen_width,\"height\":$fullscreen_height" <<<"$fullscreen_json" || \
    die "aqueousctl geometry did not match the fullscreen configure"
touch "$SYNC_DIR/fullscreen-continue"

wait_marker windowed-ready
windowed_json=$(XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
    "$AQUEOUSCTL_BIN" windows --json)
grep -q '"app_id":"aqueous.fullscreen-request"' <<<"$windowed_json" || \
    die "aqueousctl lost the windowed fixture"
if grep -q '"states":\[[^]]*"fullscreen"' <<<"$windowed_json"; then
    die "aqueousctl still reported fullscreen after unset_fullscreen"
fi
touch "$SYNC_DIR/windowed-continue"

if ! wait "$CLIENT_PID"; then
    CLIENT_PID=""
    tail -120 "$COMPOSITOR_LOG" >&2
    cat "$CLIENT_LOG" >&2
    die "xdg fullscreen fixture failed"
fi
CLIENT_PID=""
grep -q 'PASS: client fullscreen requests and repeated configures' "$CLIENT_LOG" || \
    die "fixture did not complete all fullscreen cycles"
kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited after fullscreen cycles"

echo "PASS: xdg_toplevel fullscreen requests are applied and acknowledged by integrated policy"
