#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
prefix=${AQUEOUS_WLROOTS_PREFIX:-"$here/.deps/wlroots-render-hook"}
test_root=$(mktemp -d /tmp/aqueous-ext-capture.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
dimensions=()
case "${AQUEOUS_CAPTURE_BENCHMARK:-}" in
    "") ;;
    1080p) dimensions=(-DCAPTURE_WIDTH=1920 -DCAPTURE_HEIGHT=1080) ;;
    4k) dimensions=(-DCAPTURE_WIDTH=3840 -DCAPTURE_HEIGHT=2160) ;;
    *) echo "AQUEOUS_CAPTURE_BENCHMARK must be 1080p or 4k" >&2; exit 1 ;;
esac
if [ -n "${AQUEOUS_CAPTURE_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AQUEOUS_CAPTURE_ARTIFACT_DIR"
fi
protocol_dir=$(pkg-config --variable=pkgdatadir wayland-protocols)
protocols=(
    "$protocol_dir/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml"
    "$protocol_dir/staging/ext-image-capture-source/ext-image-capture-source-v1.xml"
    "$protocol_dir/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml"
    "$here/protocol/aqueous-capture-color-v1.xml"
    "$here/protocol/upstream/wlr-screencopy-unstable-v1.xml"
)
sources=()
for protocol in "${protocols[@]}"; do
    name=$(basename "$protocol" .xml)
    wayland-scanner client-header "$protocol" "$test_root/$name-client-protocol.h"
    wayland-scanner private-code "$protocol" "$test_root/$name-protocol.c"
    sources+=("$test_root/$name-protocol.c")
done
cc -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter -O2 -DWLR_USE_UNSTABLE \
    "${dimensions[@]}" \
    -I"$test_root" "$here/scripts/fixtures/ext-capture-formats.c" "${sources[@]}" \
    -o "$test_root/ext-capture-formats" \
    $(pkg-config --cflags --libs wlroots-0.20 wayland-client wayland-server pixman-1) -lm
LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$test_root/ext-capture-formats" "$@"
