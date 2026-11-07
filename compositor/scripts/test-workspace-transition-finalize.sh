#!/usr/bin/env bash
set -euo pipefail

# Regression for issue #106: a workspace swap must not flash the outgoing
# workspace on a neighboring output when the slide finishes.
#
# The outgoing window's live tree is parked one output-width off-screen for the
# whole slide and kept invisible only while `prev_workspace` names it. If the
# transition is finalized before that tree is disabled, `applyOpacity` restores
# its opacity while it still sits over the neighbor and the next frame renders
# the previous workspace there. A single presented frame is hard to sample with
# screencopy, so this test drives the compositor's opt-in transition invariant
# diagnostics and fails if the compositor ever reports the leaked state.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
WM_CONFIG="$here/scripts/fixtures/workspace-output-clip-wm.toml"
GHOSTTY_CONFIG="$here/scripts/fixtures/workspace-output-clip-ghostty.conf"
TEST_RENDERER=${AQUEOUS_WORKSPACE_FINALIZE_RENDERER:-vulkan}

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for file in "$WM_CONFIG" "$GHOSTTY_CONFIG"; do
    [ -r "$file" ] || die "missing test input: $file"
done
for tool in ghostty jq wlrctl; do
    have "$tool" || die "$tool is required"
done

TEST_ROOT=$(mktemp -d /tmp/aqueous-workspace-finalize.XXXXXX)
RUNTIME_DIR="$TEST_ROOT/runtime"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
CLIENT_PID=""
mkdir -p "$RUNTIME_DIR/config" "$TEST_ROOT/home"
chmod 700 "$RUNTIME_DIR"
trap 'cleanup' EXIT

cleanup() {
    [ -z "$CLIENT_PID" ] || kill "$CLIENT_PID" 2>/dev/null || true
    [ -z "$CLIENT_PID" ] || wait "$CLIENT_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    if [ "${AQUEOUS_KEEP_TEST_OUTPUT:-0}" = 1 ]; then
        echo "test artifacts: $TEST_ROOT" >&2
    else
        rm -rf "$TEST_ROOT"
    fi
}

env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=2 \
    WLR_RENDERER="$TEST_RENDERER" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_CONFIG_HOME="$RUNTIME_DIR/config" \
    HOME="$TEST_ROOT/home" \
    AQUEOUS_CONFIG="$WM_CONFIG" \
    AQUEOUS_MOD=Super \
    AQUEOUS_DEBUG_WINDOW_STATE=1 \
    GDK_BACKEND=wayland \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -log-level debug -c true \
    >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -100 "$COMPOSITOR_LOG" >&2
        die "compositor exited during startup"
    }
    socket=$(find "$RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"

export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export XDG_CONFIG_HOME="$RUNTIME_DIR/config"
export HOME="$TEST_ROOT/home"
export WAYLAND_DISPLAY="$socket"
export GDK_BACKEND=wayland

# Map the client on the rightmost output before switching its workspace.
wlrctl pointer move 5000 100
ghostty \
    --config-file="$GHOSTTY_CONFIG" \
    --config-default-files=false \
    --gtk-single-instance=false \
    --window-decoration=false \
    --class=aq-workspace-clip,aq-workspace-clip \
    --title=aq-workspace-clip \
    -e sleep 30 >/dev/null 2>&1 &
CLIENT_PID=$!

windows_json="[]"
for _ in $(seq 1 200); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    [ "$(jq 'length' <<<"$windows_json")" = 1 ] && break
    sleep 0.05
done
[ "$(jq 'length' <<<"$windows_json")" = 1 ] || die "test window did not map"

WINDOW_X=$(jq -r '.[0].geometry.x' <<<"$windows_json")
WINDOW_Y=$(jq -r '.[0].geometry.y' <<<"$windows_json")
wlrctl pointer move -10000 -10000
wlrctl pointer move "$((WINDOW_X + 100))" "$((WINDOW_Y + 100))"
wlrctl pointer click left

# The fixture uses a slow slide, leaving time to observe motion and settle.
wlrctl keyboard type 2 modifiers SUPER

saw_motion=0
settled=0
for _ in $(seq 1 400); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -100 "$COMPOSITOR_LOG" >&2
        die "compositor exited during the workspace swap"
    }
    scene=$("$AQUEOUSCTL_BIN" scene 2>/dev/null || true)
    if grep -q 'anim=true' <<<"$scene"; then
        saw_motion=1
    elif [ "$saw_motion" = 1 ]; then
        settled=1
        break
    fi
    sleep 0.05
done
if [ "$saw_motion" = 0 ]; then
    # A -Danimations=false build swaps instantly, so there is no off-screen
    # parking and nothing to finalize. Require the swap itself to have applied.
    if "$AQUEOUSCTL_BIN" scene 2>/dev/null | grep -q 'aq-workspace-clip.*disabled'; then
        echo "workspace transition finalize containment passed (animations disabled)"
        exit 0
    fi
    die "workspace slide did not start"
fi
[ "$settled" = 1 ] || die "workspace slide did not settle"

# A few more frames let the deferred windowing transaction run.
sleep 0.5

if grep -q 'transition invariant:' "$COMPOSITOR_LOG"; then
    grep -n 'transition invariant:' "$COMPOSITOR_LOG" >&2
    tail -80 "$COMPOSITOR_LOG" >&2
    die "outgoing workspace was visible off-screen after finalizing the slide"
fi

# Confirm the swap actually took effect rather than the keypress being dropped.
if ! "$AQUEOUSCTL_BIN" scene 2>/dev/null | grep -q 'aq-workspace-clip.*disabled'; then
    die "workspace swap did not hide the outgoing window"
fi

echo "workspace transition finalize containment passed"