#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Seafoam Labs
# SPDX-License-Identifier: GPL-3.0-only
#
# Integration test for shell-drawn server-side decorations
# (aqueous_shell_manager_v1 version 4). A fixture client creates an
# xdg-toplevel preferring SSD, verifies the shell state advertises
# ssd_renderer "shell", draws an above-placement decoration, and checks
# recoverable error statuses. After the client disconnects the compositor
# must stay alive (border fallback path).
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
PROTOCOL="$here/protocol/aqueous-shell-v1.xml"
FIXTURE_SOURCE="$here/scripts/fixtures/shell-decoration-client.c"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -r "$PROTOCOL" ] || die "missing aqueous-shell-v1 protocol"
[ -r "$FIXTURE_SOURCE" ] || die "missing shell-decoration fixture"
for tool in cc pkg-config timeout wayland-scanner; do
    have "$tool" || die "$tool is required for the shell-decoration integration test"
done
pkg-config --exists wayland-client || die "Wayland client development files are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-shell-decoration.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
CONFIG="$TEST_ROOT/wm.toml"
FIXTURE_BIN="$TEST_ROOT/shell-decoration-client"
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

wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
    "$TEST_ROOT/xdg-shell-client-protocol.h"
wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
    "$TEST_ROOT/xdg-shell-protocol.c"
wayland-scanner client-header /usr/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml \
    "$TEST_ROOT/xdg-decoration-unstable-v1-client-protocol.h"
wayland-scanner private-code /usr/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml \
    "$TEST_ROOT/xdg-decoration-unstable-v1-protocol.c"
wayland-scanner client-header "$PROTOCOL" "$TEST_ROOT/aqueous-shell-v1-client-protocol.h"
wayland-scanner private-code "$PROTOCOL" "$TEST_ROOT/aqueous-shell-v1-protocol.c"
wayland-scanner client-header "$here/protocol/upstream/ext-workspace-v1.xml" \
    "$TEST_ROOT/ext-workspace-v1-client-protocol.h"
wayland-scanner private-code "$here/protocol/upstream/ext-workspace-v1.xml" \
    "$TEST_ROOT/ext-workspace-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" \
    "$TEST_ROOT/xdg-shell-protocol.c" \
    "$TEST_ROOT/xdg-decoration-unstable-v1-protocol.c" \
    "$TEST_ROOT/aqueous-shell-v1-protocol.c" \
    "$TEST_ROOT/ext-workspace-v1-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"
cat >"$CONFIG" <<'EOF'
[layout]
default = "float"
force_ssd = false

[decoration]
renderer = "shell"

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
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -log-level debug -c true \
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
    timeout 20s "$FIXTURE_BIN" >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

wait "$CLIENT_PID" || {
    cat "$CLIENT_LOG" >&2
    tail -120 "$COMPOSITOR_LOG" >&2
    die "shell-decoration fixture failed"
}
CLIENT_PID=""

grep -q '^WINDOW_ID ' "$CLIENT_LOG" || die "fixture never discovered its window ID"
grep -q '^SSD_RENDERER shell$' "$CLIENT_LOG" || die "shell state never advertised ssd_renderer shell"
grep -q '^DECORATION applied$' "$CLIENT_LOG" || die "decoration creation was not applied"
grep -q '^MOVE invalid$' "$CLIENT_LOG" || die "invalid move serial was not rejected"
grep -q '^UNKNOWN not_found$' "$CLIENT_LOG" || die "unknown window ID was not rejected"
grep -q '^DONE$' "$CLIENT_LOG" || die "fixture did not complete"

# The shell client disconnected with a live decoration: the compositor must
# survive the owner-loss cleanup and keep serving clients.
sleep 0.3
kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
    tail -120 "$COMPOSITOR_LOG" >&2
    die "compositor exited after shell decoration owner disconnect"
}

kill "$COMPOSITOR_PID" 2>/dev/null || true
wait "$COMPOSITOR_PID" 2>/dev/null || true
COMPOSITOR_PID=""

echo "shell-decoration integration passed: shell SSD state, decoration creation, recoverable errors, owner-loss survival"