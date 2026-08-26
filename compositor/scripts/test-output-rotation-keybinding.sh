#!/usr/bin/env bash
set -euo pipefail

# The rotation binding targets the exact enabled output beneath the pointer
# and cycles clockwise through all quarter turns.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
WM_CONFIG="$here/scripts/fixtures/output-rotation-wm.toml"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -r "$WM_CONFIG" ] || die "missing fixture config $WM_CONFIG"
for tool in jq nc wlrctl; do
    have "$tool" || die "$tool is required for output-rotation integration tests"
done

TEST_ROOT=$(mktemp -d /tmp/aqueous-output-rotation.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""

cleanup() {
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"
WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=2 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$WM_CONFIG" \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -policy internal -log-level debug -c true \
    >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -120 "$COMPOSITOR_LOG" >&2
        die "compositor failed during startup"
    }
    socket=$(find "$RUNTIME" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -n "$socket" ] && break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"
export XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$socket"

OUTPUT_SOCKET="$RUNTIME/aqueous/outputd.sock"
output_request() {
    printf '%s\n' "$1" | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1
}

outputs=""
for _ in $(seq 1 160); do
    [ -S "$OUTPUT_SOCKET" ] || { sleep 0.05; continue; }
    outputs=$(output_request '{"op":"list"}' || true)
    [ "$(jq '.outputs | length' <<<"$outputs" 2>/dev/null || echo 0)" -eq 2 ] && break
    sleep 0.05
done
[ "$(jq '.outputs | length' <<<"$outputs")" -eq 2 ] || die "output service did not report two outputs"

SOURCE=$(jq -r '.outputs | sort_by(.name) | .[0].name' <<<"$outputs")
DEST=$(jq -r '.outputs | sort_by(.name) | .[1].name' <<<"$outputs")
SOURCE_WIDTH=$(jq -r --arg name "$SOURCE" \
    '.outputs[] | select(.name == $name) | (.current_mode.width / .scale | floor)' <<<"$outputs")
DEST_X=$((SOURCE_WIDTH + 300))

configure=$(jq -cn \
    --arg source "$SOURCE" \
    --arg dest "$DEST" \
    --argjson dest_x "$DEST_X" \
    '{
        op: "set",
        changes: [
            {name: $source, enabled: true, scale: 1, transform: "normal", position: [0, 0]},
            {name: $dest, enabled: true, scale: 1, transform: "normal", position: [$dest_x, 0]}
        ]
    }')
configured=$(output_request "$configure")
jq -e '.ok == true and .applied == 2' <<<"$configured" >/dev/null ||
    die "two-output setup was rejected: $configured"

wait_transform() {
    local name=$1 expected=$2 state=""
    for _ in $(seq 1 160); do
        state=$(output_request '{"op":"list"}' || true)
        [ "$(jq -r --arg name "$name" '.outputs[] | select(.name == $name) | .transform' <<<"$state")" = "$expected" ] && return 0
        sleep 0.05
    done
    die "timed out waiting for $name transform=$expected"
}

wait_transform "$SOURCE" normal
wait_transform "$DEST" normal
outputs=$(output_request '{"op":"list"}')
DEST_BASELINE=$(jq -c --arg name "$DEST" \
    '.outputs[] | select(.name == $name) | {enabled, current_mode, position, scale, adaptive_sync, hdr}' <<<"$outputs")

move_pointer() {
    wlrctl pointer move -10000 -10000
    wlrctl pointer move "$1" "$2"
}

rotate_key() {
    wlrctl keyboard type r modifiers SUPER,CTRL
}

# Keep the pointer on DEST while repeated presses prove the complete cycle and
# that SOURCE is never selected through focus or declaration order.
move_pointer $((DEST_X + 100)) 100
for transform in 90 180 270 normal; do
    rotate_key
    wait_transform "$DEST" "$transform"
    outputs=$(output_request '{"op":"list"}')
    [ "$(jq -r --arg name "$SOURCE" '.outputs[] | select(.name == $name) | .transform' <<<"$outputs")" = normal ] ||
        die "rotation changed the output not beneath the pointer"
done

DEST_FINAL=$(jq -c --arg name "$DEST" \
    '.outputs[] | select(.name == $name) | {enabled, current_mode, position, scale, adaptive_sync, hdr}' <<<"$outputs")
[ "$DEST_FINAL" = "$DEST_BASELINE" ] || die "rotation changed unrelated output state"

echo "PASS: pointer output rotation targets one head and cycles by 90 degrees"
