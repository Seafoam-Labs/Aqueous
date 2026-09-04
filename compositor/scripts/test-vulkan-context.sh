#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
TEST_POLICY=${AQUEOUS_TEST_POLICY:-internal}
EXIT_FIXTURE_SOURCE="$here/scripts/fixtures/exit-session.c"
WINDOW_MANAGEMENT_PROTOCOL="$here/protocol/river-window-management-v1.xml"
WORKSPACE_PROTOCOL="$here/protocol/upstream/ext-workspace-v1.xml"

die() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] ||
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[[ "$TEST_POLICY" = internal || "$TEST_POLICY" = compare ]] ||
    die "AQUEOUS_TEST_POLICY must be internal or compare"
for tool in cc grim jq nc pkg-config readelf wayland-scanner; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
pkg-config --exists wayland-client ||
    die "Wayland client development files are required"
readelf -d "$AQUEOUS_COMPOSITOR_BIN" | grep -q 'libvulkan.so' ||
    die "the compositor is not linked directly to Vulkan"
if readelf -d "$AQUEOUS_COMPOSITOR_BIN" | grep -q 'libscenefx'; then
    die "the Vulkan-effects compositor must not be linked to SceneFX"
fi

HOST_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}
HOST_WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
[ -n "$HOST_RUNTIME_DIR" ] && [ -n "$HOST_WAYLAND_DISPLAY" ] ||
    die "a parent Wayland display is required"
[ -S "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ] ||
    die "the parent Wayland socket is unavailable"

TEST_ROOT=$(mktemp -d /tmp/aqueous-vulkan-context.XXXXXX)
RUNTIME_DIR="$TEST_ROOT/runtime"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
CAPTURE="$TEST_ROOT/modeset.png"
EXIT_FIXTURE="$TEST_ROOT/exit-session"
COMPOSITOR_PID=""

cleanup() {
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$RUNTIME_DIR/config" "$RUNTIME_DIR/home"
chmod 700 "$RUNTIME_DIR"
ln -s "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" "$RUNTIME_DIR/aqueous-vulkan-host"

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

VALIDATION_ENV=()
if find /usr/share/vulkan /etc/vulkan -type f \
    -name 'VkLayer_khronos_validation.json' -print -quit 2>/dev/null |
    grep -q .; then
    VALIDATION_ENV=(VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation)
fi

env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
    "${VALIDATION_ENV[@]}" \
    WLR_BACKENDS=wayland \
    WLR_WL_OUTPUTS=1 \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_CONFIG_HOME="$RUNTIME_DIR/config" \
    HOME="$RUNTIME_DIR/home" \
    WAYLAND_DISPLAY=aqueous-vulkan-host \
    "$AQUEOUS_COMPOSITOR_BIN" \
        -no-xwayland -policy "$TEST_POLICY" -log-level info -c true \
        >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -120 "$COMPOSITOR_LOG" >&2
        die "compositor failed during Vulkan startup"
    }
    socket=$(find "$RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"

OUTPUT_SOCKET="$RUNTIME_DIR/aqueous/outputd.sock"
for _ in $(seq 1 200); do
    [ -S "$OUTPUT_SOCKET" ] && break
    sleep 0.05
done
[ -S "$OUTPUT_SOCKET" ] || {
    tail -120 "$COMPOSITOR_LOG" >&2
    die "output service did not create its socket"
}

output_request() {
    printf '%s\n' "$1" | nc -U -N -w 3 "$OUTPUT_SOCKET" 2>/dev/null | head -1
}

output_state=$(output_request '{"op":"list"}')
OUTPUT_NAME=$(jq -r '.outputs[0].name // empty' <<<"$output_state")
[ -n "$OUTPUT_NAME" ] || die "nested output was not reported"
jq -e \
    '.outputs[0] |
     .hdr == false and
     .hdr_capable == false and
     .hdr_active == false and
     (.render_format | type == "string") and
     (.supported_primaries | type == "array") and
     (.supported_transfer_functions | type == "array")' \
    >/dev/null <<<"$output_state" ||
    die "output service did not report the expected HDR capability fields"

hdr_response=$(output_request \
    "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"hdr\":true}]}")
jq -e \
    '.ok == false and
     .applied == 0 and
     .rejected == 1 and
     .outputs[0].hdr == false' \
    >/dev/null <<<"$hdr_response" ||
    die "non-DRM output did not reject HDR as unsupported: $hdr_response"

mode_response=$(output_request \
    "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"mode\":\"1920x1080\"}]}")
jq -e '.ok == true' >/dev/null <<<"$mode_response" ||
    die "output service rejected the Vulkan modeset: $mode_response"

for _ in $(seq 1 200); do
    output_state=$(output_request '{"op":"list"}')
    if jq -e \
        '.outputs[0].current_mode.width == 1920 and
         .outputs[0].current_mode.height == 1080' \
        >/dev/null <<<"$output_state"; then
        break
    fi
    sleep 0.05
done
jq -e \
    '.outputs[0].current_mode.width == 1920 and
     .outputs[0].current_mode.height == 1080' \
    >/dev/null <<<"$output_state" || die "Vulkan output did not settle after modeset"

env -u LD_PRELOAD \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    WAYLAND_DISPLAY="$socket" \
    grim -o "$OUTPUT_NAME" "$CAPTURE"
[ -s "$CAPTURE" ] || die "Vulkan output capture is empty"

if [ "$TEST_POLICY" = compare ]; then
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        "$EXIT_FIXTURE"
else
    kill -TERM "$COMPOSITOR_PID"
fi
shutdown_status=0
wait "$COMPOSITOR_PID" || shutdown_status=$?
COMPOSITOR_PID=""
[ "$shutdown_status" -eq 0 ] ||
    die "compositor exited with status $shutdown_status"

grep -q 'Vulkan effects context:' "$COMPOSITOR_LOG" ||
    die "Vulkan context creation was not logged"
if ! grep -q 'destroyed Vulkan effects context' "$COMPOSITOR_LOG"; then
    tail -120 "$COMPOSITOR_LOG" >&2
    die "Vulkan context destruction was not logged"
fi
if grep -Eiq 'validation error|validation layer.*error|VUID-' "$COMPOSITOR_LOG"; then
    tail -120 "$COMPOSITOR_LOG" >&2
    die "Vulkan validation reported an error"
fi

echo "PASS: Vulkan effects context survived a modeset and clean shutdown"
