#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
PROTOCOL="$here/protocol/upstream/kde-server-decoration.xml"
FIXTURE_SOURCE="$here/scripts/fixtures/server-decoration-default-mode.c"
GTK_FIXTURE_SOURCE="$here/scripts/fixtures/gtk-server-decoration.c"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -r "$PROTOCOL" ] || die "missing KDE server-decoration protocol"
[ -r "$FIXTURE_SOURCE" ] || die "missing server-decoration fixture"
for tool in cc pkg-config timeout wayland-scanner; do
    have "$tool" || die "$tool is required for the server-decoration integration test"
done
pkg-config --exists wayland-client || die "Wayland client development files are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-server-decoration.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
CONFIG="$TEST_ROOT/wm.toml"
FIXTURE_BIN="$TEST_ROOT/server-decoration-default-mode"
GTK_FIXTURE_BIN="$TEST_ROOT/gtk-server-decoration"
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

wayland-scanner client-header "$PROTOCOL" \
    "$TEST_ROOT/kde-server-decoration-client-protocol.h"
wayland-scanner private-code "$PROTOCOL" \
    "$TEST_ROOT/kde-server-decoration-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" "$TEST_ROOT/kde-server-decoration-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)
if pkg-config --exists gtk4; then
    cc -std=c11 -Wall -Wextra -Werror -O2 "$GTK_FIXTURE_SOURCE" \
        -o "$GTK_FIXTURE_BIN" $(pkg-config --cflags --libs gtk4)
fi

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"
cat >"$CONFIG" <<'EOF'
[layout]
default = "tile"
force_ssd = false

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
    timeout 12s "$FIXTURE_BIN" 1 2 1 >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

wait_lines() {
    local wanted=$1
    for _ in $(seq 1 120); do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited during reload"
        [ "$(wc -l <"$CLIENT_LOG")" -ge "$wanted" ] && return 0
        sleep 0.05
    done
    cat "$CLIENT_LOG" >&2
    tail -120 "$COMPOSITOR_LOG" >&2
    die "timed out waiting for decoration event $wanted"
}

wait_lines 1
if [ -x "$GTK_FIXTURE_BIN" ]; then
    gtk_mode=$(XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        XDG_CONFIG_HOME="$RUNTIME/config" HOME="$RUNTIME/home" \
        GDK_BACKEND=wayland GSK_RENDERER=cairo timeout 5s "$GTK_FIXTURE_BIN")
    [ "$gtk_mode" = "present" ] || die "GTK omitted its default titlebar in client mode"
fi
sed -i 's/force_ssd = false/force_ssd = true/' "$CONFIG"
wait_lines 2
if [ -x "$GTK_FIXTURE_BIN" ]; then
    gtk_mode=$(XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        XDG_CONFIG_HOME="$RUNTIME/config" HOME="$RUNTIME/home" \
        GDK_BACKEND=wayland GSK_RENDERER=cairo timeout 5s "$GTK_FIXTURE_BIN")
    [ "$gtk_mode" = "absent" ] || die "GTK retained its default titlebar in server mode"
    gtk_mode=$(XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        XDG_CONFIG_HOME="$RUNTIME/config" HOME="$RUNTIME/home" \
        GDK_BACKEND=wayland GSK_RENDERER=cairo timeout 5s "$GTK_FIXTURE_BIN" custom)
    [ "$gtk_mode" = "present" ] || die "GTK custom titlebar compatibility changed"
fi
sed -i 's/force_ssd = true/force_ssd = false/' "$CONFIG"
wait_lines 3
if [ -x "$GTK_FIXTURE_BIN" ]; then
    gtk_mode=$(XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        XDG_CONFIG_HOME="$RUNTIME/config" HOME="$RUNTIME/home" \
        GDK_BACKEND=wayland GSK_RENDERER=cairo timeout 5s "$GTK_FIXTURE_BIN")
    [ "$gtk_mode" = "present" ] || die "GTK did not restore its default titlebar in client mode"
fi

wait "$CLIENT_PID" || {
    cat "$CLIENT_LOG" >&2
    die "server-decoration client failed"
}
CLIENT_PID=""

[ "$(cat "$CLIENT_LOG")" = $'1\n2\n1' ] || die "unexpected mode sequence"
grep -q 'default mode=client' "$COMPOSITOR_LOG" || die "missing client-mode log"
grep -q 'default mode=server' "$COMPOSITOR_LOG" || die "missing server-mode reload log"

echo "server-decoration integration passed: global advertised and force_ssd hot-reloaded client -> server -> client"
