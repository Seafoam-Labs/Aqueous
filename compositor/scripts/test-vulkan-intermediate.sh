#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
prefix=${1:-"$here/.deps/wlroots-render-hook"}
work=$(mktemp -d /tmp/aqueous-intermediate.XXXXXX)
trap 'rm -rf "$work"' EXIT
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
read -r -a flags <<< "$(pkg-config --cflags --libs wlroots-0.20 vulkan wayland-server libdrm pixman-1)"
cc -Wall -Wextra -Werror -DWLR_USE_UNSTABLE -Wl,--export-dynamic "$here/scripts/fixtures/vulkan-intermediate.c" \
    -o "$work/test" "${flags[@]}" -ldl
status=0
"$work/test" >"$work/log" 2>&1 || status=$?
if ((status != 0)); then cat "$work/log"; exit "$status"; fi
if rg '\[ERROR\]|SYNC-HAZARD-|VUID-|Validation Error' "$work/log"; then exit 1; fi
tail -1 "$work/log"
