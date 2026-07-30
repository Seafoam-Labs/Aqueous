#!/usr/bin/env bash
set -euo pipefail

# Active-workspace overview regression (headless Pixman by default, optionally
# nested Wayland/Vulkan). This checks frozen thumbnail rendering, modal
# keyboard/pointer selection, focus/layout invariants, scrolling viewport
# reveal, repeated cleanup, window removal, and output teardown.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURES="$here/scripts/fixtures"
TEST_BACKEND=${AQUEOUS_TEST_BACKEND:-headless}
TEST_RENDERER=${AQUEOUS_TEST_RENDERER:-pixman}
TEST_OUTPUTS=${AQUEOUS_TEST_OUTPUTS:-1}

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for tool in ghostty grim magick wlrctl wlr-randr jq nc; do
    have "$tool" || die "$tool is required"
done

TEST_ROOT=$(mktemp -d /tmp/aqueous-overview.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
CLIENT_PIDS=()
mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"

BACKEND_ENV=(
    "WLR_BACKENDS=$TEST_BACKEND"
    "WLR_RENDERER=$TEST_RENDERER"
)
case "$TEST_BACKEND" in
    headless)
        BACKEND_ENV+=("WLR_HEADLESS_OUTPUTS=$TEST_OUTPUTS")
        ;;
    wayland)
        HOST_RUNTIME=${XDG_RUNTIME_DIR:-}
        HOST_DISPLAY=${WAYLAND_DISPLAY:-}
        [ -n "$HOST_RUNTIME" ] && [ -n "$HOST_DISPLAY" ] &&
            [ -S "$HOST_RUNTIME/$HOST_DISPLAY" ] ||
            die "the nested Vulkan overview test requires a parent Wayland display"
        ln -s "$HOST_RUNTIME/$HOST_DISPLAY" "$RUNTIME/overview-host"
        BACKEND_ENV+=("WLR_WL_OUTPUTS=$TEST_OUTPUTS" "WAYLAND_DISPLAY=overview-host")
        ;;
    *)
        die "unsupported overview test backend: $TEST_BACKEND"
        ;;
esac

cleanup() {
    for pid in "${CLIENT_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

env --default-signal=INT --default-signal=TERM \
    "${BACKEND_ENV[@]}" \
    XDG_RUNTIME_DIR="$RUNTIME" \
    XDG_CONFIG_HOME="$RUNTIME/config" \
    HOME="$RUNTIME/home" \
    AQUEOUS_CONFIG="$FIXTURES/overview-wm.toml" \
    GDK_BACKEND=wayland \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -log-level info -c true >"$LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 160); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -100 "$LOG" >&2
        die "compositor exited during startup"
    }
    socket=$(find "$RUNTIME" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"
export XDG_RUNTIME_DIR="$RUNTIME" XDG_CONFIG_HOME="$RUNTIME/config" HOME="$RUNTIME/home"
export WAYLAND_DISPLAY="$socket" GDK_BACKEND=wayland

wlrctl pointer move 100 100

launch_window() {
    local id=$1 config=$2
    ghostty \
        --config-file="$config" \
        --config-default-files=false \
        --gtk-single-instance=false \
        --window-decoration=false \
        --class="$id,$id" \
        --title="$id" \
        -e sleep 60 >/dev/null 2>&1 &
    CLIENT_PIDS+=("$!")
}

launch_window aq-overview-red "$FIXTURES/overview-red-ghostty.conf"
launch_window aq-overview-green "$FIXTURES/overview-green-ghostty.conf"
launch_window aq-overview-blue "$FIXTURES/overview-blue-ghostty.conf"

windows_json="[]"
for _ in $(seq 1 240); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    [ "$(jq 'length' <<<"$windows_json")" = 3 ] && break
    sleep 0.05
done
[ "$(jq 'length' <<<"$windows_json")" = 3 ] || {
    tail -100 "$LOG" >&2
    die "three overview windows did not map"
}

OUTPUT_SOCKET="$RUNTIME/aqueous/outputd.sock"
output_state=$(printf '%s\n' '{"op":"list"}' | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1)
OWNER_OUTPUT=$(jq -r 'map(.output) | unique | join(" ")' <<<"$windows_json")
OWNER_RIGHT=$(jq -r --arg owner "$OWNER_OUTPUT" '
    .outputs[] | select(.name == $owner) |
    .x + (.current_mode.width / .scale)
' <<<"$output_state")
[ -n "$OWNER_RIGHT" ] && [ "$OWNER_RIGHT" != "null" ] ||
    die "could not resolve overview output bounds"

# Three half-width scrolling columns put at least one complete placement beyond
# the initial viewport. The overview must still clone that window.
offscreen_id=$(jq -r --argjson edge "$OWNER_RIGHT" '
    [.[] | select(.geometry.x >= $edge or .geometry.x + .geometry.width > $edge)] |
    last.id // empty
' <<<"$windows_json")
[ -n "$offscreen_id" ] || die "scrolling fixture did not create an off-screen window"

# Optional multi-output coverage leaves a live window on a second output. Its
# scene tree must remain enabled while the owning output enters overview.
if [ "$TEST_OUTPUTS" -gt 1 ]; then
    read -r other_x other_y <<<"$(jq -r --arg owner "$OWNER_OUTPUT" '
        .outputs[] | select(.name != $owner) |
        "\(.x + 100) \(.y + 100)"
    ' <<<"$output_state" | head -1)"
    [ -n "${other_x:-}" ] && [ -n "${other_y:-}" ] ||
        die "could not resolve a second output"
    wlrctl pointer move -10000 -10000
    wlrctl pointer move "$other_x" "$other_y"
    launch_window aq-other-output "$FIXTURES/overview-green-ghostty.conf"
    for _ in $(seq 1 200); do
        windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
        [ "$(jq 'length' <<<"$windows_json")" = 4 ] && break
        sleep 0.05
    done
    [ "$(jq 'length' <<<"$windows_json")" = 4 ] ||
        die "second-output overview fixture did not map"
    wlrctl pointer move -10000 -10000
    wlrctl pointer move 100 100
fi

stable_snapshot() {
    "$AQUEOUSCTL_BIN" windows --json |
        jq -S '[.[] | {id, output, workspace, geometry, layout, states}]'
}

focused_id() {
    "$AQUEOUSCTL_BIN" windows --json |
        jq -r '.[] | select(.states | index("focused")) | .id' |
        head -1
}

before_geometry=$(stable_snapshot)
before_focus=$(focused_id)
[ -n "$before_focus" ] || die "no initially focused window"

open_overview() {
    wlrctl keyboard type w modifiers SUPER
    for _ in $(seq 1 120); do
        scene=$("$AQUEOUSCTL_BIN" scene 2>/dev/null || true)
        cards=$(grep -cF 'overview card:' <<<"$scene" || true)
        if grep -F 'workspace overview [tree]' <<<"$scene" |
            grep -vq ' disabled' && [ "$cards" = 3 ]; then
            return
        fi
        sleep 0.02
    done
    tail -100 "$LOG" >&2
    printf '%s\n' "$scene" >&2
    die "overview did not expose one enabled tree with three cards"
}

open_overview
sleep 0.5
[ "$(stable_snapshot)" = "$before_geometry" ] ||
    die "opening overview changed window geometry, workspace, or output"
[ "$(focused_id)" = "$before_focus" ] ||
    die "opening overview changed keyboard focus"
scene=$("$AQUEOUSCTL_BIN" scene)
grep -F 'layer: background [tree]' <<<"$scene" | grep -vq ' disabled' ||
    die "overview hid the background layer"
for layer in bottom windows top fullscreen overlay popups; do
    grep -F "layer: $layer [tree]" <<<"$scene" | grep -vq ' disabled' ||
        die "overview disabled the global $layer layer"
done
hidden_windows=$(grep -F 'window: aq-overview-' <<<"$scene" |
    grep -cF '[tree] disabled' || true)
[ "$hidden_windows" = 3 ] || {
    printf '%s\n' "$scene" >&2
    die "overview did not hide all live windows on its output"
}
if [ "$TEST_OUTPUTS" -gt 1 ]; then
    grep -F 'window: aq-other-output [tree]' <<<"$scene" |
        grep -vq ' disabled' ||
        die "overview hid a window on the other output"
fi

grim "$TEST_ROOT/overview.png"
for channel in red green blue; do
    case "$channel" in
        red) expression='r > 0.12 && r > g * 2 && r > b * 2' ;;
        green) expression='g > 0.12 && g > r * 2 && g > b * 2' ;;
        blue) expression='b > 0.12 && b > r * 2 && b > g * 2' ;;
    esac
    share=$(magick "$TEST_ROOT/overview.png" -alpha off \
        -fx "$expression ? 1 : 0" -format '%[fx:mean]' info:)
    awk -v value="$share" 'BEGIN { exit !(value > 0.01) }' ||
        die "$channel thumbnail was missing from overview screenshot (share=$share)"
done

# Two Tab presses select the third snapshot-order card, which is the
# off-screen scrolling window, and Return confirms it.
wlrctl keyboard type $'\t'
wlrctl keyboard type $'\t'
wlrctl keyboard type $'\n'
for _ in $(seq 1 120); do
    [ "$(focused_id)" = "$offscreen_id" ] && break
    sleep 0.03
done
[ "$(focused_id)" = "$offscreen_id" ] ||
    die "Return did not focus the off-screen overview selection"
revealed=$(jq --arg id "$offscreen_id" --argjson edge "$OWNER_RIGHT" '
    [.[] | select(.id == $id and .geometry.x < $edge and
        .geometry.x + .geometry.width > 0)] | length
' <<<"$("$AQUEOUSCTL_BIN" windows --json)")
[ "$revealed" = 1 ] || die "normal scrolling focus path did not reveal the selection"

# Escape cancels without disturbing the now-focused window.
pre_cancel_scene=$("$AQUEOUSCTL_BIN" scene)
pre_cancel_disabled=$(grep -F 'window: aq-overview-' <<<"$pre_cancel_scene" |
    grep -cF '[tree] disabled' || true)
open_overview
cancel_focus=$(focused_id)
wlrctl keyboard type $'\e'
sleep 0.1
scene=$("$AQUEOUSCTL_BIN" scene)
grep -F 'workspace overview [tree] disabled' <<<"$scene" >/dev/null ||
    die "Escape left the overview enabled"
for layer in bottom windows top fullscreen overlay popups; do
    grep -F "layer: $layer [tree]" <<<"$scene" | grep -vq ' disabled' ||
        die "Escape did not restore the $layer layer"
done
restored_windows=$(grep -F 'window: aq-overview-' <<<"$scene" |
    grep -cF '[tree]' || true)
disabled_windows=$(grep -F 'window: aq-overview-' <<<"$scene" |
    grep -cF '[tree] disabled' || true)
[ "$restored_windows" = 3 ] &&
    [ "$disabled_windows" = "$pre_cancel_disabled" ] ||
    die "Escape did not restore all live windows"
[ "$(focused_id)" = "$cancel_focus" ] || die "Escape changed focus"

# Hover the first card's first thumbnail buffer, then confirm with a click.
open_overview
sleep 0.5
scene=$("$AQUEOUSCTL_BIN" scene)
buffer_geometry=$(grep -F 'overview thumbnail buffer [buffer]' <<<"$scene" |
    head -1 |
    sed -n 's/.*(\(-\?[0-9][0-9]*\),\(-\?[0-9][0-9]*\) \([0-9][0-9]*\)x\([0-9][0-9]*\)).*/\1 \2 \3 \4/p')
[ -n "$buffer_geometry" ] || {
    printf '%s\n' "$scene" >&2
    die "could not resolve a thumbnail pointer target"
}
read -r bx by bw bh <<<"$buffer_geometry"
wlrctl pointer move -10000 -10000
wlrctl pointer move "$((bx + bw / 2))" "$((by + bh / 2))"
wlrctl pointer click left
for _ in $(seq 1 120); do
    click_focus=$(focused_id)
    [ -n "$click_focus" ] && [ "$click_focus" != "$cancel_focus" ] && break
    sleep 0.03
done
[ "$click_focus" != "$cancel_focus" ] || die "overview pointer click did not change focus"

# Removing the selected window keeps the frozen membership coherent and
# selects a replacement without rebuilding unrelated cards.
open_overview
selected_title=$(jq -r '.[] | select(.states | index("focused")) | .title' \
    <<<"$("$AQUEOUSCTL_BIN" windows --json)")
case "$selected_title" in
    aq-overview-red|aq-overview-green|aq-overview-blue) ;;
    *) die "could not identify the selected overview client" ;;
esac
wlrctl toplevel close "title:$selected_title"
for _ in $(seq 1 160); do
    scene=$("$AQUEOUSCTL_BIN" scene 2>/dev/null || true)
    cards=$(grep -cF 'overview card:' <<<"$scene" || true)
    [ "$cards" = 2 ] && break
    sleep 0.03
done
[ "$cards" = 2 ] || {
    tail -100 "$LOG" >&2
    printf '%s\n' "$scene" >&2
    die "closing an overview window did not remove exactly one card"
}
grep -F 'workspace overview [tree]' <<<"$scene" | grep -vq ' disabled' ||
    die "overview closed while two cards remained"
wlrctl keyboard type $'\e'

# Exercise repeated entry/exit before tearing down the output. Every cancel
# must destroy all per-card scene nodes so stale buffers cannot accumulate.
for _ in $(seq 1 12); do
    wlrctl keyboard type w modifiers SUPER
    for _ in $(seq 1 80); do
        scene=$("$AQUEOUSCTL_BIN" scene 2>/dev/null || true)
        cards=$(grep -cF 'overview card:' <<<"$scene" || true)
        [ "$cards" = 2 ] && break
        sleep 0.01
    done
    [ "$cards" = 2 ] || die "repeated overview entry lost surviving membership"

    wlrctl keyboard type $'\e'
    for _ in $(seq 1 80); do
        scene=$("$AQUEOUSCTL_BIN" scene 2>/dev/null || true)
        cards=$(grep -cF 'overview card:' <<<"$scene" || true)
        if [ "$cards" = 0 ] &&
            grep -F 'workspace overview [tree] disabled' <<<"$scene" >/dev/null; then
            break
        fi
        sleep 0.01
    done
    [ "$cards" = 0 ] || die "repeated overview cancel left stale cards"
done

# Reopen with the two surviving windows and disable the owning output. The
# lifecycle hook must remove every active card before the output is torn down.
wlrctl keyboard type w modifiers SUPER
for _ in $(seq 1 100); do
    scene=$("$AQUEOUSCTL_BIN" scene 2>/dev/null || true)
    cards=$(grep -cF 'overview card:' <<<"$scene" || true)
    [ "$cards" = 2 ] && break
    sleep 0.02
done
[ "$cards" = 2 ] || die "overview did not reopen with surviving membership"
wlr-randr --output "$OWNER_OUTPUT" --off
sleep 0.2
scene=$("$AQUEOUSCTL_BIN" scene)
grep -F 'workspace overview [tree] disabled' <<<"$scene" >/dev/null ||
    die "output disable left the overview enabled"
[ "$(grep -cF 'overview card:' <<<"$scene" || true)" = 0 ] ||
    die "output disable left overview cards alive"

echo "active-workspace overview regression passed"
