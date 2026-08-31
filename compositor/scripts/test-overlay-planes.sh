#!/usr/bin/env bash
set -euo pipefail

# CI-safe overlay-plane test. It exercises the backend-independent state
# machine, verifies that the patched wlroots contract builds, then starts a
# headless compositor and validates both aqueousctl diagnostic formats.

unset LD_PRELOAD

here=$(cd "$(dirname "$0")/.." && pwd)
fixture="$here/scripts/fixtures/overlay-planes-wm.toml"
patched_prefix=${AQUEOUS_WLROOTS_PREFIX:-"$here/.deps/wlroots-render-hook"}

die() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

for tool in jq zig; do command -v "$tool" >/dev/null 2>&1 || skip "$tool is required"; done
[ -r "$fixture" ] || die "missing fixture $fixture"
[ -r "$patched_prefix/include/wlroots-0.20/wlr/types/wlr_scene.h" ] ||
    die "patched wlroots headers not found; run scripts/build-wlroots-render-hook.sh"

grep -Fq 'WLR_AQUEOUS_OUTPUT_LAYER_PROMOTION_VERSION 2' \
    "$patched_prefix/include/wlroots-0.20/wlr/types/wlr_scene.h" ||
    die "wlroots promotion API version 2 is not installed"
grep -Fq 'bool must_scan_out;' \
    "$patched_prefix/include/wlroots-0.20/wlr/types/wlr_output_layer.h" ||
    die "wlroots required-layer contract is missing"

cache_dir=$(mktemp -d /tmp/aqueous-overlay-zig-cache.XXXXXX)
test_root=$(mktemp -d /tmp/aqueous-overlay-test.XXXXXX)
compositor_pid=""
cleanup() {
    [ -z "$compositor_pid" ] || kill "$compositor_pid" 2>/dev/null || true
    [ -z "$compositor_pid" ] || wait "$compositor_pid" 2>/dev/null || true
    rm -rf -- "$cache_dir" "$test_root"
}
trap cleanup EXIT HUP INT TERM

if [ -n "${AQUEOUS_COMPOSITOR_BIN:-}" ]; then
    compositor_bin=$AQUEOUS_COMPOSITOR_BIN
    ctl_bin=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
else
    install_dir="$test_root/install"
    (
        cd "$here"
        PKG_CONFIG_PATH="$patched_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        LD_LIBRARY_PATH="$patched_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        ZIG_GLOBAL_CACHE_DIR="$cache_dir" \
            zig build --prefix "$install_dir" -Dcpu=baseline -Doptimize=ReleaseSafe \
                -Dvulkan-effects=false -Danimations=false
    )
    compositor_bin="$install_dir/bin/aqueous"
    ctl_bin="$install_dir/bin/aqueousctl"
fi
[ -x "$compositor_bin" ] || die "aqueous binary not found at $compositor_bin"
[ -x "$ctl_bin" ] || die "aqueousctl binary not found at $ctl_bin"

ZIG_GLOBAL_CACHE_DIR="$cache_dir" zig test "$here/aqueous/overlay_planes.zig"

runtime="$test_root/runtime"
mkdir -p "$runtime/config" "$runtime/home"
chmod 700 "$runtime"
log="$test_root/aqueous.log"

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$runtime" \
XDG_CONFIG_HOME="$runtime/config" \
HOME="$runtime/home" \
AQUEOUS_CONFIG="$fixture" \
AQUEOUS_RULES="$test_root/no-rules.toml" \
LD_LIBRARY_PATH="$patched_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$compositor_bin" -no-xwayland -policy internal -log-level debug -c true \
    >"$log" 2>&1 &
compositor_pid=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$compositor_pid" 2>/dev/null || {
        tail -100 "$log" >&2
        die "headless compositor exited during startup"
    }
    socket=$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "headless compositor did not create a Wayland socket"

export XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$socket"
export LD_LIBRARY_PATH="$patched_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

json="$test_root/overlay.json"
text="$test_root/overlay.txt"
"$ctl_bin" overlay-planes --json >"$json"
"$ctl_bin" overlay-planes >"$text"

jq -e '
    length == 1 and
    .[0].enabled == true and
    .[0].capability == "unavailable" and
    .[0].phase == "unavailable" and
    .[0].rejection_reason == "backend_unavailable" and
    .[0].candidate_id == 0 and
    .[0].backoff_ms == 0 and
    (.[] | .counters | keys | sort) ==
      (["accepted","attempts","backoff_skips","demotions","fallback_retries","promotions","rejected"] | sort)
' "$json" >/dev/null || {
    cat "$json" >&2
    die "unexpected headless overlay-plane JSON"
}

for label in 'Enabled:' 'Capability:' 'Phase:' 'Reason:' 'Counters:'; do
    grep -Fq "$label" "$text" || die "plain diagnostics are missing $label"
done

echo "PASS: overlay state machine, required-layer ABI, and headless diagnostics"
