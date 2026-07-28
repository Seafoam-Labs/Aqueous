#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
WM_CONFIG="$here/scripts/fixtures/visual-effects-wm.toml"
RULES_CONFIG="$here/scripts/fixtures/layer-blur-rules.toml"
POPUP_FIXTURE_SOURCE="$here/scripts/fixtures/layer-popup-reference.c"
LAYER_SHELL_PROTOCOL="$here/protocol/upstream/wlr-layer-shell-unstable-v1.xml"
TEST_LAYER=${AQUEOUS_TEST_LAYER:-background}

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$#" -le 1 ] || die "usage: $0 [OUTPUT_DIRECTORY]"
[ -x "$AQUEOUS_COMPOSITOR_BIN" ] ||
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] ||
    die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for tool in cc grim gtk4-layer-demo magick pkg-config readelf swaylock \
    wayland-scanner; do
    have "$tool" || die "$tool is required"
done
pkg-config --exists wayland-client wayland-protocols ||
    die "Wayland client and protocol development files are required"
readelf -d "$AQUEOUS_COMPOSITOR_BIN" | grep 'libvulkan.so' >/dev/null ||
    die "the compositor is not linked directly to Vulkan"

test_root=$(mktemp -d /tmp/aqueous-vulkan-shell-paths.XXXXXX)
runtime="$test_root/runtime"
test_home="$test_root/home"
runtime_rules="$runtime/layer-blur-rules.toml"
if [ "$#" -eq 1 ]; then
    artifacts=$(readlink -m "$1")
    mkdir -p "$artifacts"
    [ -z "$(find "$artifacts" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        die "output directory is not empty: $artifacts"
else
    artifacts="$test_root/artifacts"
fi
compositor_log="$artifacts/compositor.log"
layer_log="$artifacts/layer.log"
lock_log="$artifacts/lock.log"
popup_log="$artifacts/layer-popup.log"
popup_ready="$test_root/layer-popup.ready"
popup_fixture="$test_root/layer-popup-reference"
compositor_pid=""
layer_pid=""
popup_pid=""
lock_pid=""

cleanup() {
    [ -z "$lock_pid" ] || kill "$lock_pid" 2>/dev/null || true
    [ -z "$lock_pid" ] || wait "$lock_pid" 2>/dev/null || true
    [ -z "$popup_pid" ] || kill "$popup_pid" 2>/dev/null || true
    [ -z "$popup_pid" ] || wait "$popup_pid" 2>/dev/null || true
    [ -z "$layer_pid" ] || kill "$layer_pid" 2>/dev/null || true
    [ -z "$layer_pid" ] || wait "$layer_pid" 2>/dev/null || true
    [ -z "$compositor_pid" ] || kill "$compositor_pid" 2>/dev/null || true
    [ -z "$compositor_pid" ] || wait "$compositor_pid" 2>/dev/null || true
    rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$runtime/config" "$test_home" "$artifacts"
chmod 700 "$runtime"
cp "$RULES_CONFIG" "$runtime_rules"
xdg_shell_protocol="$(
    pkg-config --variable=pkgdatadir wayland-protocols
)/stable/xdg-shell/xdg-shell.xml"
wayland-scanner client-header "$xdg_shell_protocol" \
    "$test_root/xdg-shell-client-protocol.h"
wayland-scanner private-code "$xdg_shell_protocol" \
    "$test_root/xdg-shell-protocol.c"
wayland-scanner client-header "$LAYER_SHELL_PROTOCOL" \
    "$test_root/wlr-layer-shell-unstable-v1-client-protocol.h"
wayland-scanner private-code "$LAYER_SHELL_PROTOCOL" \
    "$test_root/wlr-layer-shell-unstable-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$test_root" \
    "$POPUP_FIXTURE_SOURCE" \
    "$test_root/xdg-shell-protocol.c" \
    "$test_root/wlr-layer-shell-unstable-v1-protocol.c" \
    -o "$popup_fixture" \
    $(pkg-config --cflags --libs wayland-client)
env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    XDG_RUNTIME_DIR="$runtime" \
    XDG_CONFIG_HOME="$runtime/config" \
    HOME="$test_home" \
    AQUEOUS_CONFIG="$WM_CONFIG" \
    AQUEOUS_RULES="$runtime_rules" \
    "$AQUEOUS_COMPOSITOR_BIN" \
        -no-xwayland -policy internal -log-level debug -c true \
        >"$compositor_log" 2>&1 &
compositor_pid=$!

socket=""
for _ in $(seq 1 240); do
    kill -0 "$compositor_pid" 2>/dev/null || {
        tail -120 "$compositor_log" >&2
        die "compositor failed during startup"
    }
    socket=$(find "$runtime" -maxdepth 1 -type s \
        -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"

output_name=$(
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$runtime" \
        WAYLAND_DISPLAY="$socket" \
        "$AQUEOUSCTL_BIN" outputs |
        awk 'NR == 1 { print $1 }'
)
[ -n "$output_name" ] || die "unable to resolve the headless output"

capture() {
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$runtime" \
        WAYLAND_DISPLAY="$socket" \
        grim -o "$output_name" "$1"
    [ -s "$1" ] || die "empty capture: $1"
}

capture "$artifacts/before-layer.png"
env -u LD_PRELOAD \
    XDG_RUNTIME_DIR="$runtime" \
    WAYLAND_DISPLAY="$socket" \
    gtk4-layer-demo -l "$TEST_LAYER" -a lrtb -k none \
    >"$layer_log" 2>&1 &
layer_pid=$!
for _ in $(seq 1 240); do
    kill -0 "$layer_pid" 2>/dev/null ||
        die "layer-shell client exited before mapping"
    grep -q "layer surface.*mapped" "$compositor_log" && break
    sleep 0.05
done
grep -q "layer surface.*mapped" "$compositor_log" ||
    die "layer-shell surface did not map"
scene_snapshot=$(
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$runtime" \
        WAYLAND_DISPLAY="$socket" \
        "$AQUEOUSCTL_BIN" scene
)
grep -Fq 'layer surface: demo' <<<"$scene_snapshot" ||
    die "scene inspection did not expose the layer namespace"
blur_marker=$(
    grep -F 'layer backdrop blur marker [rect]' <<<"$scene_snapshot" |
        head -1
)
[ -n "$blur_marker" ] ||
    die "matched layer surface has no backdrop blur marker"
grep -Fq ' disabled' <<<"$blur_marker" &&
    die "matched layer surface backdrop blur marker is disabled"

sed -i 's/blur = true/blur = false/' "$runtime_rules"
for _ in $(seq 1 30); do
    sleep 0.1
    scene_snapshot=$(
        env -u LD_PRELOAD \
            XDG_RUNTIME_DIR="$runtime" \
            WAYLAND_DISPLAY="$socket" \
            "$AQUEOUSCTL_BIN" scene
    )
    blur_marker=$(
        grep -F 'layer backdrop blur marker [rect]' <<<"$scene_snapshot" |
            head -1
    )
    grep -Fq ' disabled' <<<"$blur_marker" && break
done
grep -Fq ' disabled' <<<"$blur_marker" ||
    die "layer blur rule removal did not hot-reload"

sed -i 's/blur = false/blur = true/' "$runtime_rules"
for _ in $(seq 1 30); do
    sleep 0.1
    scene_snapshot=$(
        env -u LD_PRELOAD \
            XDG_RUNTIME_DIR="$runtime" \
            WAYLAND_DISPLAY="$socket" \
            "$AQUEOUSCTL_BIN" scene
    )
    blur_marker=$(
        grep -F 'layer backdrop blur marker [rect]' <<<"$scene_snapshot" |
            head -1
    )
    if ! grep -Fq ' disabled' <<<"$blur_marker"; then break; fi
done
grep -Fq ' disabled' <<<"$blur_marker" &&
    die "layer blur rule addition did not hot-reload"

capture "$artifacts/layer-shell.png"
layer_difference=$(
    magick \
        "$artifacts/before-layer.png" \
        "$artifacts/layer-shell.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h]' info:
)
awk -v changed="$layer_difference" \
    'BEGIN { exit !(changed > 1000) }' ||
    die "output capture did not include the layer-shell surface"

env -u LD_PRELOAD \
    XDG_RUNTIME_DIR="$runtime" \
    WAYLAND_DISPLAY="$socket" \
    "$popup_fixture" "$popup_ready" \
    >"$popup_log" 2>&1 &
popup_pid=$!
for _ in $(seq 1 240); do
    kill -0 "$popup_pid" 2>/dev/null ||
        die "layer-popup fixture exited before mapping"
    [ -s "$popup_ready" ] && break
    sleep 0.05
done
[ -s "$popup_ready" ] || die "layer-popup fixture did not become ready"

scene_snapshot=$(
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$runtime" \
        WAYLAND_DISPLAY="$socket" \
        "$AQUEOUSCTL_BIN" scene
)
grep -Fq 'layer surface: aqueous-popup-test' <<<"$scene_snapshot" ||
    die "layer-popup fixture namespace is absent from scene inspection"
popup_marker_count=$(
    grep -Fc 'layer popup backdrop blur marker [rect]' <<<"$scene_snapshot"
)
[ "$popup_marker_count" -eq 2 ] ||
    die "expected two recursive layer-popup blur markers, found $popup_marker_count"
popup_enabled_count=$(
    grep -F 'layer popup backdrop blur marker [rect]' <<<"$scene_snapshot" |
        grep -Fvc ' disabled'
)
[ "$popup_enabled_count" -eq 2 ] ||
    die "recursive layer-popup blur markers are not enabled"

sed -i 's/blur_popups = true/blur_popups = false/' "$runtime_rules"
for _ in $(seq 1 30); do
    sleep 0.1
    scene_snapshot=$(
        env -u LD_PRELOAD \
            XDG_RUNTIME_DIR="$runtime" \
            WAYLAND_DISPLAY="$socket" \
            "$AQUEOUSCTL_BIN" scene
    )
    popup_disabled_count=$(
        awk '
            /layer popup backdrop blur marker \[rect\]/ &&
                / disabled/ { count++ }
            END { print count + 0 }
        ' <<<"$scene_snapshot"
    )
    [ "$popup_disabled_count" -eq 2 ] && break
done
[ "$popup_disabled_count" -eq 2 ] ||
    die "layer-popup blur rule removal did not hot-reload"
capture "$artifacts/layer-popup-blur-disabled.png"

sed -i 's/blur_popups = false/blur_popups = true/' "$runtime_rules"
for _ in $(seq 1 30); do
    sleep 0.1
    scene_snapshot=$(
        env -u LD_PRELOAD \
            XDG_RUNTIME_DIR="$runtime" \
            WAYLAND_DISPLAY="$socket" \
            "$AQUEOUSCTL_BIN" scene
    )
    popup_enabled_count=$(
        awk '
            /layer popup backdrop blur marker \[rect\]/ &&
                !/ disabled/ { count++ }
            END { print count + 0 }
        ' <<<"$scene_snapshot"
    )
    [ "$popup_enabled_count" -eq 2 ] && break
done
[ "$popup_enabled_count" -eq 2 ] ||
    die "layer-popup blur rule addition did not hot-reload"

capture "$artifacts/layer-popup.png"
popup_blur_difference=$(
    magick \
        "$artifacts/layer-popup-blur-disabled.png" \
        "$artifacts/layer-popup.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h]' info:
)
awk -v changed="$popup_blur_difference" \
    'BEGIN { exit !(changed > 100) }' ||
    die "enabling popup blur did not visibly change the captured popup bounds"
popup_difference=$(
    magick \
        "$artifacts/layer-shell.png" \
        "$artifacts/layer-popup.png" \
        -compose difference -composite \
        -alpha off -colorspace gray -threshold 0 \
        -format '%[fx:mean*w*h]' info:
)
awk -v changed="$popup_difference" \
    'BEGIN { exit !(changed > 1000) }' ||
    die "output capture did not include the layer popup fixture"
kill "$popup_pid" 2>/dev/null || true
wait "$popup_pid" 2>/dev/null || true
popup_pid=""

kill "$layer_pid" 2>/dev/null || true
wait "$layer_pid" 2>/dev/null || true
layer_pid=""

env -u LD_PRELOAD \
    XDG_RUNTIME_DIR="$runtime" \
    WAYLAND_DISPLAY="$socket" \
    swaylock -c 224466 -u --grace 30 \
    >"$lock_log" 2>&1 &
lock_pid=$!
for _ in $(seq 1 240); do
    kill -0 "$lock_pid" 2>/dev/null ||
        die "session-lock client exited before presentation"
    grep -q "session locked" "$compositor_log" && break
    sleep 0.05
done
grep -q "session locked" "$compositor_log" ||
    die "session-lock surface was not presented"

if grep -Eq 'Vulkan rounded (texture|rect) draw failed:|Vulkan .*blur.*failed:' \
    "$compositor_log"; then
    tail -160 "$compositor_log" >&2
    die "a Vulkan effects path reported a runtime failure"
fi

{
    printf 'output=%s\n' "$output_name"
    printf 'layer=%s\n' "$TEST_LAYER"
    printf 'layer_changed_pixels=%s\n' "$layer_difference"
    printf 'layer_blur_marker_enabled=true\n'
    printf 'layer_blur_hot_reload=true\n'
    printf 'layer_popup_changed_pixels=%s\n' "$popup_difference"
    printf 'layer_popup_blur_changed_pixels=%s\n' "$popup_blur_difference"
    printf 'layer_popup_markers=%s\n' "$popup_marker_count"
    printf 'layer_popup_nested=true\n'
    printf 'layer_popup_blur_hot_reload=true\n'
    printf 'session_lock_presented=true\n'
} >"$artifacts/results.txt"

echo "PASS: layer-shell and recursive popup blur use the Vulkan output path"
echo "artifacts: $artifacts"
