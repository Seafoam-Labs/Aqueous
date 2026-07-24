#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURE_SOURCE="$here/scripts/fixtures/visual-effects-reference.c"
EXIT_FIXTURE_SOURCE="$here/scripts/fixtures/exit-session.c"
WM_CONFIG="$here/scripts/fixtures/visual-effects-wm.toml"
LAYOUT_CONFIG="$here/scripts/fixtures/visual-effects-layout.toml"
RULES_CONFIG="$here/scripts/fixtures/visual-effects-rules.toml"
WINDOW_MANAGEMENT_PROTOCOL="$here/protocol/river-window-management-v1.xml"
WORKSPACE_PROTOCOL="$here/protocol/upstream/ext-workspace-v1.xml"
STRESS_FRAMES=${AQUEOUS_VULKAN_PROBE_FRAMES:-4096}
STRESS_TIMEOUT_SECONDS=${AQUEOUS_VULKAN_PROBE_TIMEOUT_SECONDS:-240}
REQUIRE_VALIDATION=${AQUEOUS_VULKAN_PROBE_REQUIRE_VALIDATION:-1}
REQUIRE_EXPLICIT_SYNC=${AQUEOUS_VULKAN_PROBE_REQUIRE_EXPLICIT_SYNC:-1}

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$#" -le 1 ] || die "usage: $0 [OUTPUT_DIRECTORY]"
[[ "$STRESS_FRAMES" =~ ^[1-9][0-9]*$ ]] ||
    die "AQUEOUS_VULKAN_PROBE_FRAMES must be a positive integer"
[[ "$STRESS_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
    die "AQUEOUS_VULKAN_PROBE_TIMEOUT_SECONDS must be a positive integer"
[[ "$REQUIRE_VALIDATION" = 0 || "$REQUIRE_VALIDATION" = 1 ]] ||
    die "AQUEOUS_VULKAN_PROBE_REQUIRE_VALIDATION must be 0 or 1"
[[ "$REQUIRE_EXPLICIT_SYNC" = 0 || "$REQUIRE_EXPLICIT_SYNC" = 1 ]] ||
    die "AQUEOUS_VULKAN_PROBE_REQUIRE_EXPLICIT_SYNC must be 0 or 1"
[ -x "$AQUEOUS_COMPOSITOR_BIN" ] ||
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
for file in \
    "$FIXTURE_SOURCE" \
    "$EXIT_FIXTURE_SOURCE" \
    "$WM_CONFIG" \
    "$LAYOUT_CONFIG" \
    "$RULES_CONFIG" \
    "$WINDOW_MANAGEMENT_PROTOCOL" \
    "$WORKSPACE_PROTOCOL"; do
    [ -r "$file" ] || die "missing test input: $file"
done
for tool in cc grim jq ldd magick nc nm pkg-config readelf sha256sum wayland-scanner; do
    have "$tool" || die "$tool is required"
done
pkg-config --exists wayland-client wayland-protocols ||
    die "Wayland client development files and protocols are required"

readelf -d "$AQUEOUS_COMPOSITOR_BIN" | grep 'libvulkan.so' >/dev/null ||
    die "the compositor is not linked directly to Vulkan"
if readelf -d "$AQUEOUS_COMPOSITOR_BIN" | grep 'libscenefx' >/dev/null; then
    die "the Vulkan-effects compositor must not be linked to SceneFX"
fi
wlroots_library=$(
    ldd "$AQUEOUS_COMPOSITOR_BIN" |
        awk '/libwlroots-0.20.so/ { print $3; exit }'
)
[ -n "$wlroots_library" ] && [ -r "$wlroots_library" ] ||
    die "unable to resolve the compositor's wlroots library"
for symbol in \
    wlr_scene_output_set_buffer_render_hook \
    wlr_vk_render_pass_get_attribs; do
    nm -D --defined-only "$wlroots_library" | grep " $symbol$" >/dev/null ||
        die "wlroots is missing the render-seam symbol $symbol"
done
grep -a -q 'Vulkan render probe initialized' "$AQUEOUS_COMPOSITOR_BIN" ||
    die "the compositor was not built with -Dvulkan-render-probe=true"

HOST_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}
HOST_WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
[ -n "$HOST_RUNTIME_DIR" ] && [ -n "$HOST_WAYLAND_DISPLAY" ] ||
    die "a parent Wayland display is required"
[ -S "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ] ||
    die "the parent Wayland socket is unavailable"

validation_manifest=$(
    find /usr/share/vulkan /etc/vulkan -type f \
        -name 'VkLayer_khronos_validation.json' -print -quit 2>/dev/null || true
)
if [ "$REQUIRE_VALIDATION" = 1 ] && [ -z "$validation_manifest" ]; then
    die "VK_LAYER_KHRONOS_validation is required"
fi
VALIDATION_ENV=()
[ -z "$validation_manifest" ] ||
    VALIDATION_ENV=(VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation)

TEST_ROOT=$(mktemp -d /tmp/aqueous-vulkan-render-seam.XXXXXX)
RUNTIME_DIR="$TEST_ROOT/runtime"
SANDBOX_HOME="$TEST_ROOT/home"
FIXTURE_BIN="$TEST_ROOT/visual-effects-reference"
EXIT_FIXTURE="$TEST_ROOT/exit-session"
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
CLIENT_LOG="$ARTIFACT_DIR/client.log"
COMPOSITOR_PID=""
CLIENT_PID=""
EXIT_PID=""

cleanup() {
    [ -z "$CLIENT_PID" ] || kill "$CLIENT_PID" 2>/dev/null || true
    [ -z "$CLIENT_PID" ] || wait "$CLIENT_PID" 2>/dev/null || true
    [ -z "$EXIT_PID" ] || kill "$EXIT_PID" 2>/dev/null || true
    [ -z "$EXIT_PID" ] || wait "$EXIT_PID" 2>/dev/null || true
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
    "$RUNTIME_DIR/aqueous-vulkan-probe-host"

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

wayland-scanner client-header "$WINDOW_MANAGEMENT_PROTOCOL" \
    "$TEST_ROOT/river-window-management-v1-client-protocol.h"
wayland-scanner private-code "$WINDOW_MANAGEMENT_PROTOCOL" \
    "$TEST_ROOT/river-window-management-v1-protocol.c"
wayland-scanner private-code "$WORKSPACE_PROTOCOL" \
    "$TEST_ROOT/ext-workspace-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$EXIT_FIXTURE_SOURCE" \
    "$TEST_ROOT/river-window-management-v1-protocol.c" \
    "$TEST_ROOT/ext-workspace-v1-protocol.c" \
    -o "$EXIT_FIXTURE" $(pkg-config --cflags --libs wayland-client)

env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
    "${VALIDATION_ENV[@]}" \
    WLR_BACKENDS=wayland \
    WLR_WL_OUTPUTS=1 \
    AQUEOUS_CONFIG="$WM_CONFIG" \
    AQUEOUS_LAYOUT="$LAYOUT_CONFIG" \
    AQUEOUS_RULES="$RULES_CONFIG" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_CONFIG_HOME="$RUNTIME_DIR/config" \
    HOME="$SANDBOX_HOME" \
    WAYLAND_DISPLAY=aqueous-vulkan-probe-host \
    "$AQUEOUS_COMPOSITOR_BIN" \
        -no-xwayland -policy compare -log-level info -c true \
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

wait_output_state() {
    local width=$1 height=$2 scale=$3 transform=$4
    for _ in $(seq 1 240); do
        output_state=$(output_request '{"op":"list"}')
        if jq -e \
            --argjson width "$width" \
            --argjson height "$height" \
            --argjson scale "$scale" \
            --arg transform "$transform" \
            '.outputs[0].current_mode.width == $width and
             .outputs[0].current_mode.height == $height and
             ((.outputs[0].scale - $scale) | fabs) < 0.001 and
             .outputs[0].transform == $transform' \
            >/dev/null <<<"$output_state"; then
            sleep 0.15
            return
        fi
        sleep 0.05
    done
    die "output did not settle at ${width}x${height}, scale $scale, transform $transform"
}

set_output_state() {
    local width=$1 height=$2 scale=$3 transform=$4 response
    response=$(output_request \
        "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"mode\":\"${width}x${height}\",\"scale\":$scale,\"transform\":\"$transform\"}]}")
    jq -e '.ok == true' >/dev/null <<<"$response" ||
        die "output service rejected the state change: $response"
    wait_output_state "$width" "$height" "$scale" "$transform"
}

capture_output() {
    local destination=$1
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        grim -o "$OUTPUT_NAME" "$destination"
    [ -s "$destination" ] || die "empty capture: $destination"
}

green_pixel_count() {
    magick "$1" -alpha off \
        -fx 'g > 0.55 && g-r > 0.25 && g-b > 0.20 ? 1 : 0' \
        -format '%[fx:mean*w*h]' info:
}

CONTROL_SEQUENCE=0

send_background_command() {
    local operation=$1 value=$2 expected_x=$3 expected_y=$4
    local expected_width=$5 expected_height=$6
    CONTROL_SEQUENCE=$((CONTROL_SEQUENCE + 1))
    printf '%d %s %d\n' "$CONTROL_SEQUENCE" "$operation" "$value" \
        >"$BACKGROUND_CONTROL/command.tmp"
    mv "$BACKGROUND_CONTROL/command.tmp" "$BACKGROUND_CONTROL/command"
    local deadline=$((SECONDS + STRESS_TIMEOUT_SECONDS))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$BACKGROUND_CONTROL/ack" ]; then
            read -r sequence ack_operation x y width height \
                <"$BACKGROUND_CONTROL/ack"
            if [ "$sequence" = "$CONTROL_SEQUENCE" ]; then
                [ "$ack_operation" = "$operation" ] ||
                    die "fixture acknowledged the wrong operation"
                [ "$x $y $width $height" = \
                    "$expected_x $expected_y $expected_width $expected_height" ] ||
                    die "fixture acknowledged unexpected damage: $x $y $width $height"
                cat "$BACKGROUND_CONTROL/ack" \
                    >>"$ARTIFACT_DIR/background-controls.log"
                return
            fi
        fi
        kill -0 "$CLIENT_PID" 2>/dev/null ||
            die "fixture exited while processing $operation"
        kill -0 "$COMPOSITOR_PID" 2>/dev/null ||
            die "compositor exited while processing $operation"
        sleep 0.05
    done
    die "fixture did not complete $operation within $STRESS_TIMEOUT_SECONDS seconds"
}

set_output_state 1920 1080 1 normal

ready="$TEST_ROOT/background.ready"
env -u LD_PRELOAD \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    WAYLAND_DISPLAY="$socket" \
    "$FIXTURE_BIN" background "$ready" "$BACKGROUND_CONTROL" \
    >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!
for _ in $(seq 1 240); do
    [ -f "$ready" ] && break
    kill -0 "$CLIENT_PID" 2>/dev/null || {
        cat "$CLIENT_LOG" >&2
        die "fixture exited before mapping"
    }
    sleep 0.05
done
[ -f "$ready" ] || die "fixture did not map"
read -r _ BACKGROUND_WIDTH BACKGROUND_HEIGHT <"$ready"
[ "$BACKGROUND_WIDTH $BACKGROUND_HEIGHT" = "1760 920" ] ||
    die "fixture mapped at an unexpected size"

send_background_command \
    reset 0 0 0 "$BACKGROUND_WIDTH" "$BACKGROUND_HEIGHT"
capture_output "$ARTIFACT_DIR/rounded-normal.png"
rounded_values=$(
    magick "$ARTIFACT_DIR/rounded-normal.png" \
        -format '%[fx:p{960,540}.g-p{960,540}.r] %[fx:p{81,81}.g-p{81,81}.r] %[fx:p{144,144}.g-p{144,144}.r]' \
        info:
)
read -r center_green corner_green inset_green <<<"$rounded_values"
awk \
    -v center="$center_green" \
    -v corner="$corner_green" \
    -v inset="$inset_green" \
    'BEGIN {
        exit !(center > 0.30 && inset > 0.30 &&
            center - corner > 0.35 && inset - corner > 0.35)
    }' ||
    die "screencopy does not contain the expected rounded Vulkan probe"

send_background_command localized 1 360 240 160 120
capture_output "$ARTIFACT_DIR/localized-damage.png"
difference_stats=$(
    magick \
        "$ARTIFACT_DIR/rounded-normal.png" \
        "$ARTIFACT_DIR/localized-damage.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h] %@' info:
)
read -r difference_pixels difference_bounds <<<"$difference_stats"
[[ "$difference_pixels" =~ ^[0-9]+$ ]] ||
    die "unable to measure localized damage"
[[ "$difference_bounds" =~ ^([0-9]+)x([0-9]+)[+]([0-9]+)[+]([0-9]+)$ ]] ||
    die "unable to locate localized damage"
diff_width=${BASH_REMATCH[1]}
diff_height=${BASH_REMATCH[2]}
diff_x=${BASH_REMATCH[3]}
diff_y=${BASH_REMATCH[4]}
awk \
    -v changed="$difference_pixels" \
    -v width="$diff_width" \
    -v height="$diff_height" \
    -v x="$diff_x" \
    -v y="$diff_y" \
    'BEGIN {
        exit !(changed > 1000 && changed <= 19200 &&
            x >= 440 && y >= 320 &&
            x + width <= 600 && y + height <= 440)
    }' ||
    die "render-probe changes escaped the submitted damage region"

set_output_state 1920 1080 1.25 90
capture_output "$ARTIFACT_DIR/rounded-scale-1.25-transform-90.png"
transformed_green=$(green_pixel_count \
    "$ARTIFACT_DIR/rounded-scale-1.25-transform-90.png")
awk -v pixels="$transformed_green" \
    'BEGIN { exit !(pixels > 1000) }' ||
    die "transformed fractional-scale capture is missing the Vulkan probe"

set_output_state 1920 1080 1 normal
send_background_command \
    reset 0 0 0 "$BACKGROUND_WIDTH" "$BACKGROUND_HEIGHT"
send_background_command stress "$STRESS_FRAMES" 360 240 160 120
capture_output "$ARTIFACT_DIR/after-buffer-reuse.png"
output_request '{"op":"list"}' | jq . >"$ARTIFACT_DIR/output.json"

env -u LD_PRELOAD \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    WAYLAND_DISPLAY="$socket" \
    "$EXIT_FIXTURE" &
EXIT_PID=$!
shutdown_status=0
wait "$COMPOSITOR_PID" || shutdown_status=$?
COMPOSITOR_PID=""
kill "$EXIT_PID" 2>/dev/null || true
wait "$EXIT_PID" 2>/dev/null || true
EXIT_PID=""
[ "$shutdown_status" -eq 0 ] ||
    die "compositor exited with status $shutdown_status"

probe_counts=$(
    sed -n \
        's/.*destroyed Vulkan render probe after \([0-9][0-9]*\) draws (\([0-9][0-9]*\) normal, \([0-9][0-9]*\) swapchain, \([0-9][0-9]*\) explicit-sync).*/\1 \2 \3 \4/p' \
        "$COMPOSITOR_LOG" |
        tail -1
)
[ -n "$probe_counts" ] || {
    tail -120 "$COMPOSITOR_LOG" >&2
    die "render-probe teardown counts were not logged"
}
read -r total_draws normal_draws swapchain_draws explicit_sync_draws \
    <<<"$probe_counts"
[ "$total_draws" -ge "$STRESS_FRAMES" ] ||
    die "render probe recorded fewer draws than the reuse stress"
[ "$normal_draws" -gt 0 ] ||
    die "ordinary Output.renderAndCommit did not invoke the render probe"
[ "$swapchain_draws" -gt 0 ] ||
    die "OutputManager swapchain rendering did not invoke the render probe"
if [ "$REQUIRE_EXPLICIT_SYNC" = 1 ] &&
    [ "$explicit_sync_draws" -ne "$total_draws" ]; then
    die "not every render-probe draw used wlroots' explicit-sync timeline"
fi
if grep -Eiq \
    'VUID-|validation error|Validation Error|validation layer.*error|UNASSIGNED-' \
    "$COMPOSITOR_LOG"; then
    tail -160 "$COMPOSITOR_LOG" >&2
    die "Vulkan validation reported an error"
fi
if grep -q 'Vulkan render probe failed:' "$COMPOSITOR_LOG"; then
    tail -160 "$COMPOSITOR_LOG" >&2
    die "the Vulkan render probe reported a runtime failure"
fi

{
    printf 'wlroots_library=%s\n' "$wlroots_library"
    printf 'validation_layer=%s\n' "${validation_manifest:-not-installed}"
    printf 'stress_frames=%s\n' "$STRESS_FRAMES"
    printf 'total_draws=%s\n' "$total_draws"
    printf 'normal_draws=%s\n' "$normal_draws"
    printf 'swapchain_draws=%s\n' "$swapchain_draws"
    printf 'explicit_sync_draws=%s\n' "$explicit_sync_draws"
    printf 'rounded_center_green_delta=%s\n' "$center_green"
    printf 'rounded_corner_green_delta=%s\n' "$corner_green"
    printf 'rounded_inset_green_delta=%s\n' "$inset_green"
    printf 'localized_changed_pixels=%s\n' "$difference_pixels"
    printf 'localized_difference_bounds=%s\n' "$difference_bounds"
    printf 'transformed_green_pixels=%s\n' "$transformed_green"
} >"$ARTIFACT_DIR/results.txt"
(
    cd "$ARTIFACT_DIR"
    find . -type f ! -name SHA256SUMS -print0 |
        sort -z |
        xargs -0 sha256sum >SHA256SUMS
)

echo "PASS: rounded Vulkan probe survived both render paths, damage, transform, scale, capture, and $STRESS_FRAMES reused-buffer frames"
