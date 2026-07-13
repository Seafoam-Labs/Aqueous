#!/usr/bin/env bash
set -euo pipefail

# Regression for a configured XDG toplevel destroyed before its first map.
# Such windows can already belong to a workspace but never emit unmap.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURE_SOURCE="$here/scripts/fixtures/xdg-destroy-before-map.c"
XDG_SHELL_PROTOCOL="$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing destroy-before-map fixture"
for tool in cc pkg-config timeout wayland-scanner; do
    have "$tool" || die "$tool is required for window lifecycle integration tests"
done
pkg-config --exists wayland-client wayland-protocols || \
    die "Wayland client development files and protocols are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-window-lifecycle.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
FIXTURE_BIN="$TEST_ROOT/xdg-destroy-before-map"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
CLIENT_LOG="$TEST_ROOT/client.log"
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
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" "$TEST_ROOT/xdg-shell-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
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
    timeout 20 "$FIXTURE_BIN" >"$CLIENT_LOG" 2>&1 || {
        tail -120 "$COMPOSITOR_LOG" >&2
        cat "$CLIENT_LOG" >&2
        die "destroy-before-map fixture failed"
    }

kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
    tail -120 "$COMPOSITOR_LOG" >&2
    die "compositor exited after pre-map destruction"
}
grep -q 'PASS: configured XDG toplevels destroyed before map' "$CLIENT_LOG" || \
    die "fixture did not complete"
if grep -q 'destroying window still attached to a workspace' "$COMPOSITOR_LOG"; then
    tail -120 "$COMPOSITOR_LOG" >&2
    die "final Window.destroy guard had to repair an early-destroy lifecycle"
fi

echo "PASS: pre-map XDG destruction leaves no dangling workspace links"
