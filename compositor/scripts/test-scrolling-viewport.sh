#!/usr/bin/env bash
set -euo pipefail

# Render-level regression for scrolling viewport containment. Three bright-red
# windows belong to the left headless output; after focusing the middle column,
# its right-hand neighbor would extend into the adjacent output without a fixed
# window/animation clip.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURES="$here/scripts/fixtures"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for tool in ghostty grim magick wlrctl jq nc; do
    have "$tool" || die "$tool is required"
done

TEST_ROOT=$(mktemp -d /tmp/aqueous-scrolling-viewport.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
CLIENT_PIDS=()
mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"

cleanup() {
    for pid in "${CLIENT_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=2 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$FIXTURES/scrolling-viewport-wm.toml" \
GDK_BACKEND=wayland \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -log-level info -c true >"$LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 160); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || { tail -80 "$LOG" >&2; die "compositor exited during startup"; }
    socket=$(find "$RUNTIME" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"
export XDG_RUNTIME_DIR="$RUNTIME" XDG_CONFIG_HOME="$RUNTIME/config" HOME="$RUNTIME/home"
export WAYLAND_DISPLAY="$socket" GDK_BACKEND=wayland

# New windows inherit the output under the cursor. Pin it well inside the first
# autolayout output before any client creates a surface.
wlrctl pointer move 100 100

launch_window() {
    local id=$1
    ghostty \
        --config-file="$FIXTURES/scrolling-viewport-ghostty.conf" \
        --config-default-files=false \
        --gtk-single-instance=false \
        --window-decoration=false \
        --class="$id,$id" \
        --title="$id" \
        -e sleep 60 >/dev/null 2>&1 &
    CLIENT_PIDS+=("$!")
}

launch_window aq-scroll-clip-one
launch_window aq-scroll-clip-two
launch_window aq-scroll-clip-three

windows_json="[]"
for _ in $(seq 1 200); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    [ "$(jq 'length' <<<"$windows_json")" = 3 ] && break
    sleep 0.05
done
[ "$(jq 'length' <<<"$windows_json")" = 3 ] || { tail -80 "$LOG" >&2; die "three windows did not map"; }
OWNER_OUTPUT=$(jq -r 'map(.output) | unique | join(" ")' <<<"$windows_json")
case "$OWNER_OUTPUT" in
    HEADLESS-1) OTHER_OUTPUT=HEADLESS-2 ;;
    HEADLESS-2) OTHER_OUTPUT=HEADLESS-1 ;;
    *) die "test windows were not confined to one headless output (got: $OWNER_OUTPUT)" ;;
esac

OUTPUT_SOCKET="$RUNTIME/aqueous/outputd.sock"
output_state=$(printf '%s\n' '{"op":"list"}' | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1)
OWNER_RIGHT=$(jq -r --arg owner "$OWNER_OUTPUT" '
    .outputs[] | select(.name == $owner) |
    .x + (.current_mode.width / .scale)
' <<<"$output_state")
[ -n "$OWNER_RIGHT" ] && [ "$OWNER_RIGHT" != "null" ] || die "could not resolve the owning output edge"

# The newest third window is focused. Move focus left once so the third column
# straddles the right edge of HEADLESS-1 throughout the position animation.
wlrctl keyboard type h modifiers SUPER

# Confirm the full placement really crosses the owning output edge. The render
# clip, not geometry clamping or a missed keybinding, must keep it off the
# neighbor.
crossing=0
for _ in $(seq 1 100); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    crossing=$(jq --arg owner "$OWNER_OUTPUT" --argjson edge "$OWNER_RIGHT" '
        [.[] | select(.output == $owner and (.geometry.x + .geometry.width > $edge))] | length
    ' <<<"$windows_json")
    [ "$crossing" -gt 0 ] && break
    sleep 0.03
done
[ "$crossing" -gt 0 ] || die "focus change did not produce an edge-crossing scrolling placement"

assert_output_clean() {
    local shot=$1 mean_red
    grim -o "$OTHER_OUTPUT" "$shot"
    mean_red=$(magick "$shot" -alpha off -format '%[fx:mean.r]' info:)
    awk -v value="$mean_red" 'BEGIN { exit !(value < 0.01) }' || die "$OWNER_OUTPUT red content leaked onto $OTHER_OUTPUT (mean red=$mean_red)"
}

# Sample both the in-flight animation and its settled target.
for frame in $(seq 1 12); do
    assert_output_clean "$TEST_ROOT/frame-$frame.png"
    sleep 0.03
done
sleep 1
assert_output_clean "$TEST_ROOT/settled.png"

echo "scrolling viewport containment passed: $OTHER_OUTPUT stayed clean during animation and at rest"
