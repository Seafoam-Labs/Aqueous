#!/usr/bin/env bash
set -euo pipefail
export AQUEOUS_DEBUG_WINDOW_STATE=1
# Keep host configuration overrides out of the isolated test compositor.
unset AQUEOUS_LAYOUT AQUEOUS_INPUT AQUEOUS_OUTPUTS AQUEOUS_RULES

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
WM_CONFIG="$TEST_ROOT/scrolling-viewport-wm.toml"
COMPOSITOR_PID=""
CLIENT_PIDS=()
mkdir -p "$RUNTIME/config" "$RUNTIME/home"
cp "$FIXTURES/scrolling-viewport-wm.toml" "$WM_CONFIG"
chmod 700 "$RUNTIME"

cleanup() {
    local status=$?
    for pid in "${CLIENT_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    if [ "$status" = 0 ]; then rm -rf "$TEST_ROOT"; else echo "Artifacts: $TEST_ROOT" >&2; fi
}
trap cleanup EXIT

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=2 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$WM_CONFIG" \
AQUEOUS_RULES="$TEST_ROOT/rules.toml" \
AQUEOUS_LAYOUT="$TEST_ROOT/layout.toml" \
AQUEOUS_INPUT="$TEST_ROOT/input.toml" \
AQUEOUS_OUTPUTS="$TEST_ROOT/outputs.toml" \
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
[ "$crossing" -gt 0 ] || { printf '%s\n' "$windows_json" >&2; die "focus change did not produce an edge-crossing scrolling placement"; }

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
# travel with its original surface tree instead of remaining at the settled
# target while the sibling slides across it.
wlrctl keyboard type . modifiers SUPER

observed_animation=0
for _ in $(seq 1 30); do
    scene=$("$AQUEOUSCTL_BIN" scene 2>/dev/null || true)
    active_presentations=$(grep -F 'anim=true' <<<"$scene" |
        grep -vc ' disabled' || true)
    [ "$active_presentations" -gt 0 ] || {
        sleep 0.01
        continue
    }

    ! grep -F 'window animation snapshot' <<<"$scene" >/dev/null ||
        die "retired animation tree still exists"
    grep -F 'border: left [rect]' <<<"$scene" | grep -v ' disabled' >/dev/null ||
        die "original borders were suppressed during presentation"
    window_line=$(grep -nF 'anim=true' <<<"$scene" | head -1 | cut -d: -f1)
    window_tail=$(tail -n +"$window_line" <<<"$scene")
    marker_line=$(grep -nF 'backdrop blur marker [rect]' <<<"$window_tail" | head -1 | cut -d: -f1)
    surfaces_line=$(grep -nF 'live surfaces [tree]' <<<"$window_tail" | head -1 | cut -d: -f1)
    border_line=$(grep -nF 'border: left [rect]' <<<"$window_tail" | head -1 | cut -d: -f1)
    [ "$marker_line" -lt "$surfaces_line" ] && [ "$surfaces_line" -lt "$border_line" ] ||
        die "window scene order was not blur marker, surfaces, border"

    observed_animation=1
    break
done
[ "$observed_animation" = 1 ] ||
    die "right-focus transition never exposed a moving presentation"

sleep 1
windows_json=$("$AQUEOUSCTL_BIN" windows --json)
right_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
[ "$right_focus" = aq-scroll-clip-three ] ||
    die "focus-follows-mouse snapped past the requested right column (focused=$right_focus)"
settled_scene=$("$AQUEOUSCTL_BIN" scene)
active_presentations=$(grep -F 'anim=true' <<<"$settled_scene" |
    grep -vc ' disabled' || true)
[ "$active_presentations" = 0 ] ||
    die "presentation remained active after settling"
grep -F 'border: left [rect]' <<<"$settled_scene" |
    grep -v 'animation border' |
    grep -v ' disabled' >/dev/null ||
    die "live border was not restored after animation"

# Layout movement left the stationary pointer over the second column without
# changing keyboard focus. A real pointer event, even within that same hovered
# surface, starts the configured scrolling focus delay. Keyboard focus must not
# snap back before that delay expires.
wlrctl pointer move 1 0
sleep 0.05
windows_json=$("$AQUEOUSCTL_BIN" windows --json)
early_motion_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
[ "$early_motion_focus" = aq-scroll-clip-three ] ||
    die "pointer focus ignored the scrolling delay (focused=$early_motion_focus)"

# Explicit keyboard navigation cancels that armed hover request. Return right
# and wait beyond the original deadline; the stationary pointer must not revive
# the old request and scroll focus back to the second column.
wlrctl keyboard type , modifiers SUPER
for _ in $(seq 1 100); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    cancelled_left_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
    [ "$cancelled_left_focus" = aq-scroll-clip-two ] && break
    sleep 0.02
done
[ "$cancelled_left_focus" = aq-scroll-clip-two ] ||
    die "keyboard navigation did not immediately focus the second column"
wlrctl keyboard type . modifiers SUPER
for _ in $(seq 1 100); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    cancelled_right_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
    [ "$cancelled_right_focus" = aq-scroll-clip-three ] && break
    sleep 0.02
done
[ "$cancelled_right_focus" = aq-scroll-clip-three ] ||
    die "keyboard navigation did not immediately restore the third column"
sleep 0.2
windows_json=$("$AQUEOUSCTL_BIN" windows --json)
cancelled_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
[ "$cancelled_focus" = aq-scroll-clip-three ] ||
    die "cancelled hover request scrolled focus back (focused=$cancelled_focus)"

# A fresh real motion starts a fresh delay and eventually focuses the hovered
# second column.
wlrctl pointer move 1 0
motion_focus=""
for _ in $(seq 1 100); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    motion_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
    [ "$motion_focus" = aq-scroll-clip-two ] && break
    sleep 0.02
done
[ "$motion_focus" = aq-scroll-clip-two ] ||
    die "delayed pointer motion did not apply focus-follows-mouse (focused=$motion_focus)"

# Zero retains the legacy immediate behavior. Reload a private fixture copy,
# move keyboard focus right again, then ensure a real pointer event transfers
# focus well inside the former 150 ms delay window.
sed -i 's/focus_follows_mouse_delay_ms = 150/focus_follows_mouse_delay_ms = 0/' "$WM_CONFIG"
wlrctl keyboard type r modifiers SUPER
sleep 0.2
wlrctl keyboard type . modifiers SUPER
zero_keyboard_focus=""
for _ in $(seq 1 100); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    zero_keyboard_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
    [ "$zero_keyboard_focus" = aq-scroll-clip-three ] && break
    sleep 0.02
done
[ "$zero_keyboard_focus" = aq-scroll-clip-three ] ||
    die "keyboard viewport focus failed after zero-delay reload (focused=$zero_keyboard_focus)"
sleep 1
wlrctl pointer move 1 0
sleep 0.05
windows_json=$("$AQUEOUSCTL_BIN" windows --json)
zero_motion_focus=$(jq -r '.[] | select(.states | index("focused")) | .title' <<<"$windows_json")
[ "$zero_motion_focus" = aq-scroll-clip-two ] ||
    die "zero-delay pointer focus was not immediate (focused=$zero_motion_focus)"

echo "scrolling viewport, animated border containment, and pointer focus delay passed"
