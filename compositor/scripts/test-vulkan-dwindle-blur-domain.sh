#!/usr/bin/env bash
set -euo pipefail

# Deterministic two-window oracle for blur-domain reflection, sibling isolation,
# and partial cache updates. Run directly for one cache mode; the companion
# test-vulkan-dwindle-blur-effects.sh runs and compares both modes.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
REFERENCE_SOURCE="$here/scripts/fixtures/visual-effects-reference.c"
BACKGROUND_SOURCE="$here/scripts/fixtures/vulkan-blur-domain-background.c"
EXIT_SOURCE="$here/scripts/fixtures/exit-session.c"
WM_CONFIG="$here/scripts/fixtures/vulkan-dwindle-blur-wm.toml"
RULES_CONFIG="$here/scripts/fixtures/vulkan-dwindle-blur-rules.toml"
LAYER_SHELL_PROTOCOL="$here/protocol/upstream/wlr-layer-shell-unstable-v1.xml"
WINDOW_MANAGEMENT_PROTOCOL="$here/protocol/river-window-management-v1.xml"
WORKSPACE_PROTOCOL="$here/protocol/upstream/ext-workspace-v1.xml"
UNCACHED_ORACLE=${AQUEOUS_VULKAN_BLUR_UNCACHED:-0}
TEST_BACKEND=${AQUEOUS_VULKAN_EFFECTS_BACKEND:-auto}
REFERENCE_TOLERANCE=${AQUEOUS_VULKAN_BLUR_REFERENCE_TOLERANCE:-0.0002}
CROSS_BLEED_LIMIT=${AQUEOUS_VULKAN_BLUR_CROSS_BLEED_LIMIT:-0.020}
EDGE_EXCESS_LIMIT=${AQUEOUS_VULKAN_BLUR_EDGE_EXCESS_LIMIT:-0.015}

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$#" -le 1 ] || die "usage: $0 [OUTPUT_DIRECTORY]"
[[ "$UNCACHED_ORACLE" = 0 || "$UNCACHED_ORACLE" = 1 ]] ||
    die "AQUEOUS_VULKAN_BLUR_UNCACHED must be 0 or 1"
[[ "$TEST_BACKEND" = auto || "$TEST_BACKEND" = wayland ||
    "$TEST_BACKEND" = headless ]] ||
    die "AQUEOUS_VULKAN_EFFECTS_BACKEND must be auto, wayland, or headless"
[ -x "$AQUEOUS_COMPOSITOR_BIN" ] ||
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] ||
    die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for file in \
    "$REFERENCE_SOURCE" \
    "$BACKGROUND_SOURCE" \
    "$EXIT_SOURCE" \
    "$WM_CONFIG" \
    "$RULES_CONFIG" \
    "$LAYER_SHELL_PROTOCOL" \
    "$WINDOW_MANAGEMENT_PROTOCOL" \
    "$WORKSPACE_PROTOCOL"; do
    [ -r "$file" ] || die "missing test input: $file"
done
for tool in cc grim jq magick nc pkg-config timeout wayland-scanner wlrctl; do
    have "$tool" || die "$tool is required"
done
pkg-config --exists wayland-client wayland-protocols ||
    die "Wayland client development files and protocols are required"

if [ "$#" -eq 1 ]; then
    ARTIFACT_DIR=$(readlink -m "$1")
    mkdir -p "$ARTIFACT_DIR"
    [ -z "$(find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        die "output directory is not empty: $ARTIFACT_DIR"
else
    ARTIFACT_DIR=$(mktemp -d /tmp/aqueous-vulkan-dwindle-blur-artifacts.XXXXXX)
fi

TEST_ROOT=$(mktemp -d /tmp/aqueous-vulkan-dwindle-blur.XXXXXX)
RUNTIME_DIR="$TEST_ROOT/runtime"
SANDBOX_HOME="$TEST_ROOT/home"
REFERENCE_BIN="$TEST_ROOT/visual-effects-reference"
BACKGROUND_BIN="$TEST_ROOT/vulkan-blur-domain-background"
EXIT_BIN="$TEST_ROOT/exit-session"
BACKGROUND_CONTROL="$TEST_ROOT/background-control"
COMPOSITOR_LOG="$ARTIFACT_DIR/compositor.log"
COMPOSITOR_PID=""
EXIT_PID=""
CLIENT_PIDS=()

cleanup() {
    [ -z "$EXIT_PID" ] || kill "$EXIT_PID" 2>/dev/null || true
    [ -z "$EXIT_PID" ] || wait "$EXIT_PID" 2>/dev/null || true
    for pid in "${CLIENT_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${CLIENT_PIDS[@]}"; do
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

HOST_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}
HOST_WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
if [ "$TEST_BACKEND" = auto ]; then
    if [ -n "$HOST_RUNTIME_DIR" ] && [ -n "$HOST_WAYLAND_DISPLAY" ] &&
        [ -S "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ]; then
        TEST_BACKEND=wayland
    else
        TEST_BACKEND=headless
    fi
fi

BACKEND_ENV=()
if [ "$TEST_BACKEND" = wayland ]; then
    [ -n "$HOST_RUNTIME_DIR" ] && [ -n "$HOST_WAYLAND_DISPLAY" ] ||
        die "a parent Wayland display is required"
    [ -S "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ] ||
        die "the parent Wayland socket is unavailable"
    ln -s "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" \
        "$RUNTIME_DIR/aqueous-dwindle-blur-host"
    BACKEND_ENV=(
        WLR_BACKENDS=wayland
        WLR_WL_OUTPUTS=1
        WAYLAND_DISPLAY=aqueous-dwindle-blur-host
    )
else
    BACKEND_ENV=(
        WLR_BACKENDS=headless
        WLR_HEADLESS_OUTPUTS=1
    )
fi

XDG_SHELL_PROTOCOL="$(
    pkg-config --variable=pkgdatadir wayland-protocols
)/stable/xdg-shell/xdg-shell.xml"
wayland-scanner client-header "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-client-protocol.h"
wayland-scanner private-code "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-protocol.c"
wayland-scanner client-header "$LAYER_SHELL_PROTOCOL" \
    "$TEST_ROOT/wlr-layer-shell-unstable-v1-client-protocol.h"
wayland-scanner private-code "$LAYER_SHELL_PROTOCOL" \
    "$TEST_ROOT/wlr-layer-shell-unstable-v1-protocol.c"
wayland-scanner client-header "$WINDOW_MANAGEMENT_PROTOCOL" \
    "$TEST_ROOT/river-window-management-v1-client-protocol.h"
wayland-scanner private-code "$WINDOW_MANAGEMENT_PROTOCOL" \
    "$TEST_ROOT/river-window-management-v1-protocol.c"
wayland-scanner private-code "$WORKSPACE_PROTOCOL" \
    "$TEST_ROOT/ext-workspace-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$REFERENCE_SOURCE" "$TEST_ROOT/xdg-shell-protocol.c" \
    -o "$REFERENCE_BIN" \
    $(pkg-config --cflags --libs wayland-client)
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$BACKGROUND_SOURCE" \
    "$TEST_ROOT/xdg-shell-protocol.c" \
    "$TEST_ROOT/wlr-layer-shell-unstable-v1-protocol.c" \
    -o "$BACKGROUND_BIN" \
    $(pkg-config --cflags --libs wayland-client)
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$EXIT_SOURCE" \
    "$TEST_ROOT/river-window-management-v1-protocol.c" \
    "$TEST_ROOT/ext-workspace-v1-protocol.c" \
    -o "$EXIT_BIN" \
    $(pkg-config --cflags --libs wayland-client)

env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
    "${BACKEND_ENV[@]}" \
    WLR_RENDERER=vulkan \
    AQUEOUS_CONFIG="$WM_CONFIG" \
    AQUEOUS_RULES="$RULES_CONFIG" \
    AQUEOUS_VULKAN_BLUR_UNCACHED="$UNCACHED_ORACLE" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_CONFIG_HOME="$RUNTIME_DIR/config" \
    HOME="$SANDBOX_HOME" \
    "$AQUEOUS_COMPOSITOR_BIN" \
        -no-xwayland -policy compare -log-level debug -c true \
        >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 240); do
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

nested_env=(
    env -u LD_PRELOAD
    XDG_RUNTIME_DIR="$RUNTIME_DIR"
    WAYLAND_DISPLAY="$socket"
)

OUTPUT_SOCKET="$RUNTIME_DIR/aqueous/outputd.sock"
for _ in $(seq 1 240); do
    [ -S "$OUTPUT_SOCKET" ] && break
    sleep 0.05
done
[ -S "$OUTPUT_SOCKET" ] || die "output service did not create its socket"

output_request() {
    printf '%s\n' "$1" |
        timeout 5s nc -U -N -w 3 "$OUTPUT_SOCKET" 2>/dev/null |
        head -1
}

output_state=$(output_request '{"op":"list"}')
OUTPUT_NAME=$(jq -r '.outputs[0].name // empty' <<<"$output_state")
[ -n "$OUTPUT_NAME" ] || die "nested output was not reported"
set_response=$(output_request \
    "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"mode\":\"1568x900\"}]}")
jq -e '.ok == true' >/dev/null <<<"$set_response" ||
    die "output service rejected 1568x900: $set_response"
for _ in $(seq 1 240); do
    output_state=$(output_request '{"op":"list"}')
    if jq -e \
        '.outputs[0].enabled == true and
         .outputs[0].current_mode.width == 1568 and
         .outputs[0].current_mode.height == 900' \
        >/dev/null <<<"$output_state"; then
        break
    fi
    sleep 0.05
done
jq -e \
    '.outputs[0].current_mode.width == 1568 and
     .outputs[0].current_mode.height == 900' \
    >/dev/null <<<"$output_state" ||
    die "output did not settle at 1568x900"
jq . <<<"$output_state" >"$ARTIFACT_DIR/output.json"

capture_output() {
    local destination=$1
    "${nested_env[@]}" grim -o "$OUTPUT_NAME" "$destination"
    [ -s "$destination" ] || die "empty capture: $destination"
}

launch_client() {
    local role=$1 label=$2
    local ready="$TEST_ROOT/$label.ready"
    local log="$ARTIFACT_DIR/$label.log"
    "${nested_env[@]}" "$REFERENCE_BIN" "$role" "$ready" >"$log" 2>&1 &
    local pid=$!
    CLIENT_PIDS+=("$pid")
    for _ in $(seq 1 240); do
        [ -f "$ready" ] && return
        kill -0 "$pid" 2>/dev/null || {
            cat "$log" >&2
            die "$label exited before mapping"
        }
        sleep 0.05
    done
    die "$label did not map"
}

background_ready="$TEST_ROOT/background.ready"
"${nested_env[@]}" "$BACKGROUND_BIN" \
    "$background_ready" "$BACKGROUND_CONTROL" \
    >"$ARTIFACT_DIR/background.log" 2>&1 &
BACKGROUND_PID=$!
CLIENT_PIDS+=("$BACKGROUND_PID")
for _ in $(seq 1 240); do
    [ -f "$background_ready" ] && break
    kill -0 "$BACKGROUND_PID" 2>/dev/null || {
        cat "$ARTIFACT_DIR/background.log" >&2
        die "domain background exited before mapping"
    }
    sleep 0.05
done
[ -f "$background_ready" ] || die "domain background did not map"
read -r _ BACKGROUND_WIDTH BACKGROUND_HEIGHT <"$background_ready"
[ "$BACKGROUND_WIDTH $BACKGROUND_HEIGHT" = "1568 900" ] ||
    die "domain background mapped at ${BACKGROUND_WIDTH}x${BACKGROUND_HEIGHT}"
capture_output "$ARTIFACT_DIR/source-background.png"

launch_client blur-probe-left blur-probe-left
launch_client blur-probe-right blur-probe-right

windows_json() {
    "${nested_env[@]}" "$AQUEOUSCTL_BIN" windows --json
}

scene_text() {
    "${nested_env[@]}" "$AQUEOUSCTL_BIN" scene
}

wait_settled() {
    local expected_focus=$1 json scene active_snapshots
    for _ in $(seq 1 300); do
        json=$(windows_json 2>/dev/null || echo '[]')
        if ! jq -e --arg focus "$expected_focus" '
            length == 2 and
            any(.[]; .app_id == $focus and
                (.states | index("focused") != null)) and
            ([.[] | .geometry] | sort_by(.x)) ==
                [
                    {"x":8,"y":8,"width":774,"height":884},
                    {"x":786,"y":8,"width":774,"height":884}
                ]
        ' >/dev/null <<<"$json"; then
            sleep 0.04
            continue
        fi
        scene=$(scene_text 2>/dev/null || true)
        active_snapshots=$(
            grep -F 'window animation snapshot [tree]' <<<"$scene" |
                grep -vc ' disabled' || true
        )
        if [ "$active_snapshots" = 0 ]; then
            sleep 0.08
            return
        fi
        sleep 0.04
    done
    windows_json >&2 || true
    scene_text >&2 || true
    die "windows did not settle with focus on $expected_focus"
}

save_state() {
    local label=$1 expected_focus=$2
    wait_settled "$expected_focus"
    windows_json | jq . >"$ARTIFACT_DIR/$label-windows.json"
    scene_text >"$ARTIFACT_DIR/$label-scene.txt"
    capture_output "$ARTIFACT_DIR/$label.png"
}

image_difference() {
    magick "$1" "$2" \
        -compose difference -composite \
        -alpha off -format '%[fx:mean]' info:
}

assert_reference_match() {
    local left=$1 right=$2 description=$3 difference
    difference=$(image_difference "$left" "$right")
    printf '%s=%s\n' "$description" "$difference" \
        >>"$ARTIFACT_DIR/comparisons.txt"
    awk -v difference="$difference" -v limit="$REFERENCE_TOLERANCE" \
        'BEGIN { exit !(difference <= limit) }' ||
        die "$description exceeds tolerance $REFERENCE_TOLERANCE: $difference"
}

CONTROL_SEQUENCE=0
send_background_command() {
    local operation=$1 value=$2 expected_x=$3 expected_y=$4
    local expected_width=$5 expected_height=$6
    CONTROL_SEQUENCE=$((CONTROL_SEQUENCE + 1))
    printf '%d %s %d\n' "$CONTROL_SEQUENCE" "$operation" "$value" \
        >"$BACKGROUND_CONTROL/command.tmp"
    mv "$BACKGROUND_CONTROL/command.tmp" "$BACKGROUND_CONTROL/command"
    for _ in $(seq 1 300); do
        if [ -f "$BACKGROUND_CONTROL/ack" ]; then
            read -r sequence ack_operation x y width height \
                <"$BACKGROUND_CONTROL/ack"
            if [ "$sequence" = "$CONTROL_SEQUENCE" ]; then
                [ "$ack_operation" = "$operation" ] ||
                    die "background acknowledged the wrong operation"
                [ "$x $y $width $height" = \
                    "$expected_x $expected_y $expected_width $expected_height" ] ||
                    die "unexpected $operation damage: $x $y $width $height"
                cat "$BACKGROUND_CONTROL/ack" \
                    >>"$ARTIFACT_DIR/background-controls.log"
                return
            fi
        fi
        kill -0 "$BACKGROUND_PID" 2>/dev/null ||
            die "domain background exited during $operation"
        sleep 0.04
    done
    die "domain background did not complete $operation"
}

: >"$ARTIFACT_DIR/comparisons.txt"
save_state static-right aqueous.effects.blur-probe-right
save_state cache-hit aqueous.effects.blur-probe-right
assert_reference_match \
    "$ARTIFACT_DIR/static-right.png" \
    "$ARTIFACT_DIR/cache-hit.png" \
    cache_hit

send_background_command edge 1 720 300 36 160
save_state edge-incremental aqueous.effects.blur-probe-right
send_background_command repaint 1 0 0 1568 900
save_state edge-full aqueous.effects.blur-probe-right
assert_reference_match \
    "$ARTIFACT_DIR/edge-incremental.png" \
    "$ARTIFACT_DIR/edge-full.png" \
    localized_vs_full

"${nested_env[@]}" wlrctl keyboard type h modifiers SUPER
save_state focus-left aqueous.effects.blur-probe-left
"${nested_env[@]}" wlrctl keyboard type l modifiers SUPER
save_state focus-right-roundtrip aqueous.effects.blur-probe-right
assert_reference_match \
    "$ARTIFACT_DIR/edge-full.png" \
    "$ARTIFACT_DIR/focus-right-roundtrip.png" \
    focus_roundtrip

analyze_domain() {
    local label=$1 image="$ARTIFACT_DIR/$1.png"
    local state="$ARTIFACT_DIR/$1-windows.json"
    local check_cross=${2:-1}
    local right_x right_y right_height analysis_x analysis_y analysis_height
    local cross_bleed edge_mean interior_mean edge_excess flat_run
    right_x=$(jq -r \
        '.[] | select(.app_id == "aqueous.effects.blur-probe-right") |
         .geometry.x' "$state")
    right_y=$(jq -r \
        '.[] | select(.app_id == "aqueous.effects.blur-probe-right") |
         .geometry.y' "$state")
    right_height=$(jq -r \
        '.[] | select(.app_id == "aqueous.effects.blur-probe-right") |
         .geometry.height' "$state")
    # Exclude the two-pixel border and its antialiasing from both metrics.
    analysis_x=$((right_x + 4))
    analysis_y=$((right_y + 120))
    analysis_height=$((right_height - 240))

    # The lower sibling's witness is strongly blue while every right-domain
    # backdrop color has blue no greater than red or green. A positive blue
    # residual in this narrow, border-free seam band therefore measures client
    # pixels imported across the blur domain.
    magick "$image" \
        -crop "48x${analysis_height}+${analysis_x}+${analysis_y}" +repage \
        -alpha off -fx 'max(0,b-max(r,g))' \
        "$ARTIFACT_DIR/$label-cross-bleed-mask.png"
    cross_bleed=$(
        magick "$ARTIFACT_DIR/$label-cross-bleed-mask.png" \
            -format '%[fx:mean]' info:
    )

    # Average vertically before reading the seam profile. The known-bad clamp
    # shader measures at least +0.032 edge excess in this fixture; reflection
    # measures about -0.022. The 0.015 ceiling leaves margin on both sides.
    magick "$image" \
        -crop "96x${analysis_height}+${analysis_x}+${analysis_y}" +repage \
        -alpha off -colorspace gray -resize 96x1! -depth 8 \
        "$ARTIFACT_DIR/$label-edge-profile.png"
    magick "$ARTIFACT_DIR/$label-edge-profile.png" \
        -filter point -resize 768x64! \
        "$ARTIFACT_DIR/$label-edge-profile-view.png"
    magick "$ARTIFACT_DIR/$label-edge-profile.png" txt:- \
        >"$ARTIFACT_DIR/$label-edge-profile.txt"
    flat_run=$(
        sed -n 's/^[0-9][0-9]*,0: (\([0-9][0-9]*\)).*/\1/p' \
            "$ARTIFACT_DIR/$label-edge-profile.txt" |
        awk '
            NR == 1 { previous = $1; run = 1; longest = 1; next }
            {
                if ($1 == previous) {
                    run++
                } else {
                    if (run > longest) longest = run
                    previous = $1
                    run = 1
                }
            }
            END {
                if (run > longest) longest = run
                print longest + 0
            }
        '
    )
    edge_mean=$(
        magick "$ARTIFACT_DIR/$label-edge-profile.png" \
            -crop 24x1+0+0 -format '%[fx:mean]' info:
    )
    interior_mean=$(
        magick "$ARTIFACT_DIR/$label-edge-profile.png" \
            -crop 32x1+64+0 -format '%[fx:mean]' info:
    )
    edge_excess=$(awk -v edge="$edge_mean" -v interior="$interior_mean" \
        'BEGIN { print edge - interior }')

    {
        printf '%s_cross_bleed=%s\n' "$label" "$cross_bleed"
        printf '%s_edge_mean=%s\n' "$label" "$edge_mean"
        printf '%s_interior_mean=%s\n' "$label" "$interior_mean"
        printf '%s_edge_excess=%s\n' "$label" "$edge_excess"
        printf '%s_longest_flat_run=%s\n' "$label" "$flat_run"
    } >>"$ARTIFACT_DIR/domain-metrics.txt"

    if [ "$check_cross" = 1 ]; then
        awk -v value="$cross_bleed" -v limit="$CROSS_BLEED_LIMIT" \
            'BEGIN { exit !(value <= limit) }' ||
            die "$label imported the sibling client witness: $cross_bleed"
    fi
    awk -v value="$edge_excess" -v limit="$EDGE_EXCESS_LIMIT" \
        'BEGIN { exit !(value <= limit) }' ||
        die "$label contains a constant-clamped bright edge: $edge_excess"
}

: >"$ARTIFACT_DIR/domain-metrics.txt"
analyze_domain static-right 1
# Focusing left restacks it above the right tile, so this state verifies the
# focus transition and edge profile but is not a sibling-isolation oracle.
analyze_domain focus-left 0
analyze_domain focus-right-roundtrip 1

if grep -Eiq \
    'VUID-|validation error|Validation Error|validation layer.*error|UNASSIGNED-' \
    "$COMPOSITOR_LOG"; then
    tail -160 "$COMPOSITOR_LOG" >&2
    die "Vulkan validation reported an error"
fi
if grep -Eq \
    'Vulkan (cached blur processing|uncached blur processing|backdrop blur) failed:' \
    "$COMPOSITOR_LOG"; then
    tail -160 "$COMPOSITOR_LOG" >&2
    die "the Vulkan blur renderer reported a runtime failure"
fi

"${nested_env[@]}" "$EXIT_BIN" >"$ARTIFACT_DIR/exit.log" 2>&1 &
EXIT_PID=$!
shutdown_status=0
wait "$COMPOSITOR_PID" || shutdown_status=$?
COMPOSITOR_PID=""
kill "$EXIT_PID" 2>/dev/null || true
wait "$EXIT_PID" 2>/dev/null || true
EXIT_PID=""
[ "$shutdown_status" -eq 0 ] ||
    die "compositor exited with status $shutdown_status"

blur_counts=$(
    sed -n \
        's/.*destroyed Vulkan blur after \([0-9][0-9]*\) checkpoints, \([0-9][0-9]*\) offscreen draws, and \([0-9][0-9]*\) composites (\([0-9][0-9]*\) cache hits, \([0-9][0-9]*\) partial rebuilds, \([0-9][0-9]*\) full rebuilds, \([0-9][0-9]*\) pixels processed).*/\1 \2 \3 \4 \5 \6 \7/p' \
        "$COMPOSITOR_LOG" |
        tail -1
)
[ -n "$blur_counts" ] || {
    tail -120 "$COMPOSITOR_LOG" >&2
    die "blur teardown counts were not logged"
}
read -r blur_checkpoints blur_offscreen_draws blur_composites \
    blur_cache_hits blur_partial_rebuilds blur_full_rebuilds \
    blur_pixels_processed \
    <<<"$blur_counts"
if [ "$UNCACHED_ORACLE" = 1 ]; then
    [ "$blur_cache_hits" -eq 0 ] &&
        [ "$blur_partial_rebuilds" -eq 0 ] &&
        [ "$blur_full_rebuilds" -eq 0 ] &&
        [ "$blur_pixels_processed" -eq 0 ] ||
        die "uncached oracle unexpectedly used the blur cache"
else
    [ "$blur_cache_hits" -gt 0 ] ||
        die "blur cache did not record a reusable checkpoint"
    [ "$blur_partial_rebuilds" -gt 0 ] ||
        die "blur cache did not record the localized rebuild"
    [ "$blur_full_rebuilds" -gt 0 ] ||
        die "blur cache did not record a full rebuild"
fi
{
    printf 'backend=%s\n' "$TEST_BACKEND"
    printf 'uncached=%s\n' "$UNCACHED_ORACLE"
    printf 'blur_checkpoints=%s\n' "$blur_checkpoints"
    printf 'blur_offscreen_draws=%s\n' "$blur_offscreen_draws"
    printf 'blur_composites=%s\n' "$blur_composites"
    printf 'blur_cache_hits=%s\n' "$blur_cache_hits"
    printf 'blur_partial_rebuilds=%s\n' "$blur_partial_rebuilds"
    printf 'blur_full_rebuilds=%s\n' "$blur_full_rebuilds"
    printf 'blur_pixels_processed=%s\n' "$blur_pixels_processed"
} >"$ARTIFACT_DIR/run-metrics.txt"

echo "PASS: dwindle blur domains, sibling isolation, focus, and cache damage"
echo "artifacts: $ARTIFACT_DIR"
