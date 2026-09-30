#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
source_dir=${1:?Usage: test-screencopy-sdr.sh PATCHED_WLROOTS_SOURCE [PREFIX]}
prefix=${2:-"$here/.deps/wlroots-render-hook"}
test_root=$(mktemp -d /tmp/aqueous-screencopy-sdr.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
read -r -a package_flags <<< "$(pkg-config --cflags --libs wlroots-0.20)"
read -r -a extra_flags <<< "${CFLAGS:-}"
flags=(-std=c11 -Wall -Wextra -Werror -O2 "${extra_flags[@]}" -UNDEBUG
    -DWLR_USE_UNSTABLE -I"$source_dir/include")
# The table initializer is internal to wlroots. Compile its exact source into
# the fixture instead of exposing an implementation symbol as public API.
"${CC:-cc}" "${flags[@]}" "$here/scripts/fixtures/screencopy-sdr.c" \
    "$source_dir/types/screencopy_sdr.c" "${package_flags[@]}" -lm -pthread \
    -o "$test_root/screencopy-sdr"
args=()
if [ "${AQUEOUS_CAPTURE_EXHAUSTIVE:-0}" = 1 ]; then args+=(--exhaustive); fi
"$test_root/screencopy-sdr" "${args[@]}"

case "${AQUEOUS_CAPTURE_BENCHMARK:-}" in
    "") ;;
    1080p|4k)
        "${CC:-cc}" "${flags[@]}" "$here/scripts/fixtures/screencopy-sdr-bench.c" \
            "$source_dir/types/screencopy_sdr.c" "${package_flags[@]}" -lm -pthread \
            -o "$test_root/screencopy-sdr-bench"
        "$test_root/screencopy-sdr-bench" "$AQUEOUS_CAPTURE_BENCHMARK"
        ;;
    *) echo "AQUEOUS_CAPTURE_BENCHMARK must be 1080p or 4k" >&2; exit 1 ;;
esac
