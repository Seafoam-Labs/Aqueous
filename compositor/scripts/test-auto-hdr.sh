#!/usr/bin/env bash
set -euo pipefail

# Headless integration smoke test for the Auto HDR output settings.
#
# The wlroots headless backend is not DRM, so HDR can never activate here;
# this script verifies the wire contract of the Auto HDR configuration
# surface instead: field presence, acceptance, state reflection, range
# validation, and persistence. The GPU-side expansion curve is covered by
# the aqueous/auto_hdr.zig unit tests; visual verification requires a DRM
# output and is tracked in the HDR test matrix.
#
# Requirements: a built ./zig-out/bin/aqueous, plus nc and jq.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}

fail=0
pass() { echo "PASS: $*"; }
err()  { echo "FAIL: $*"; fail=1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || { echo "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN (build with: zig build -Dxwayland)"; exit 2; }
have nc || { echo "nc with Unix-socket support is required"; exit 2; }
have jq || { echo "jq is required"; exit 2; }

TEST_ROOT=$(mktemp -d /tmp/aqueous-auto-hdr.XXXXXX)
COMPOSITOR_PID=""
cleanup() {
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

runtime="$TEST_ROOT/runtime"
mkdir -p "$runtime/config" "$runtime/home" "$runtime/outputs"
chmod 700 "$runtime"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
XDG_RUNTIME_DIR="$runtime" \
XDG_CONFIG_HOME="$runtime/config" \
HOME="$runtime/home" \
AQUEOUS_OUTPUTS="$runtime/outputs/outputs.toml" \
    "$AQUEOUS_COMPOSITOR_BIN" -policy internal -no-xwayland -log-level debug \
    >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

n=0
OUTPUT_SOCKET="$runtime/aqueous/outputd.sock"
while [ "$n" -lt 100 ]; do
    if ! kill -0 "$COMPOSITOR_PID" 2>/dev/null; then
        tail -30 "$COMPOSITOR_LOG" >&2
        err "aqueous exited during startup"
        exit 1
    fi
    [ -S "$OUTPUT_SOCKET" ] && break
    sleep 0.1
    n=$((n + 1))
done
[ -S "$OUTPUT_SOCKET" ] || { tail -30 "$COMPOSITOR_LOG" >&2; err "output service socket never appeared"; exit 1; }

output_request() { printf '%s\n' "$1" | nc -U -q 1 "$OUTPUT_SOCKET" 2>/dev/null | head -1; }

NAME=""
n=0
while [ "$n" -lt 100 ]; do
    NAME=$(output_request '{"op":"list"}' | jq -r '.outputs[0].name' 2>/dev/null || true)
    [ -n "$NAME" ] && [ "$NAME" != "null" ] && break
    NAME=""
    sleep 0.2
    n=$((n + 1))
done
[ -n "$NAME" ] || { tail -30 "$COMPOSITOR_LOG" >&2; err "no output reported by the output service"; exit 1; }
echo "using output: $NAME"

# Field presence and headless capability reporting.
list=$(output_request '{"op":"list"}')
echo "$list" | jq -e '.outputs[0] | has("auto_hdr") and has("auto_hdr_boost") and has("auto_hdr_capable")' >/dev/null \
    && pass "list reports the auto HDR fields" \
    || err "list is missing auto HDR fields"
echo "$list" | jq -e '.outputs[0] | .auto_hdr == false and .auto_hdr_capable == false' >/dev/null \
    && pass "headless output reports auto HDR off and incapable" \
    || err "headless auto HDR defaults are wrong"

# Acceptance and state reflection.
set_ok=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$NAME\",\"auto_hdr\":true,\"auto_hdr_boost\":0.7}]}")
echo "$set_ok" | jq -e '.ok == true and .applied == 1' >/dev/null \
    && pass "set accepts auto_hdr and auto_hdr_boost" \
    || err "set rejected valid auto HDR settings: $set_ok"
list=$(output_request '{"op":"list"}')
echo "$list" | jq -e '.outputs[0] | .auto_hdr == true and .auto_hdr_boost == 0.7' >/dev/null \
    && pass "list reflects the applied auto HDR state" \
    || err "list does not reflect the applied auto HDR state"

# Range validation.
bad_boost=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$NAME\",\"auto_hdr_boost\":1.5}]}")
echo "$bad_boost" | jq -e '.ok == false' >/dev/null \
    && pass "out-of-range auto_hdr_boost is rejected" \
    || err "out-of-range auto_hdr_boost was accepted"

# HDR level plumbing (level state is staged even without an HDR-capable
# output; enabling HDR itself must still be rejected on headless).
level_auto=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$NAME\",\"hdr_level\":\"auto\"}]}")
echo "$level_auto" | jq -e '.ok == true' >/dev/null \
    && pass "hdr_level accepts \"auto\"" \
    || err "hdr_level rejected \"auto\": $level_auto"
level_400=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$NAME\",\"hdr_level\":400}]}")
echo "$level_400" | jq -e '.ok == true' >/dev/null \
    && pass "hdr_level accepts numeric presets" \
    || err "hdr_level rejected 400: $level_400"
list=$(output_request '{"op":"list"}')
echo "$list" | jq -e '.outputs[0].hdr_level == 400' >/dev/null \
    && pass "list reflects the resolved HDR level" \
    || err "list does not reflect the HDR level"
bad_level=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$NAME\",\"hdr_level\":600}]}")
echo "$bad_level" | jq -e '.ok == false' >/dev/null \
    && pass "unsupported hdr_level is rejected" \
    || err "unsupported hdr_level was accepted"
hdr_on=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$NAME\",\"hdr\":true}]}")
echo "$hdr_on" | jq -e '.ok == false and (.rejections[0].error | contains("HDR10"))' >/dev/null \
    && pass "HDR enable is still rejected on non-DRM outputs" \
    || err "HDR enable rejection changed: $hdr_on"

# Persistence through save_profile.
save=$(output_request "{\"op\":\"save_profile\",\"name\":\"auto-hdr-smoke\",\"outputs\":[{\"name\":\"$NAME\",\"auto_hdr\":true,\"auto_hdr_boost\":0.3,\"hdr_level\":\"auto\"}]}")
echo "$save" | jq -e '.ok == true' >/dev/null \
    || err "save_profile failed: $save"
profile_path="$runtime/outputs/outputs.toml"
grep -q 'auto_hdr = true' "$profile_path" \
    && grep -q 'auto_hdr_boost = 0.3' "$profile_path" \
    && grep -q 'hdr_level = "auto"' "$profile_path" \
    && pass "save_profile persists the auto HDR settings" \
    || err "persisted profile is missing auto HDR settings"

[ "$fail" -eq 0 ] && echo "auto HDR settings smoke test passed" || { echo "auto HDR settings smoke test FAILED"; exit 1; }
