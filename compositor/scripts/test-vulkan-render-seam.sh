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
TEST_BACKEND=${AQUEOUS_VULKAN_EFFECTS_BACKEND:-auto}
UNCACHED_ORACLE=${AQUEOUS_VULKAN_BLUR_UNCACHED:-0}

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
[[ "$TEST_BACKEND" = auto || "$TEST_BACKEND" = wayland ||
    "$TEST_BACKEND" = headless ]] ||
    die "AQUEOUS_VULKAN_EFFECTS_BACKEND must be auto, wayland, or headless"
[[ "$UNCACHED_ORACLE" = 0 || "$UNCACHED_ORACLE" = 1 ]] ||
    die "AQUEOUS_VULKAN_BLUR_UNCACHED must be 0 or 1"
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
for tool in cc grim jq ldd magick nc nm pkg-config readelf sha256sum wayland-scanner wlrctl; do
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
    wlr_scene_output_set_buffer_needs_composition \
    wlr_scene_output_set_rect_render_hook \
    wlr_scene_output_set_render_hooks \
    wlr_scene_buffer_set_force_blend \
    wlr_scene_rect_set_force_blend \
    wlr_vk_renderer_enable_offscreen \
    wlr_vk_render_pass_run_offscreen \
    wlr_vk_render_pass_add_completion \
    wlr_vk_render_pass_set_texture_hook \
    wlr_vk_render_pass_get_attribs; do
    nm -D --defined-only "$wlroots_library" | grep " $symbol$" >/dev/null ||
        die "wlroots is missing the render-seam symbol $symbol"
done
grep -a -q 'Vulkan rounded effects pipeline initialized' "$AQUEOUS_COMPOSITOR_BIN" ||
    die "the compositor was not built with -Dvulkan-effects=true"
grep -a -q 'Vulkan backdrop-blur pipeline initialized' \
    "$AQUEOUS_COMPOSITOR_BIN" ||
    die "the compositor does not contain the blur pipeline"

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
BLUR_LOG="$ARTIFACT_DIR/blur.log"
OVERLAP_LOG="$ARTIFACT_DIR/blur-overlap.log"
COMPOSITOR_PID=""
CLIENT_PID=""
BLUR_PID=""
OVERLAP_PID=""
EXIT_PID=""

cleanup() {
    [ -z "$OVERLAP_PID" ] || kill "$OVERLAP_PID" 2>/dev/null || true
    [ -z "$OVERLAP_PID" ] || wait "$OVERLAP_PID" 2>/dev/null || true
    [ -z "$BLUR_PID" ] || kill "$BLUR_PID" 2>/dev/null || true
    [ -z "$BLUR_PID" ] || wait "$BLUR_PID" 2>/dev/null || true
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
BACKEND_ENV=()
if [ "$TEST_BACKEND" = wayland ]; then
    [ -n "$HOST_RUNTIME_DIR" ] && [ -n "$HOST_WAYLAND_DISPLAY" ] ||
        die "a parent Wayland display is required"
    [ -S "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ] ||
        die "the parent Wayland socket is unavailable"
    ln -s "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" \
        "$RUNTIME_DIR/aqueous-vulkan-effects-host"
    BACKEND_ENV=(
        WLR_BACKENDS=wayland
        WLR_WL_OUTPUTS=1
        WAYLAND_DISPLAY=aqueous-vulkan-effects-host
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
    "${BACKEND_ENV[@]}" \
    AQUEOUS_CONFIG="$WM_CONFIG" \
    AQUEOUS_LAYOUT="$LAYOUT_CONFIG" \
    AQUEOUS_RULES="$RULES_CONFIG" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_CONFIG_HOME="$RUNTIME_DIR/config" \
    HOME="$SANDBOX_HOME" \
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
             .outputs[0].enabled == true and
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

set_output_mode() {
    local width=$1 height=$2 response
    response=$(output_request \
        "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"mode\":\"${width}x${height}\"}]}")
    jq -e '.ok == true' >/dev/null <<<"$response" ||
        die "output service rejected the mode change: $response"
    wait_output_state "$width" "$height" 1 normal
}

wait_output_enabled() {
    local enabled=$1
    for _ in $(seq 1 240); do
        output_state=$(output_request '{"op":"list"}')
        if jq -e --argjson enabled "$enabled" \
            '.outputs[0].enabled == $enabled' \
            >/dev/null <<<"$output_state"; then
            sleep 0.15
            return
        fi
        sleep 0.05
    done
    die "output did not settle with enabled=$enabled"
}

set_output_enabled() {
    local enabled=$1 response
    response=$(output_request \
        "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"enabled\":$enabled}]}")
    jq -e '.ok == true' >/dev/null <<<"$response" ||
        die "output service rejected enabled=$enabled: $response"
    wait_output_enabled "$enabled"
}

capture_output() {
    local destination=$1
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        grim -o "$OUTPUT_NAME" "$destination"
    [ -s "$destination" ] || die "empty capture: $destination"
}

capture_output_with_cursor() {
    local destination=$1
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        grim -c -o "$OUTPUT_NAME" "$destination"
    [ -s "$destination" ] || die "empty cursor capture: $destination"
}

move_pointer() {
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        wlrctl pointer move -10000 -10000
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        wlrctl pointer move "$1" "$2"
}

send_key() {
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        wlrctl keyboard type "$1"
}

nonblack_pixel_count() {
    magick "$1" -alpha off \
        -fx 'max(r,max(g,b)) > 0.02 ? 1 : 0' \
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

set_output_mode 1920 1080

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
        -format '%[fx:max(p{78,78}.r,max(p{78,78}.g,p{78,78}.b))] %[fx:max(p{82,82}.r,max(p{82,82}.g,p{82,82}.b))] %[fx:max(p{95,95}.r,max(p{95,95}.g,p{95,95}.b))] %[fx:max(p{960,78}.r,max(p{960,78}.g,p{960,78}.b))] %[fx:max(p{960,540}.r,max(p{960,540}.g,p{960,540}.b))]' \
        info:
)
read -r outer_corner antialias_corner inset_content straight_border center_content \
    <<<"$rounded_values"
awk \
    -v outer="$outer_corner" \
    -v antialias="$antialias_corner" \
    -v inset="$inset_content" \
    -v border="$straight_border" \
    -v center="$center_content" \
    'BEGIN {
        exit !(outer < 0.02 &&
            antialias > 0.10 && antialias < 0.60 &&
            inset > 0.10 && border > 0.30 && center > 0.20)
    }' ||
    die "screencopy does not contain the expected rounded texture and outline"

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
    die "rounded-effects changes escaped the submitted damage region"

set_output_state 1920 1080 1.25 90
capture_output "$ARTIFACT_DIR/rounded-scale-1.25-transform-90.png"
set_output_state 1920 1080 1.5 180
capture_output "$ARTIFACT_DIR/rounded-scale-1.5-transform-180.png"
set_output_state 1920 1080 2 270
capture_output "$ARTIFACT_DIR/rounded-scale-2-transform-270.png"
for capture in \
    "$ARTIFACT_DIR/rounded-scale-1.25-transform-90.png" \
    "$ARTIFACT_DIR/rounded-scale-1.5-transform-180.png" \
    "$ARTIFACT_DIR/rounded-scale-2-transform-270.png"; do
    transformed_pixels=$(nonblack_pixel_count "$capture")
    awk -v pixels="$transformed_pixels" \
        'BEGIN { exit !(pixels > 1000) }' ||
        die "scaled/rotated capture is missing rounded Vulkan content: $capture"
done

set_output_state 1920 1080 1 normal
send_background_command \
    reset 0 0 0 "$BACKGROUND_WIDTH" "$BACKGROUND_HEIGHT"
capture_output "$ARTIFACT_DIR/blur-source.png"

blur_ready="$TEST_ROOT/blur.ready"
env -u LD_PRELOAD \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    WAYLAND_DISPLAY="$socket" \
    "$FIXTURE_BIN" blur "$blur_ready" \
    >"$BLUR_LOG" 2>&1 &
BLUR_PID=$!
for _ in $(seq 1 240); do
    [ -f "$blur_ready" ] && break
    kill -0 "$BLUR_PID" 2>/dev/null || {
        cat "$BLUR_LOG" >&2
        die "blur fixture exited before mapping"
    }
    sleep 0.05
done
[ -f "$blur_ready" ] || die "blur fixture did not map"
read -r _ BLUR_WIDTH BLUR_HEIGHT <"$blur_ready"
[ "$BLUR_WIDTH $BLUR_HEIGHT" = "760 520" ] ||
    die "blur fixture mapped at an unexpected size"
capture_output "$ARTIFACT_DIR/blur-static.png"
content_order_values=$(
    magick "$ARTIFACT_DIR/blur-static.png" \
        -format '%[fx:(p{741,600}.r+p{741,600}.g+p{741,600}.b)/3] %[fx:(p{754,600}.r+p{754,600}.g+p{754,600}.b)/3] %[fx:(p{270,600}.r+p{270,600}.g+p{270,600}.b)/3] %[fx:abs(p{572,438}.r-p{588,438}.r)+abs(p{572,438}.g-p{588,438}.g)+abs(p{572,438}.b-p{588,438}.b)]' \
        info:
)
read -r blur_grid blur_grid_adjacent blur_frame blur_content_contrast \
    <<<"$content_order_values"
awk \
    -v grid="$blur_grid" \
    -v adjacent="$blur_grid_adjacent" \
    -v frame="$blur_frame" \
    -v contrast="$blur_content_contrast" \
    'BEGIN {
        exit !(grid > adjacent + 0.10 &&
            frame > 0.80 &&
            contrast > 1.0)
    }' ||
    die "backdrop blur was composited over the blur window's client content"

# A screencopy with cursor overlay temporarily forces wlroots' software cursor
# path. Cursor-only output damage must composite the existing blur cache, not
# invalidate it or feed the cursor rectangles back into the cached backdrop.
move_pointer 960 540
capture_output "$ARTIFACT_DIR/blur-before-software-cursor.png"
capture_output_with_cursor "$ARTIFACT_DIR/blur-software-cursor.png"
sleep 0.1
capture_output "$ARTIFACT_DIR/blur-after-software-cursor.png"
# Some nested backends retain the actual 16x23 cursor for this first frame.
# Exclude only a tight cursor footprint; the cache-corruption halo extends
# beyond it and remains visible to this comparison.
cursor_damage_difference=$(
    magick \
        "$ARTIFACT_DIR/blur-before-software-cursor.png" \
        "$ARTIFACT_DIR/blur-after-software-cursor.png" \
        -compose difference -composite \
        -compose over -fill black -draw 'rectangle 952,532 980,572' \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h]' info:
)
awk -v changed="$cursor_damage_difference" \
    'BEGIN { exit !(changed <= 64) }' ||
    die "software cursor damage contaminated the cached backdrop"

# Recreate the nested backend swapchain at a smaller size and then return to
# the original extent. Drivers commonly recycle the raw VkImageView handles in
# this pattern, which previously let the blur cache select a stale descriptor.
set_output_mode 1280 720
capture_output "$ARTIFACT_DIR/blur-mode-small.png"
set_output_mode 1920 1080
capture_output "$ARTIFACT_DIR/blur-mode-roundtrip.png"
roundtrip_pixels=$(nonblack_pixel_count \
    "$ARTIFACT_DIR/blur-mode-roundtrip.png")
awk -v pixels="$roundtrip_pixels" \
    'BEGIN { exit !(pixels > 1000) }' ||
    die "blur content did not survive the output mode roundtrip"

for generation in 1 2 3 4; do
    send_background_command \
        localized-cache-hit "$generation" 1400 700 80 60
done
capture_output "$ARTIFACT_DIR/blur-cache-hit.png"

set_output_state 1920 1080 1.25 90
capture_output "$ARTIFACT_DIR/blur-scale-1.25-transform-90.png"
set_output_state 1920 1080 1.5 180
capture_output "$ARTIFACT_DIR/blur-scale-1.5-transform-180.png"
set_output_state 1920 1080 2 270
capture_output "$ARTIFACT_DIR/blur-scale-2-transform-270.png"
for capture in \
    "$ARTIFACT_DIR/blur-scale-1.25-transform-90.png" \
    "$ARTIFACT_DIR/blur-scale-1.5-transform-180.png" \
    "$ARTIFACT_DIR/blur-scale-2-transform-270.png"; do
    transformed_pixels=$(nonblack_pixel_count "$capture")
    awk -v pixels="$transformed_pixels" \
        'BEGIN { exit !(pixels > 1000) }' ||
        die "scaled/rotated capture is missing Vulkan blur content: $capture"
done
set_output_state 1920 1080 1 normal

send_background_command \
    motion 19 0 0 "$BACKGROUND_WIDTH" "$BACKGROUND_HEIGHT"
capture_output "$ARTIFACT_DIR/blur-motion.png"
motion_difference=$(
    magick \
        "$ARTIFACT_DIR/blur-static.png" \
        "$ARTIFACT_DIR/blur-motion.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h]' info:
)
awk -v changed="$motion_difference" \
    'BEGIN { exit !(changed > 100000) }' ||
    die "moving backdrop did not update through the uncached blur"

send_background_command \
    reset 0 0 0 "$BACKGROUND_WIDTH" "$BACKGROUND_HEIGHT"
capture_output "$ARTIFACT_DIR/blur-before-localized.png"
send_background_command localized 2 360 240 160 120
capture_output "$ARTIFACT_DIR/blur-after-localized.png"
blurred_difference_stats=$(
    magick \
        "$ARTIFACT_DIR/blur-before-localized.png" \
        "$ARTIFACT_DIR/blur-after-localized.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h] %@' info:
)
read -r blurred_difference_pixels blurred_difference_bounds \
    <<<"$blurred_difference_stats"
[[ "$blurred_difference_bounds" =~ ^([0-9]+)x([0-9]+)[+]([0-9]+)[+]([0-9]+)$ ]] ||
    die "unable to locate the blurred localized update"
blurred_diff_width=${BASH_REMATCH[1]}
blurred_diff_height=${BASH_REMATCH[2]}
awk \
    -v changed="$blurred_difference_pixels" \
    -v width="$blurred_diff_width" \
    -v height="$blurred_diff_height" \
    'BEGIN {
        exit !(changed > 1000 &&
            width > 160 && width <= 240 &&
            height > 120 && height <= 200)
    }' ||
    die "localized backdrop update escaped its expanded damage region"

send_background_command stress "$STRESS_FRAMES" 360 240 160 120
capture_output "$ARTIFACT_DIR/after-buffer-reuse.png"

overlap_ready="$TEST_ROOT/blur-overlap.ready"
env -u LD_PRELOAD \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    WAYLAND_DISPLAY="$socket" \
    "$FIXTURE_BIN" blur "$overlap_ready" \
    >"$OVERLAP_LOG" 2>&1 &
OVERLAP_PID=$!
for _ in $(seq 1 240); do
    [ -f "$overlap_ready" ] && break
    kill -0 "$OVERLAP_PID" 2>/dev/null || {
        cat "$OVERLAP_LOG" >&2
        die "overlapping blur fixture exited before mapping"
    }
    sleep 0.05
done
[ -f "$overlap_ready" ] || die "overlapping blur fixture did not map"
capture_output "$ARTIFACT_DIR/blur-overlap.png"
overlap_difference=$(
    magick \
        "$ARTIFACT_DIR/after-buffer-reuse.png" \
        "$ARTIFACT_DIR/blur-overlap.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h]' info:
)
awk -v changed="$overlap_difference" \
    'BEGIN { exit !(changed > 1000) }' ||
    die "the overlapping blur window did not change the composited output"

capture_output "$ARTIFACT_DIR/workspace-animation-before.png"
send_key x
sleep 0.25
capture_output "$ARTIFACT_DIR/workspace-animation-outgoing.png"
workspace_outgoing_difference=$(
    magick \
        "$ARTIFACT_DIR/workspace-animation-before.png" \
        "$ARTIFACT_DIR/workspace-animation-outgoing.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h]' info:
)
awk -v changed="$workspace_outgoing_difference" \
    'BEGIN { exit !(changed > 1000) }' ||
    die "workspace animation did not move the outgoing rounded snapshots"
sleep 2.5
send_key y
sleep 0.25
capture_output "$ARTIFACT_DIR/workspace-animation-incoming.png"
workspace_incoming_pixels=$(nonblack_pixel_count \
    "$ARTIFACT_DIR/workspace-animation-incoming.png")
awk -v pixels="$workspace_incoming_pixels" \
    'BEGIN { exit !(pixels > 1000) }' ||
    die "workspace animation did not render incoming rounded snapshots"
sleep 2.5
capture_output "$ARTIFACT_DIR/workspace-animation-after.png"
workspace_roundtrip_difference=$(
    magick \
        "$ARTIFACT_DIR/workspace-animation-before.png" \
        "$ARTIFACT_DIR/workspace-animation-after.png" \
        -compose difference -composite \
        -alpha off -format '%[fx:mean]' info:
)
awk -v difference="$workspace_roundtrip_difference" \
    'BEGIN { exit !(difference <= 0.0002) }' ||
    die "workspace animation did not restore the composited effects"

capture_output "$ARTIFACT_DIR/before-output-resume.png"
set_output_enabled false
set_output_enabled true
capture_output "$ARTIFACT_DIR/after-output-resume.png"
resume_difference=$(
    magick \
        "$ARTIFACT_DIR/before-output-resume.png" \
        "$ARTIFACT_DIR/after-output-resume.png" \
        -compose difference -composite \
        -alpha off -format '%[fx:mean]' info:
)
awk -v difference="$resume_difference" \
    'BEGIN { exit !(difference <= 0.0002) }' ||
    die "output resume did not rebuild the composited effects"
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

rounded_counts=$(
    sed -n \
        's/.*destroyed Vulkan rounded effects after \([0-9][0-9]*\) texture and \([0-9][0-9]*\) rect draws (\([0-9][0-9]*\) normal, \([0-9][0-9]*\) swapchain, \([0-9][0-9]*\) explicit-sync).*/\1 \2 \3 \4 \5/p' \
        "$COMPOSITOR_LOG" |
        tail -1
)
[ -n "$rounded_counts" ] || {
    tail -120 "$COMPOSITOR_LOG" >&2
    die "rounded-effects teardown counts were not logged"
}
read -r texture_draws rect_draws normal_draws swapchain_draws explicit_sync_draws \
    <<<"$rounded_counts"
rounded_resource_counts=$(
    sed -n \
        's/.*Vulkan rounded resources created: \([0-9][0-9]*\) texture pipelines, \([0-9][0-9]*\) rect pipelines.*/\1 \2/p' \
        "$COMPOSITOR_LOG" |
        tail -1
)
[ -n "$rounded_resource_counts" ] || {
    tail -120 "$COMPOSITOR_LOG" >&2
    die "rounded resource-allocation counts were not logged"
}
read -r rounded_texture_pipelines rounded_rect_pipelines \
    <<<"$rounded_resource_counts"
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
blur_resource_counts=$(
    sed -n \
        's/.*Vulkan blur resources created: \([0-9][0-9]*\) scratch sets, \([0-9][0-9]*\) images, \([0-9][0-9]*\) descriptors, \([0-9][0-9]*\) cache images, \([0-9][0-9]*\) composite pipelines.*/\1 \2 \3 \4 \5/p' \
        "$COMPOSITOR_LOG" |
        tail -1
)
[ -n "$blur_resource_counts" ] || {
    tail -120 "$COMPOSITOR_LOG" >&2
    die "blur resource-allocation counts were not logged"
}
read -r blur_scratch_sets blur_image_allocations \
    blur_descriptor_allocations blur_cache_images \
    blur_composite_pipelines \
    <<<"$blur_resource_counts"
total_draws=$((texture_draws + rect_draws))
[ "$total_draws" -ge "$STRESS_FRAMES" ] ||
    die "rounded effects recorded fewer draws than the reuse stress"
[ "$texture_draws" -gt 0 ] ||
    die "the rounded-texture pipeline did not draw"
[ "$rect_draws" -gt 0 ] ||
    die "the rounded-rect pipeline did not draw"
[ "$rounded_texture_pipelines" -lt "$texture_draws" ] ||
    die "rounded texture pipelines were created once per draw"
[ "$rounded_rect_pipelines" -lt "$rect_draws" ] ||
    die "rounded rect pipelines were created once per draw"
[ "$normal_draws" -gt 0 ] ||
    die "ordinary Output.renderAndCommit did not invoke rounded effects"
[ "$swapchain_draws" -gt 0 ] ||
    die "OutputManager swapchain rendering did not invoke rounded effects"
[ "$blur_checkpoints" -ge "$STRESS_FRAMES" ] ||
    die "blur recorded fewer checkpoints than the reuse stress"
[ "$blur_composites" -eq "$blur_checkpoints" ] ||
    die "not every blur checkpoint produced a composite"
[ "$blur_scratch_sets" -lt "$blur_checkpoints" ] ||
    die "blur scratch resources were allocated once per checkpoint"
scratch_retirements=$(
    grep -c \
        'Vulkan blur scratch resource sets before render-target change' \
        "$COMPOSITOR_LOG" || true
)
[ "$scratch_retirements" -gt 0 ] ||
    die "output changes did not retire borrowed blur render targets"
[ "$blur_image_allocations" -eq \
    $((blur_scratch_sets * 2 + blur_cache_images)) ] ||
    die "blur image allocation accounting is inconsistent"
[ "$blur_descriptor_allocations" -eq \
    $((blur_scratch_sets * 3 + blur_cache_images)) ] ||
    die "blur descriptor allocation accounting is inconsistent"
[ "$blur_composite_pipelines" -lt "$blur_composites" ] ||
    die "blur composite pipelines were created once per draw"
if [ "$UNCACHED_ORACLE" = 1 ]; then
    [ "$blur_offscreen_draws" -eq $((blur_checkpoints * 17)) ] ||
        die "the uncached oracle did not rebuild every checkpoint"
    [ "$blur_cache_hits" -eq 0 ] &&
        [ "$blur_partial_rebuilds" -eq 0 ] &&
        [ "$blur_full_rebuilds" -eq 0 ] &&
        [ "$blur_pixels_processed" -eq 0 ] ||
        die "the uncached oracle unexpectedly used the cache"
else
    [ "$blur_offscreen_draws" -eq \
        $(((blur_partial_rebuilds + blur_full_rebuilds) * 17)) ] ||
        die "cache rebuilds did not execute one downsample and sixteen separable draws"
    [ "$blur_cache_hits" -gt 0 ] ||
        die "the blur cache did not record a reusable checkpoint"
    [ "$blur_partial_rebuilds" -gt 0 ] ||
        die "the blur cache did not record a partial rebuild"
    [ "$blur_full_rebuilds" -gt 0 ] ||
        die "the blur cache did not record a full rebuild"
    [ "$blur_pixels_processed" -gt 0 ] ||
        die "the blur cache did not account for processed pixels"
fi
if [ "$REQUIRE_EXPLICIT_SYNC" = 1 ] &&
    [ "$explicit_sync_draws" -ne "$total_draws" ]; then
    die "not every rounded-effects draw used wlroots' explicit-sync timeline"
fi
if grep -Eiq \
    'VUID-|validation error|Validation Error|validation layer.*error|UNASSIGNED-' \
    "$COMPOSITOR_LOG"; then
    tail -160 "$COMPOSITOR_LOG" >&2
    die "Vulkan validation reported an error"
fi
if grep -Eq 'Vulkan rounded (texture|rect) draw failed:' "$COMPOSITOR_LOG"; then
    tail -160 "$COMPOSITOR_LOG" >&2
    die "the Vulkan rounded-effects renderer reported a runtime failure"
fi
if grep -Eq 'Vulkan (cached blur processing|uncached blur processing|backdrop blur) failed:' \
    "$COMPOSITOR_LOG"; then
    tail -160 "$COMPOSITOR_LOG" >&2
    die "the Vulkan blur renderer reported a runtime failure"
fi

{
    printf 'wlroots_library=%s\n' "$wlroots_library"
    printf 'validation_layer=%s\n' "${validation_manifest:-not-installed}"
    printf 'stress_frames=%s\n' "$STRESS_FRAMES"
    printf 'total_draws=%s\n' "$total_draws"
    printf 'texture_draws=%s\n' "$texture_draws"
    printf 'rect_draws=%s\n' "$rect_draws"
    printf 'rounded_texture_pipelines=%s\n' \
        "$rounded_texture_pipelines"
    printf 'rounded_rect_pipelines=%s\n' "$rounded_rect_pipelines"
    printf 'normal_draws=%s\n' "$normal_draws"
    printf 'swapchain_draws=%s\n' "$swapchain_draws"
    printf 'explicit_sync_draws=%s\n' "$explicit_sync_draws"
    printf 'blur_checkpoints=%s\n' "$blur_checkpoints"
    printf 'blur_offscreen_draws=%s\n' "$blur_offscreen_draws"
    printf 'blur_composites=%s\n' "$blur_composites"
    printf 'blur_cache_hits=%s\n' "$blur_cache_hits"
    printf 'blur_partial_rebuilds=%s\n' "$blur_partial_rebuilds"
    printf 'blur_full_rebuilds=%s\n' "$blur_full_rebuilds"
    printf 'blur_pixels_processed=%s\n' "$blur_pixels_processed"
    printf 'blur_scratch_sets=%s\n' "$blur_scratch_sets"
    printf 'blur_scratch_retirements=%s\n' "$scratch_retirements"
    printf 'blur_image_allocations=%s\n' "$blur_image_allocations"
    printf 'blur_descriptor_allocations=%s\n' \
        "$blur_descriptor_allocations"
    printf 'blur_cache_images=%s\n' "$blur_cache_images"
    printf 'blur_composite_pipelines=%s\n' "$blur_composite_pipelines"
    printf 'blur_content_grid=%s\n' "$blur_grid"
    printf 'blur_content_adjacent=%s\n' "$blur_grid_adjacent"
    printf 'blur_content_frame=%s\n' "$blur_frame"
    printf 'blur_content_contrast=%s\n' "$blur_content_contrast"
    printf 'blur_cursor_residual_changed_pixels=%s\n' \
        "$cursor_damage_difference"
    printf 'blur_motion_changed_pixels=%s\n' "$motion_difference"
    printf 'blur_localized_changed_pixels=%s\n' "$blurred_difference_pixels"
    printf 'blur_localized_difference_bounds=%s\n' "$blurred_difference_bounds"
    printf 'blur_overlap_changed_pixels=%s\n' "$overlap_difference"
    printf 'workspace_outgoing_changed_pixels=%s\n' \
        "$workspace_outgoing_difference"
    printf 'workspace_incoming_nonblack_pixels=%s\n' \
        "$workspace_incoming_pixels"
    printf 'workspace_roundtrip_difference=%s\n' \
        "$workspace_roundtrip_difference"
    printf 'output_resume_difference=%s\n' "$resume_difference"
    printf 'auxiliary_surfaces=popup,subsurface\n'
    printf 'rounded_outer_corner_max=%s\n' "$outer_corner"
    printf 'rounded_antialias_corner_max=%s\n' "$antialias_corner"
    printf 'rounded_inset_content_max=%s\n' "$inset_content"
    printf 'rounded_straight_border_max=%s\n' "$straight_border"
    printf 'rounded_center_content_max=%s\n' "$center_content"
    printf 'localized_changed_pixels=%s\n' "$difference_pixels"
    printf 'localized_difference_bounds=%s\n' "$difference_bounds"
} >"$ARTIFACT_DIR/results.txt"
(
    cd "$ARTIFACT_DIR"
    find . -type f ! -name SHA256SUMS -print0 |
        sort -z |
        xargs -0 sha256sum >SHA256SUMS
)

echo "PASS: rounded Vulkan effects and blur survived both render paths, popup and subsurface content, cursor-only damage, scene damage, motion, overlap, workspace animation, output resume, four scales, rotations, capture, and $STRESS_FRAMES reused-buffer frames"
