#!/usr/bin/env bash
set -euo pipefail

# Verifies startup environment parsing and live, stationary compositor cursor
# replacement through aqueousctl.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
THEME_SOURCE="$here/scripts/fixtures/xcursor-scale-theme.c"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for tool in cc grim jq magick nc pkg-config wlrctl; do
    have "$tool" || die "$tool is required"
done
pkg-config --exists xcursor || die "Xcursor development files are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-cursor-theme.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""

cleanup() {
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$RUNTIME/config" "$RUNTIME/home" \
    "$TEST_ROOT/icons/aqueous-cursor-initial/cursors" \
    "$TEST_ROOT/icons/aqueous-cursor-updated/cursors"
chmod 700 "$RUNTIME"
cc -std=c11 -Wall -Wextra -Werror -O2 "$THEME_SOURCE" \
    -o "$TEST_ROOT/theme-generator" $(pkg-config --cflags --libs xcursor)
"$TEST_ROOT/theme-generator" "$TEST_ROOT/icons/aqueous-cursor-initial/cursors/default"
cp "$TEST_ROOT/icons/aqueous-cursor-initial/cursors/default" \
    "$TEST_ROOT/icons/aqueous-cursor-updated/cursors/default"

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XCURSOR_PATH="$TEST_ROOT/icons" \
XCURSOR_THEME=aqueous-cursor-initial \
XCURSOR_SIZE=30 \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -policy internal -log-level debug -c true \
    >"$LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -120 "$LOG" >&2
        die "compositor exited during startup"
    }
    socket=$(find "$RUNTIME" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"

client_env=(env XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket")
query=$("${client_env[@]}" "$AQUEOUSCTL_BIN" cursor)
grep -Fxq 'Theme: aqueous-cursor-initial' <<<"$query" || die "startup theme was not read from XCURSOR_THEME: $query"
grep -Fxq 'Size: 30' <<<"$query" || die "startup size was not read from XCURSOR_SIZE: $query"
query_json=$("${client_env[@]}" "$AQUEOUSCTL_BIN" cursor --json)
jq -e '.ok == true and .status == "success" and .theme == "aqueous-cursor-initial" and .size == 30' <<<"$query_json" >/dev/null ||
    die "cursor JSON query did not report startup state: $query_json"

OUTPUT_SOCKET="$RUNTIME/aqueous/outputd.sock"
output_request() { printf '%s\n' "$1" | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1; }
output_name=""
for _ in $(seq 1 100); do
    output_name=$(output_request '{"op":"list"}' | jq -r '.outputs[0].name // empty' 2>/dev/null || true)
    [ -z "$output_name" ] || break
    sleep 0.05
done
[ -n "$output_name" ] || die "headless output did not become available"

"${client_env[@]}" wlrctl pointer move -10000 -10000
"${client_env[@]}" wlrctl pointer move 200 200
sleep 0.1

cursor_extent() {
    local label=$1
    "${client_env[@]}" grim -o "$output_name" "$TEST_ROOT/$label-plain.png"
    "${client_env[@]}" grim -c -o "$output_name" "$TEST_ROOT/$label-cursor.png"
    magick "$TEST_ROOT/$label-plain.png" "$TEST_ROOT/$label-cursor.png" \
        -compose difference -composite -alpha off -colorspace gray \
        -threshold 50% -trim -format '%wx%h' info:
}

[ "$(cursor_extent initial)" = 30x30 ] || die "startup cursor did not render at 30x30"

set_result=$("${client_env[@]}" "$AQUEOUSCTL_BIN" cursor set \
    --theme aqueous-cursor-updated --size 48)
grep -Fxq 'Theme: aqueous-cursor-updated' <<<"$set_result" || die "live theme update was not acknowledged: $set_result"
grep -Fxq 'Size: 48' <<<"$set_result" || die "live size update was not acknowledged: $set_result"
sleep 0.1
[ "$(cursor_extent updated)" = 48x48 ] || die "stationary cursor did not update to 48x48"
set_json=$("${client_env[@]}" "$AQUEOUSCTL_BIN" cursor set \
    --theme aqueous-cursor-updated --size 48 --json)
jq -e '.ok == true and .theme == "aqueous-cursor-updated" and .size == 48' <<<"$set_json" >/dev/null ||
    die "cursor JSON update did not acknowledge live state: $set_json"

# A reload-time child is forked after the live change, proving Aqueous updated
# the environment inherited by its own future launch paths.
probe="$TEST_ROOT/child-environment"
mkdir -p "$RUNTIME/config/aqueous"
printf '[[exec]]\nname = "cursor-environment-probe"\ncommand = "env > %s"\nwhen = "reload"\n' \
    "$probe" >"$RUNTIME/config/aqueous/wm.toml"
for _ in $(seq 1 50); do
    [ -s "$probe" ] && break
    sleep 0.1
done
[ -s "$probe" ] || die "post-update child environment probe did not run"
grep -Fxq 'XCURSOR_THEME=aqueous-cursor-updated' "$probe" || \
    die "new compositor child did not inherit the updated cursor theme"
grep -Fxq 'XCURSOR_SIZE=48' "$probe" || \
    die "new compositor child did not inherit the updated cursor size"

if "${client_env[@]}" "$AQUEOUSCTL_BIN" cursor set --theme aqueous-cursor-updated --size 0 >/dev/null 2>&1; then
    die "invalid cursor size was accepted"
fi
query=$("${client_env[@]}" "$AQUEOUSCTL_BIN" cursor)
grep -Fxq 'Theme: aqueous-cursor-updated' <<<"$query" || die "invalid update did not preserve the working theme"
grep -Fxq 'Size: 48' <<<"$query" || die "invalid update did not preserve the working size"

echo "PASS: startup and live cursor theme changes apply without pointer motion"
