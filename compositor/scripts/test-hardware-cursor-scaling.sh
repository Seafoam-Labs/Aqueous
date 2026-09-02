#!/usr/bin/env bash
set -euo pipefail

# Qualifies the cursor buffer handed to a real DRM hardware cursor plane.
# This intentionally targets an already-running Aqueous session: headless and
# nested backends do not have a DRM cursor plane, and screen capture forces a
# software cursor. The original output scale is restored on exit.

OUTPUT_NAME=${AQUEOUS_HARDWARE_CURSOR_OUTPUT:-}
RUNTIME=${XDG_RUNTIME_DIR:-}

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ -z "$OUTPUT_NAME" ]; then
    echo "SKIP: set AQUEOUS_HARDWARE_CURSOR_OUTPUT to the real DRM output currently under the pointer"
    exit 0
fi
[ -n "$RUNTIME" ] || die "XDG_RUNTIME_DIR is not set"
for tool in jq nc; do have "$tool" || die "$tool is required"; done

OUTPUT_SOCKET="$RUNTIME/aqueous/outputd.sock"
[ -S "$OUTPUT_SOCKET" ] || die "no running Aqueous output service at $OUTPUT_SOCKET"
output_request() { printf '%s\n' "$1" | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1; }

initial=$(output_request '{"op":"list"}')
original_scale=$(jq -r --arg name "$OUTPUT_NAME" \
    '.outputs[] | select(.name == $name) | .scale' <<<"$initial")
[ -n "$original_scale" ] && [ "$original_scale" != null ] || \
    die "output '$OUTPUT_NAME' is not active"
restored=0
restore_scale() {
    [ "$restored" = 1 ] && return
    output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"scale\":$original_scale}]}" >/dev/null || true
    restored=1
}
trap restore_scale EXIT

state=$(output_request '{"op":"cursor_state"}')
jq -e '.ok == true and (.outputs | type == "array")' >/dev/null <<<"$state" || \
    die "running compositor lacks the cursor_state test interface; rebuild and restart Aqueous"

assert_hardware_extent() {
    local scale=$1 expected=$2 response current
    response=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"scale\":$scale}]}")
    jq -e '.ok == true' >/dev/null <<<"$response" || \
        die "unable to set '$OUTPUT_NAME' to ${scale}x: $response"
    for _ in $(seq 1 100); do
        current=$(output_request '{"op":"cursor_state"}')
        if jq -e --arg name "$OUTPUT_NAME" --argjson scale "$scale" \
            --argjson expected "$expected" '
                any(.outputs[];
                    .name == $name and .scale == $scale and
                    .hardware_active == true and .software_cursor_locks == 0 and
                    .width == $expected and .height == $expected)
            ' >/dev/null <<<"$current"; then
            pass "DRM hardware cursor buffer is ${expected}x${expected} at ${scale}x"
            return
        fi
        sleep 0.05
    done
    jq -c --arg name "$OUTPUT_NAME" '.outputs[] | select(.name == $name)' <<<"$current" >&2
    die "hardware cursor on '$OUTPUT_NAME' did not settle at ${expected}x${expected}; keep the pointer on that output and ensure capture is inactive"
}

assert_hardware_extent 1 24
assert_hardware_extent 1.25 30
assert_hardware_extent 1.5 36
assert_hardware_extent 2 48
assert_hardware_extent 2.5 60
assert_hardware_extent 3 72
restore_scale
trap - EXIT
echo "ALL DRM HARDWARE CURSOR SCALING CHECKS PASSED (restored scale $original_scale)"
