#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$#" -le 1 ] || die "usage: $0 [OUTPUT_DIRECTORY]"
[ -x "$AQUEOUS_COMPOSITOR_BIN" ] ||
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] ||
    die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for tool in grim gtk4-layer-demo magick readelf swaylock; do
    have "$tool" || die "$tool is required"
done
readelf -d "$AQUEOUS_COMPOSITOR_BIN" | grep 'libvulkan.so' >/dev/null ||
    die "the compositor is not linked directly to Vulkan"

test_root=$(mktemp -d /tmp/aqueous-vulkan-shell-paths.XXXXXX)
runtime="$test_root/runtime"
test_home="$test_root/home"
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
compositor_pid=""
layer_pid=""
lock_pid=""

cleanup() {
    [ -z "$lock_pid" ] || kill "$lock_pid" 2>/dev/null || true
    [ -z "$lock_pid" ] || wait "$lock_pid" 2>/dev/null || true
    [ -z "$layer_pid" ] || kill "$layer_pid" 2>/dev/null || true
    [ -z "$layer_pid" ] || wait "$layer_pid" 2>/dev/null || true
    [ -z "$compositor_pid" ] || kill "$compositor_pid" 2>/dev/null || true
    [ -z "$compositor_pid" ] || wait "$compositor_pid" 2>/dev/null || true
    rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$runtime/config" "$test_home" "$artifacts"
chmod 700 "$runtime"
env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    XDG_RUNTIME_DIR="$runtime" \
    XDG_CONFIG_HOME="$runtime/config" \
    HOME="$test_home" \
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
    gtk4-layer-demo -l background -a lrtb -k none \
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
    printf 'layer_changed_pixels=%s\n' "$layer_difference"
    printf 'session_lock_presented=true\n'
} >"$artifacts/results.txt"

echo "PASS: layer-shell capture and session-lock presentation use the Vulkan output path"
echo "artifacts: $artifacts"
