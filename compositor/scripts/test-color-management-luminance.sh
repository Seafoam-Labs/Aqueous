#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
prefix=${AQUEOUS_WLROOTS_PREFIX:-"$here/.deps/wlroots-render-hook"}
source_file="$here/scripts/fixtures/color-management-luminance.c"

die() { echo "FAIL: $*" >&2; exit 1; }
for tool in cc pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[ -r "$source_file" ] || die "missing luminance fixture"
[ -r "$prefix/lib/pkgconfig/wlroots-0.20.pc" ] ||
    die "patched wlroots is not installed at $prefix"

test_root=$(mktemp -d /tmp/aqueous-color-management-luminance.XXXXXX)
cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
pkg-config --exists wlroots-0.20 || die "patched wlroots pkg-config metadata is unavailable"

# shellcheck disable=SC2046
cc -std=c11 -Wall -Wextra -Werror -O2 -DWLR_USE_UNSTABLE \
    "$source_file" -o "$test_root/color-management-luminance" \
    $(pkg-config --cflags --libs wlroots-0.20)

LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$test_root/color-management-luminance"
