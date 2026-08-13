#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cache_root=${AQUEOUS_PLUGIN_CACHE_ROOT:-/tmp/aqueous-plugin-tests}

env -u LD_PRELOAD \
    ZIG_GLOBAL_CACHE_DIR="$cache_root/global" \
    ZIG_LOCAL_CACHE_DIR="$cache_root/local" \
    zig build test --build-file "$plugin_root/helper/build.zig"

env -u LD_PRELOAD \
    ZIG_GLOBAL_CACHE_DIR="$cache_root/global" \
    ZIG_LOCAL_CACHE_DIR="$cache_root/local" \
    zig build --build-file "$plugin_root/helper/build.zig" \
    --prefix "$plugin_root/helper/zig-out"

"$plugin_root/tests/test-helper.sh"
"$plugin_root/tests/test-plugin.sh"
"$plugin_root/tests/test-noctalia.sh"
"$plugin_root/../packaging/tests/test-enable-noctalia-plugin.sh"
