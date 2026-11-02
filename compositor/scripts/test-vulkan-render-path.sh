#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
source_dir=${1:?usage: test-vulkan-render-path.sh WLROOTS_SOURCE [PREFIX]}
prefix=${2:-"$here/.deps/wlroots-render-hook"}
work=$(mktemp -d /tmp/aqueous-render-path.XXXXXX)
trap 'rm -rf "$work"' EXIT
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
read -r -a flags <<< "$(pkg-config --cflags wlroots-0.20)"
cc -std=c11 -Wall -Wextra -Werror -DWLR_USE_UNSTABLE -I"$source_dir/include" \
    "$here/scripts/fixtures/vulkan-render-path.c" "${flags[@]}" -o "$work/test"
"$work/test"
