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
for _ in $(seq 1 120); do
    [ "$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null | jq 'length' 2>/dev/null)" = 1 ] && break
    sleep 0.05
done
launch_window aq-scroll-clip-two
for _ in $(seq 1 120); do
    [ "$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null | jq 'length' 2>/dev/null)" = 2 ] && break
    sleep 0.05
done
launch_window aq-scroll-clip-three

windows_json="[]"
for _ in $(seq 1 200); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    [ "$(jq 'length' <<<"$windows_json")" = 3 ] && break
    sleep 0.05
done
[ "$(jq 'length' <<<"$windows_json")" = 3 ] || { tail -80 "$LOG" >&2; die "three windows did not map"; }
sleep 0.2
windows_json=$("$AQUEOUSCTL_BIN" windows --json)
initial_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
[ "$initial_focus" = aq-scroll-clip-three ] ||
    die "stationary pointer stole initial scrolling focus (focused=$initial_focus)"
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

# The newest third window is focused. Scroll the keyboard viewport left once;
# the newly primary second column must receive keyboard focus while the third
# column straddles the right edge throughout the position animation.
wlrctl keyboard type , modifiers SUPER

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
windows_json=$("$AQUEOUSCTL_BIN" windows --json)
left_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
[ "$left_focus" = aq-scroll-clip-two ] ||
    die "focus-follows-mouse snapped past the requested left column (focused=$left_focus)"

# Return the keyboard viewport to the right. This is the direction in which the
# newly focused window has a lower/left sibling. Its compositor border must
# travel inside the animation snapshot instead of remaining at the settled
# target while the sibling slides across it.
wlrctl keyboard type . modifiers SUPER

observed_animation=0
for _ in $(seq 1 30); do
    scene=$("$AQUEOUSCTL_BIN" scene 2>/dev/null || true)
    active_snapshots=$(grep -F 'window animation snapshot [tree]' <<<"$scene" |
        grep -vc ' disabled' || true)
    [ "$active_snapshots" -gt 0 ] || {
        sleep 0.01
        continue
    }

    disabled_live_borders=$(grep -F 'border: left [rect] disabled' <<<"$scene" |
        grep -vc 'animation border' || true)
    active_animation_borders=$(grep -F 'animation border [tree]' <<<"$scene" |
        grep -vc ' disabled' || true)
    active_animation_left=$(grep -F 'animation border: left [rect]' <<<"$scene" |
        grep -vc ' disabled' || true)
    [ "$disabled_live_borders" -ge "$active_snapshots" ] ||
        die "live destination borders remained enabled during animation"
    [ "$active_animation_borders" -ge "$active_snapshots" ] ||
        die "animation snapshots did not own an enabled border subtree"
    [ "$active_animation_left" -ge "$active_snapshots" ] ||
        die "animation border edges were not enabled with their snapshots"

    snapshot_line=$(grep -nF 'window animation snapshot [tree]' <<<"$scene" |
        grep -v ' disabled' | head -1 | cut -d: -f1)
    snapshot_tail=$(tail -n +"$snapshot_line" <<<"$scene")
    marker_line=$(grep -nF 'animation backdrop blur marker [rect]' <<<"$snapshot_tail" |
        head -1 | cut -d: -f1)
    surfaces_line=$(grep -nF 'animation surfaces [tree]' <<<"$snapshot_tail" |
        head -1 | cut -d: -f1)
    border_line=$(grep -nF 'animation border [tree]' <<<"$snapshot_tail" |
        head -1 | cut -d: -f1)
    [ "$marker_line" -lt "$surfaces_line" ] &&
        [ "$surfaces_line" -lt "$border_line" ] ||
        die "animation scene order was not blur marker, surfaces, border"

    observed_animation=1
    break
done
[ "$observed_animation" = 1 ] ||
    die "right-focus transition never exposed an animation snapshot"

sleep 1
windows_json=$("$AQUEOUSCTL_BIN" windows --json)
right_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
[ "$right_focus" = aq-scroll-clip-three ] ||
    die "focus-follows-mouse snapped past the requested right column (focused=$right_focus)"
settled_scene=$("$AQUEOUSCTL_BIN" scene)
active_snapshots=$(grep -F 'window animation snapshot [tree]' <<<"$settled_scene" |
    grep -vc ' disabled' || true)
[ "$active_snapshots" = 0 ] ||
    die "animation snapshot remained enabled after settling"
grep -F 'animation border [tree] disabled' <<<"$settled_scene" >/dev/null ||
    die "animation border remained enabled after settling"
grep -F 'border: left [rect]' <<<"$settled_scene" |
    grep -v 'animation border' |
    grep -v ' disabled' >/dev/null ||
    die "live border was not restored after animation"

# Layout movement left the stationary pointer over the second column without
# changing keyboard focus. A real pointer event, even within that same hovered
# surface, must still apply focus-follows-mouse.
wlrctl pointer move 1 0
motion_focus=""
for _ in $(seq 1 100); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    motion_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
    [ "$motion_focus" = aq-scroll-clip-two ] && break
    sleep 0.02
done
[ "$motion_focus" = aq-scroll-clip-two ] ||
    die "real pointer motion did not apply focus-follows-mouse (focused=$motion_focus)"

echo "scrolling viewport and animated border containment passed"
