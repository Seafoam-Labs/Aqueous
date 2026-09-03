#!/usr/bin/env bash
set -euo pipefail

# Regression for Qt transient dialogs receiving natural-size 0x0 configures.
# The dialog must reach its toolkit-selected size without pointer input.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/qt-transient-natural-size.cpp"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing Qt transient fixture"
for tool in c++ jq pkg-config; do
    have "$tool" || die "$tool is required for the Qt transient integration test"
done
pkg-config --exists Qt6Widgets || die "Qt 6 Widgets development files are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-qt-transient.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
FIXTURE_BIN="$TEST_ROOT/qt-transient-natural-size"
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

c++ -std=c++17 -Wall -Wextra -Werror -O2 "$FIXTURE_SOURCE" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs Qt6Widgets)

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

XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
WAYLAND_DISPLAY="$socket" \
QT_QPA_PLATFORM=wayland \
    "$FIXTURE_BIN" >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

dialog=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited while waiting for Qt dialog"
    kill -0 "$CLIENT_PID" 2>/dev/null || {
        cat "$CLIENT_LOG" >&2
        die "Qt fixture exited before its dialog mapped"
    }
    dialog=$(XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket" \
        "$AQUEOUSCTL_BIN" windows --json 2>/dev/null |
        jq -c '.[] | select(.title == "aqueous-qt-dialog")')
    [ -n "$dialog" ] && break
    sleep 0.05
done
[ -n "$dialog" ] || {
    tail -120 "$COMPOSITOR_LOG" >&2
    cat "$CLIENT_LOG" >&2
    die "timed out waiting for Qt dialog"
}

jq -e '
    (.states | index("floating") != null) and
    (.geometry.width >= 360) and
    (.geometry.height >= 120)
' <<<"$dialog" >/dev/null || {
    printf '%s\n' "$dialog" >&2
    die "Qt dialog retained placeholder geometry before pointer input"
}

if grep -q 'timeout occurred, some imperfect frames may be shown' "$COMPOSITOR_LOG"; then
    tail -120 "$COMPOSITOR_LOG" >&2
    die "Qt dialog left an xdg configure transaction waiting"
fi

echo "PASS: Qt transient reached its natural size without pointer input"
