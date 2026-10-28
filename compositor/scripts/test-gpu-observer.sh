#!/usr/bin/env bash
# Software-ICD regression for the opt-in Vulkan device observer.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d /tmp/aqueous-gpu-observer.XXXXXX)
trap 'rm -rf "$work"' EXIT
icd=${AQUEOUS_TEST_VULKAN_ICD:-/usr/share/vulkan/icd.d/lvp_icd.json}
[[ -r $icd ]] || { echo 'Software Vulkan ICD unavailable'; exit 77; }
zig build --build-file "$here/fixtures/build.zig" gpu-observer -Doptimize=safe --prefix "$work"
env -u MESA_VK_DEVICE_SELECT -u MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE \
    -u DRI_PRIME -u __NV_PRIME_RENDER_OFFLOAD -u __VK_LAYER_NV_optimus \
    VK_DRIVER_FILES="$icd" LD_PRELOAD="$work/lib/libgpu-observer.so" "$work/bin/gpu-observer-client" 2>"$work/log"
test "$(grep -c 'api=vulkan create_result=0' "$work/log")" = 2
grep -q 'enumerated=1 selection_verified=false' "$work/log"
grep -q 'has_render=false' "$work/log"
echo 'PASS: actual Vulkan creation observed through direct and loader dispatch; software is not a DRM GPU'
