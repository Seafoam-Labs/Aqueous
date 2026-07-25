#!/usr/bin/env bash
set -euo pipefail

# Workspace transitions are owned by one output even though their inert
# animation snapshots live in shared scene layers. Put a bright-red workspace
# on the right output, slide it left, and verify that the neighboring output
# never renders the off-screen snapshot.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
WM_CONFIG="$here/scripts/fixtures/workspace-output-clip-wm.toml"
GHOSTTY_CONFIG="$here/scripts/fixtures/workspace-output-clip-ghostty.conf"
TEST_RENDERER=${AQUEOUS_WORKSPACE_CLIP_RENDERER:-vulkan}

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] ||
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] ||
    die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for file in "$WM_CONFIG" "$GHOSTTY_CONFIG"; do
    [ -r "$file" ] || die "missing test input: $file"
done
for tool in ghostty grim jq magick nc wlrctl; do
    have "$tool" || die "$tool is required"
done

TEST_ROOT=$(mktemp -d /tmp/aqueous-workspace-output-clip.XXXXXX)
RUNTIME_DIR="$TEST_ROOT/runtime"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
CLIENT_PID=""
mkdir -p "$RUNTIME_DIR/config" "$TEST_ROOT/home"
chmod 700 "$RUNTIME_DIR"

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
trap cleanup EXIT

env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=2 \
    WLR_RENDERER="$TEST_RENDERER" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_CONFIG_HOME="$RUNTIME_DIR/config" \
    HOME="$TEST_ROOT/home" \
    AQUEOUS_CONFIG="$WM_CONFIG" \
    AQUEOUS_MOD=Super \
    GDK_BACKEND=wayland \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -log-level info -c true \
    >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -100 "$COMPOSITOR_LOG" >&2
        die "compositor exited during startup"
    }
    socket=$(
        find "$RUNTIME_DIR" -maxdepth 1 -type s \
            -name 'wayland-*' -printf '%f\n' | head -1
    )
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"

OUTPUT_SOCKET="$RUNTIME_DIR/aqueous/outputd.sock"
for _ in $(seq 1 200); do
    [ -S "$OUTPUT_SOCKET" ] && break
    sleep 0.05
done
[ -S "$OUTPUT_SOCKET" ] || die "output service did not create its socket"

export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export XDG_CONFIG_HOME="$RUNTIME_DIR/config"
export HOME="$TEST_ROOT/home"
export WAYLAND_DISPLAY="$socket"
export GDK_BACKEND=wayland

output_state=$(
    printf '%s\n' '{"op":"list"}' |
        nc -U -N -w 3 "$OUTPUT_SOCKET" 2>/dev/null |
        head -1
)
[ "$(jq '.outputs | length' <<<"$output_state")" = 2 ] ||
    die "expected two outputs"

# Move to the rightmost output before mapping the client. wlrctl pointer move
# is relative, and wlroots clamps the oversized delta to the layout boundary.
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
[ "$(jq 'length' <<<"$windows_json")" = 1 ] ||
    die "test window did not map"

OWNER_OUTPUT=$(jq -r '.[0].output' <<<"$windows_json")
OTHER_OUTPUT=$(
    jq -r --arg owner "$OWNER_OUTPUT" \
        '.outputs[] | select(.name != $owner) | .name' <<<"$output_state"
)
OWNER_X=$(
    jq -r --arg owner "$OWNER_OUTPUT" \
        '.outputs[] | select(.name == $owner) | .x' <<<"$output_state"
)
OTHER_X=$(
    jq -r --arg other "$OTHER_OUTPUT" \
        '.outputs[] | select(.name == $other) | .x' <<<"$output_state"
)
[ -n "$OTHER_OUTPUT" ] && [ "$OWNER_X" -gt "$OTHER_X" ] ||
    die "test window did not open on the rightmost output"

# Give the virtual keyboard the same focused-seat precondition as the policy
# integration harness. Click well inside the mapped window.
WINDOW_X=$(jq -r '.[0].geometry.x' <<<"$windows_json")
WINDOW_Y=$(jq -r '.[0].geometry.y' <<<"$windows_json")
wlrctl pointer move -10000 -10000
wlrctl pointer move "$((WINDOW_X + 100))" "$((WINDOW_Y + 100))"
wlrctl pointer click left

capture_mean_red() {
    local output=$1 destination=$2
    grim -o "$output" "$destination"
    magick "$destination" -alpha off -format '%[fx:mean.r]' info:
}

owner_red=$(capture_mean_red "$OWNER_OUTPUT" "$TEST_ROOT/owner-before.png")
other_red=$(capture_mean_red "$OTHER_OUTPUT" "$TEST_ROOT/other-before.png")
awk -v value="$owner_red" 'BEGIN { exit !(value > 0.05) }' ||
    die "test window is not visibly red on $OWNER_OUTPUT"
awk -v value="$other_red" 'BEGIN { exit !(value < 0.01) }' ||
    die "$OTHER_OUTPUT was not clean before the workspace switch"

wlrctl keyboard type 2 modifiers SUPER
for frame in $(seq 1 20); do
    red=$(
        capture_mean_red \
            "$OTHER_OUTPUT" \
            "$TEST_ROOT/other-transition-$frame.png"
    )
    awk -v value="$red" 'BEGIN { exit !(value < 0.01) }' ||
        die "workspace animation leaked onto $OTHER_OUTPUT in frame $frame (mean red=$red)"
    sleep 0.03
done

sleep 3
owner_after=$(capture_mean_red "$OWNER_OUTPUT" "$TEST_ROOT/owner-after.png")
if ! awk -v value="$owner_after" 'BEGIN { exit !(value < 0.01) }'; then
    tail -80 "$COMPOSITOR_LOG" >&2
    die "workspace switch did not hide the outgoing workspace (mean red=$owner_after, windows=$(jq -c . <<<"$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')"))"
fi

echo "workspace animation output containment passed: $OTHER_OUTPUT stayed clean"
