#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURE_SOURCE="$here/scripts/fixtures/visual-effects-reference.c"
WM_CONFIG="$here/scripts/fixtures/blur-reflow-wm.toml"
RULES_CONFIG="$here/scripts/fixtures/blur-reflow-rules.toml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$#" -le 1 ] || die "usage: $0 [OUTPUT_DIRECTORY]"
[ -x "$AQUEOUS_COMPOSITOR_BIN" ] ||
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
for tool in cc grim jq magick nc pkg-config wayland-scanner; do
    have "$tool" || die "$tool is required"
done
for file in "$FIXTURE_SOURCE" "$WM_CONFIG" "$RULES_CONFIG"; do
    [ -r "$file" ] || die "missing test input: $file"
done

HOST_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}
HOST_WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
[ -n "$HOST_RUNTIME_DIR" ] && [ -n "$HOST_WAYLAND_DISPLAY" ] ||
    die "a parent Wayland display is required"
[ -S "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ] ||
    die "the parent Wayland socket is unavailable"

TEST_ROOT=$(mktemp -d /tmp/aqueous-vulkan-blur-reflow.XXXXXX)
RUNTIME_DIR="$TEST_ROOT/runtime"
SANDBOX_HOME="$TEST_ROOT/home"
FIXTURE_BIN="$TEST_ROOT/visual-effects-reference"
BACKGROUND_CONTROL="$TEST_ROOT/background-control"
if [ "$#" -eq 1 ]; then
    ARTIFACT_DIR=$(readlink -m "$1")
    mkdir -p "$ARTIFACT_DIR"
    [ -z "$(find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        die "output directory is not empty: $ARTIFACT_DIR"
else
    ARTIFACT_DIR="$TEST_ROOT/artifacts"
fi
COMPOSITOR_LOG="$ARTIFACT_DIR/compositor.log"
COMPOSITOR_PID=""
CLIENT_PIDS=()

cleanup() {
    for pid in "${CLIENT_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p \
    "$RUNTIME_DIR/config" \
    "$SANDBOX_HOME" \
    "$BACKGROUND_CONTROL" \
    "$ARTIFACT_DIR"
chmod 700 "$RUNTIME_DIR"
ln -s "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" \
    "$RUNTIME_DIR/aqueous-vulkan-blur-reflow-host"

XDG_SHELL_PROTOCOL="$(
    pkg-config --variable=pkgdatadir wayland-protocols
)/stable/xdg-shell/xdg-shell.xml"
wayland-scanner client-header "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-client-protocol.h"
wayland-scanner private-code "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" "$TEST_ROOT/xdg-shell-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)

env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
    WLR_BACKENDS=wayland \
    WLR_WL_OUTPUTS=1 \
    WAYLAND_DISPLAY=aqueous-vulkan-blur-reflow-host \
    AQUEOUS_CONFIG="$WM_CONFIG" \
    AQUEOUS_RULES="$RULES_CONFIG" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_CONFIG_HOME="$RUNTIME_DIR/config" \
    HOME="$SANDBOX_HOME" \
    "$AQUEOUS_COMPOSITOR_BIN" \
        -no-xwayland -policy internal -log-level debug -c true \
        >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -120 "$COMPOSITOR_LOG" >&2
        die "compositor failed during startup"
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

output_request() {
    printf '%s\n' "$1" |
        nc -U -N -w 3 "$OUTPUT_SOCKET" 2>/dev/null |
        head -1
}

output_state=$(output_request '{"op":"list"}')
OUTPUT_NAME=$(jq -r '.outputs[0].name // empty' <<<"$output_state")
[ -n "$OUTPUT_NAME" ] || die "nested output was not reported"

set_output_mode() {
    local width=$1 height=$2 response
    response=$(output_request \
        "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"mode\":\"${width}x${height}\"}]}")
    jq -e '.ok == true' >/dev/null <<<"$response" ||
        die "output service rejected the mode change: $response"
    for _ in $(seq 1 240); do
        output_state=$(output_request '{"op":"list"}')
        if jq -e \
            --argjson width "$width" \
            --argjson height "$height" \
            '.outputs[0].enabled == true and
             .outputs[0].current_mode.width == $width and
             .outputs[0].current_mode.height == $height' \
            >/dev/null <<<"$output_state"; then
            sleep 0.2
            return
        fi
        sleep 0.05
    done
    die "output did not settle at ${width}x${height}"
}

capture_output() {
    local destination=$1
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        grim -o "$OUTPUT_NAME" "$destination"
    [ -s "$destination" ] || die "empty capture: $destination"
}

launch_fixture() {
    local role=$1 name=$2 control=${3:-}
    local ready="$TEST_ROOT/$name.ready"
    local log="$ARTIFACT_DIR/$name.log"
    if [ -n "$control" ]; then
        env -u LD_PRELOAD \
            XDG_RUNTIME_DIR="$RUNTIME_DIR" \
            WAYLAND_DISPLAY="$socket" \
            "$FIXTURE_BIN" "$role" "$ready" "$control" >"$log" 2>&1 &
    else
        env -u LD_PRELOAD \
            XDG_RUNTIME_DIR="$RUNTIME_DIR" \
            WAYLAND_DISPLAY="$socket" \
            "$FIXTURE_BIN" "$role" "$ready" >"$log" 2>&1 &
    fi
    local pid=$!
    CLIENT_PIDS+=("$pid")
    for _ in $(seq 1 240); do
        [ -f "$ready" ] && return
        kill -0 "$pid" 2>/dev/null || {
            cat "$log" >&2
            die "$name exited before mapping"
        }
        sleep 0.05
    done
    die "$name did not map"
}

CONTROL_SEQUENCE=0

send_background_command() {
    local operation=$1 value=$2 width=$3 height=$4
    CONTROL_SEQUENCE=$((CONTROL_SEQUENCE + 1))
    printf '%d %s %d\n' "$CONTROL_SEQUENCE" "$operation" "$value" \
        >"$BACKGROUND_CONTROL/command.tmp"
    mv "$BACKGROUND_CONTROL/command.tmp" "$BACKGROUND_CONTROL/command"
    for _ in $(seq 1 240); do
        if [ -f "$BACKGROUND_CONTROL/ack" ]; then
            read -r sequence ack_operation x y ack_width ack_height \
                <"$BACKGROUND_CONTROL/ack"
            if [ "$sequence" = "$CONTROL_SEQUENCE" ]; then
                [ "$ack_operation" = "$operation" ] ||
                    die "fixture acknowledged the wrong operation"
                [ "$x $y $ack_width $ack_height" = "0 0 $width $height" ] ||
                    die "fixture acknowledged unexpected full-surface damage"
                return
            fi
        fi
        sleep 0.05
    done
    die "background fixture did not complete $operation"
}

set_output_mode 1920 1080
launch_fixture background background "$BACKGROUND_CONTROL"
read -r _ BACKGROUND_WIDTH BACKGROUND_HEIGHT <"$TEST_ROOT/background.ready"
send_background_command reset 0 "$BACKGROUND_WIDTH" "$BACKGROUND_HEIGHT"
launch_fixture blur blur-one
sleep 1
capture_output "$ARTIFACT_DIR/one-window.png"
launch_fixture blur blur-two
sleep 1
capture_output "$ARTIFACT_DIR/two-windows.png"
launch_fixture blur blur-three
sleep 3
capture_output "$ARTIFACT_DIR/three-windows.png"

reflow_difference=$(
    magick \
        "$ARTIFACT_DIR/two-windows.png" \
        "$ARTIFACT_DIR/three-windows.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h]' info:
)
awk -v changed="$reflow_difference" \
    'BEGIN { exit !(changed > 10000) }' ||
    die "the third tiled blur window did not produce a visible reflow"

# Removing the original tile moves the surviving blurred snapshots across old
# decoration pixels. Capture the entire transition: these are the frames that
# must be fully damaged before their offscreen blur pass samples the scene.
kill "${CLIENT_PIDS[1]}"
wait "${CLIENT_PIDS[1]}" 2>/dev/null || true
for frame in $(seq -w 1 12); do
    capture_output "$ARTIFACT_DIR/reflow-motion-$frame.png"
done
sleep 2
capture_output "$ARTIFACT_DIR/reflow-incremental.png"
close_difference=$(
    magick \
        "$ARTIFACT_DIR/three-windows.png" \
        "$ARTIFACT_DIR/reflow-incremental.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h]' info:
)
awk -v changed="$close_difference" \
    'BEGIN { exit !(changed > 10000) }' ||
    die "removing the original blur tile did not produce a visible reflow"

# Repaint and restore the full background surface. This damages the whole scene
# behind the blur windows without moving them, producing a full-redraw oracle
# with identical content and geometry.
send_background_command motion 19 "$BACKGROUND_WIDTH" "$BACKGROUND_HEIGHT"
send_background_command reset 0 "$BACKGROUND_WIDTH" "$BACKGROUND_HEIGHT"
capture_output "$ARTIFACT_DIR/reflow-full-redraw.png"
oracle_difference=$(
    magick \
        "$ARTIFACT_DIR/reflow-incremental.png" \
        "$ARTIFACT_DIR/reflow-full-redraw.png" \
        -compose difference -composite \
        -alpha off -format '%[fx:mean]' info:
)
awk -v difference="$oracle_difference" \
    'BEGIN { exit !(difference <= 0.0002) }' ||
    die "tiled blur reflow retained pixels outside the current blur footprint"

if grep -Eq \
    'Vulkan (blur|rounded).*failed|validation error|Validation Error' \
    "$COMPOSITOR_LOG"; then
    tail -120 "$COMPOSITOR_LOG" >&2
    die "Vulkan effects reported an error during tiled reflow"
fi

grep -q 'forcing full output damage for blurred animation' \
    "$COMPOSITOR_LOG" ||
    die "tiled blur reflow did not exercise animation-wide damage"

echo "PASS: tiled blur reflow matched a reconstructed frame"
