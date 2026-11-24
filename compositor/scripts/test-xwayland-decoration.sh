#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Seafoam Labs
# SPDX-License-Identifier: GPL-3.0-only
#
# Integration test for XWayland server-side decoration negotiation:
# MOTIF hint suppression under force_ssd, restoration on reload, and
# honoring clients which insist on their own decorations.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURE_SOURCE="$here/scripts/fixtures/xwayland-decoration.c"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
have Xwayland || die "Xwayland is required"
for tool in cc pkg-config timeout; do
    have "$tool" || die "$tool is required"
done
pkg-config --exists xcb || die "xcb development files are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-xwayland-decoration.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
CONFIG="$TEST_ROOT/wm.toml"
FIXTURE_BIN="$TEST_ROOT/xwayland-decoration"
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

cc -std=c11 -Wall -Wextra -Werror -O2 "$FIXTURE_SOURCE" -o "$FIXTURE_BIN" $(pkg-config --cflags --libs xcb)

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"
cat >"$CONFIG" <<'EOF'
[layout]
default = "float"
force_ssd = true

[workspace_transition]
enabled = false
EOF

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$CONFIG" \
    "$AQUEOUS_COMPOSITOR_BIN" -log-level debug \
    -c 'printf %s "$DISPLAY" > "$XDG_RUNTIME_DIR/x11-display"' \
    >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

x11=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -120 "$COMPOSITOR_LOG" >&2
        die "compositor failed during startup"
    }
    [ -f "$RUNTIME/x11-display" ] && x11=$(cat "$RUNTIME/x11-display") && [ -n "$x11" ] && break
    sleep 0.05
done
[ -n "$x11" ] || die "compositor did not export DISPLAY"

DISPLAY="$x11" XDG_RUNTIME_DIR="$RUNTIME" timeout 30s "$FIXTURE_BIN" >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

wait_marker() {
    local marker=$1
    for _ in $(seq 1 200); do
        grep -q "^$marker$" "$CLIENT_LOG" && return 0
        kill -0 "$CLIENT_PID" 2>/dev/null || break
        sleep 0.05
    done
    cat "$CLIENT_LOG" >&2
    tail -60 "$COMPOSITOR_LOG" >&2
    die "missing marker $marker"
}

wait_marker SUPPRESSED
wait_marker CSD-HONORED
sed -i 's/force_ssd = true/force_ssd = false/' "$CONFIG"
wait_marker RESTORED

wait "$CLIENT_PID" || {
    cat "$CLIENT_LOG" >&2
    die "xwayland decoration fixture failed"
}
CLIENT_PID=""

echo "xwayland-decoration integration passed: suppression, CSD honoring, restoration"