#!/usr/bin/env bash
set -euo pipefail

# Render-level regression for minimum-height overflow inside one scrolling
# column. The manual viewport action must reveal the lower member without
# changing focus, and ordinary vertical focus must reveal the upper member.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/scrolling-vertical-reference.c"
WM_CONFIG="$here/scripts/fixtures/scrolling-vertical-wm.toml"
XDG_SHELL_PROTOCOL="$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing vertical scrolling fixture"
[ -r "$WM_CONFIG" ] || die "missing vertical scrolling configuration"
for tool in cc grim jq magick nc pkg-config wayland-scanner wlrctl; do
    have "$tool" || die "$tool is required"
done
pkg-config --exists wayland-client wayland-protocols || \
    die "Wayland client development files and protocols are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-scrolling-vertical.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
LOG="$TEST_ROOT/compositor.log"
FIXTURE_BIN="$TEST_ROOT/scrolling-vertical-reference"
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

wayland-scanner client-header "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-client-protocol.h"
wayland-scanner private-code "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" "$TEST_ROOT/xdg-shell-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$WM_CONFIG" \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -policy internal -log-level info -c true \
    >"$LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || { tail -120 "$LOG" >&2; die "compositor exited during startup"; }
    socket=$(find "$RUNTIME" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"
export XDG_RUNTIME_DIR="$RUNTIME" XDG_CONFIG_HOME="$RUNTIME/config" HOME="$RUNTIME/home"
export WAYLAND_DISPLAY="$socket"

OUTPUT_SOCKET="$RUNTIME/aqueous/outputd.sock"
output_state=""
for _ in $(seq 1 100); do
    [ -S "$OUTPUT_SOCKET" ] || { sleep 0.05; continue; }
    output_state=$(printf '%s\n' '{"op":"list"}' | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1)
    [ -n "$output_state" ] && break
    sleep 0.05
done
[ -n "$output_state" ] || die "output daemon did not report the headless output"
OUTPUT=$(jq -r '.outputs[0].name' <<<"$output_state")
OUTPUT_HEIGHT=$(jq -r '.outputs[0].current_mode.height / .outputs[0].scale | floor' <<<"$output_state")
MINIMUM_HEIGHT=$((OUTPUT_HEIGHT + 100))

wlrctl pointer move 100 100
"$FIXTURE_BIN" aq-scroll-red ffff0000 "$MINIMUM_HEIGHT" >"$TEST_ROOT/red.log" 2>&1 &
CLIENT_PIDS+=("$!")
for _ in $(seq 1 120); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    [ "$(jq '[.[] | select(.app_id == "aq-scroll-red")] | length' <<<"$windows_json")" = 1 ] && break
    sleep 0.05
done
"$FIXTURE_BIN" aq-scroll-blue ff0000ff "$MINIMUM_HEIGHT" >"$TEST_ROOT/blue.log" 2>&1 &
CLIENT_PIDS+=("$!")

windows_json="[]"
for _ in $(seq 1 160); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    [ "$(jq 'length' <<<"$windows_json")" = 2 ] && break
    sleep 0.05
done
[ "$(jq 'length' <<<"$windows_json")" = 2 ] || die "reference windows did not map"

# Focus the blue window, move only that window left into the red window's
# column, then focus red to reveal the top of the new vertical stack.
wlrctl keyboard type l modifiers SUPER
wlrctl keyboard type m modifiers SUPER
wlrctl keyboard type k modifiers SUPER
for _ in $(seq 1 120); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    red_y=$(jq -r '.[] | select(.app_id == "aq-scroll-red") | .geometry.y' <<<"$windows_json")
    blue_y=$(jq -r '.[] | select(.app_id == "aq-scroll-blue") | .geometry.y' <<<"$windows_json")
    [ "$red_y" = 0 ] && [ "$blue_y" -ge "$MINIMUM_HEIGHT" ] && break
    sleep 0.05
done
[ "$red_y" = 0 ] && [ "$blue_y" -ge "$MINIMUM_HEIGHT" ] || {
    printf '%s\n' "$windows_json" >&2
    die "column did not overflow at client minimum heights"
}

red_x=$(jq -r '.[] | select(.app_id == "aq-scroll-red") | .geometry.x + (.geometry.width / 2) | floor' <<<"$windows_json")
sleep 1
grim -o "$OUTPUT" "$TEST_ROOT/top.png"
top_pixel=$(magick "$TEST_ROOT/top.png" -format "%[fx:p{$red_x,20}.r] %[fx:p{$red_x,20}.b]" info:)
awk '{ exit !($1 > 0.9 && $2 < 0.1) }' <<<"$top_pixel" || die "upper red member was not rendered at the top of the column"

# Pan to blue. The action must not alter keyboard focus.
wlrctl keyboard type v modifiers SUPER
for _ in $(seq 1 120); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    red_y=$(jq -r '.[] | select(.app_id == "aq-scroll-red") | .geometry.y' <<<"$windows_json")
    blue_y=$(jq -r '.[] | select(.app_id == "aq-scroll-blue") | .geometry.y' <<<"$windows_json")
    red_focused=$(jq -r '.[] | select(.app_id == "aq-scroll-red") | (.states | index("focused") != null)' <<<"$windows_json")
    [ "$red_y" -lt 0 ] && [ "$blue_y" = 0 ] && [ "$red_focused" = true ] && break
    sleep 0.05
done
[ "$red_y" -lt 0 ] && [ "$blue_y" = 0 ] && [ "$red_focused" = true ] || {
    printf '%s\n' "$windows_json" >&2
    die "manual vertical pan changed focus or failed to reveal the lower member"
}
sleep 1
grim -o "$OUTPUT" "$TEST_ROOT/bottom.png"
bottom_pixel=$(magick "$TEST_ROOT/bottom.png" -format "%[fx:p{$red_x,20}.r] %[fx:p{$red_x,20}.b]" info:)
awk '{ exit !($1 < 0.1 && $2 > 0.9) }' <<<"$bottom_pixel" || die "lower blue member was not clipped into the output viewport (pixel=$bottom_pixel)"

# Normal focus navigation must retain the lower position, then reveal red again.
wlrctl keyboard type j modifiers SUPER
wlrctl keyboard type k modifiers SUPER
for _ in $(seq 1 120); do
    windows_json=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    red_y=$(jq -r '.[] | select(.app_id == "aq-scroll-red") | .geometry.y' <<<"$windows_json")
    red_focused=$(jq -r '.[] | select(.app_id == "aq-scroll-red") | (.states | index("focused") != null)' <<<"$windows_json")
    [ "$red_y" = 0 ] && [ "$red_focused" = true ] && break
    sleep 0.05
done
[ "$red_y" = 0 ] && [ "$red_focused" = true ] || die "focus navigation did not reveal the upper member"

echo "scrolling column vertical viewport passed"
