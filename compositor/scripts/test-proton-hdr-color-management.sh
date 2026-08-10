#!/usr/bin/env bash
set -euo pipefail

# Exercise the exact Wayland contract Wine/Proton uses for native HDR. The
# output is intentionally headless/SDR: that also verifies SDR metadata keeps
# max luminance equal to reference white and therefore does not falsely signal
# HDR. Proton's strict target/reference headroom predicate and its rounding
# boundaries are covered by test-color-management-luminance.sh.

here=$(cd "$(dirname "$0")/.." && pwd)
compositor_bin=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
fixture_source="$here/scripts/fixtures/color-management-v1-probe.c"
protocol_root=$(pkg-config --variable=pkgdatadir wayland-protocols 2>/dev/null || true)
protocol="$protocol_root/staging/color-management/color-management-v1.xml"

die() { echo "FAIL: $*" >&2; exit 1; }
for tool in cc pkg-config wayland-scanner; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[ -x "$compositor_bin" ] || die "aqueous binary not found at $compositor_bin"
[ -r "$fixture_source" ] || die "missing color-management probe fixture"
[ -r "$protocol" ] || die "wayland-protocols 1.49 color-management-v1 XML is required"
pkg-config --exists wayland-client || die "Wayland client development files are required"

test_root=$(mktemp -d /tmp/aqueous-proton-hdr-color-management.XXXXXX)
runtime="$test_root/runtime"
compositor_log="$test_root/compositor.log"
client_log="$test_root/client.log"
probe_bin="$test_root/color-management-v1-probe"
compositor_pid=""

cleanup() {
    [ -z "$compositor_pid" ] || kill "$compositor_pid" 2>/dev/null || true
    [ -z "$compositor_pid" ] || wait "$compositor_pid" 2>/dev/null || true
    rm -rf "$test_root"
}
trap cleanup EXIT

wayland-scanner client-header "$protocol" \
    "$test_root/color-management-v1-client-protocol.h"
wayland-scanner private-code "$protocol" \
    "$test_root/color-management-v1-protocol.c"
# shellcheck disable=SC2046
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$test_root" \
    "$fixture_source" "$test_root/color-management-v1-protocol.c" \
    -o "$probe_bin" $(pkg-config --cflags --libs wayland-client)

mkdir -p "$runtime/config" "$runtime/home"
chmod 700 "$runtime"
env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    XDG_RUNTIME_DIR="$runtime" \
    XDG_CONFIG_HOME="$runtime/config" \
    HOME="$runtime/home" \
    "$compositor_bin" -no-xwayland -policy internal -log-level debug -c true \
    >"$compositor_log" 2>&1 &
compositor_pid=$!

socket=""
for _ in $(seq 1 240); do
    kill -0 "$compositor_pid" 2>/dev/null || {
        tail -120 "$compositor_log" >&2
        die "compositor failed during headless startup"
    }
    socket=$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"

if ! env -u LD_PRELOAD XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$socket" \
        "$probe_bin" >"$client_log" 2>&1; then
    cat "$client_log" >&2
    tail -120 "$compositor_log" >&2
    die "color-management-v1 client probe failed"
fi
cat "$client_log"
if grep -Eqi 'protocol error|unsupported_feature' "$compositor_log"; then
    tail -120 "$compositor_log" >&2
    die "compositor logged a color-management protocol failure"
fi
