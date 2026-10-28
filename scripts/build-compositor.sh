#!/usr/bin/env bash
# Builds the in-tree Aqueous compositor and control client and stages them at
# ./bin/ (relative to the repo root).
#
# Used by:
#   - launch_aqueous.sh (dev-time, on demand)
#   - CI
#   - Rider "Aqueous (Release, AOT)" run config (with AQUEOUS_OPTIMIZE=safe)
#
# Env:
#   AQUEOUS_OPTIMIZE     Zig optimize mode (debug, safe, fast, small).
#                        Default: debug.
#   AQUEOUS_LINKER_FLAG  Extra flag selecting the Zig linker backend.
#                        Default: -Dllvm (validated LLVM + LLD configuration).
#                        Set to an empty string to test the native backend.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
optimize="${AQUEOUS_OPTIMIZE:-debug}"
linker_flag="${AQUEOUS_LINKER_FLAG--Dllvm}"

if ! command -v zig >/dev/null 2>&1; then
    echo "[build-compositor] zig not found in PATH. Install zig >= 0.17.0" >&2
    echo "[build-compositor] AQUEOUS_COMPOSITOR_BIN to a prebuilt compositor." >&2
    exit 1
fi

echo "[build-compositor] zig $(zig version), optimize=$optimize, linker_flag=${linker_flag:-<none>}"
"$here/compositor/scripts/build-wlroots-render-hook.sh"
(
    cd "$here/compositor"
    export PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig"
    export LD_LIBRARY_PATH="$PWD/.deps/wlroots-render-hook/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    zig build -Doptimize="$optimize" -Dxwayland ${linker_flag:+$linker_flag}
)

mkdir -p "$here/bin"
if [ -x "$here/compositor/zig-out/bin/aqueous" ]; then
    src="$here/compositor/zig-out/bin/aqueous"
else
    echo "[build-compositor] no compositor binary produced under compositor/zig-out/bin/" >&2
    exit 1
fi
install -m 0755 "$src" "$here/bin/aqueous"
echo "[build-compositor] -> $here/bin/aqueous"

mkdir -p "$here/lib/aqueous"
install -m 0755 \
    "$here/compositor/zig-out/lib/aqueous/libwlroots-0.20.so" \
    "$here/lib/aqueous/libwlroots-0.20.so"
echo "[build-compositor] -> $here/lib/aqueous/libwlroots-0.20.so"

if [ -x "$here/compositor/zig-out/bin/aqueousctl" ]; then
    install -m 0755 "$here/compositor/zig-out/bin/aqueousctl" "$here/bin/aqueousctl"
    echo "[build-compositor] -> $here/bin/aqueousctl"
else
    echo "[build-compositor] no aqueousctl binary produced under compositor/zig-out/bin/" >&2
    exit 1
fi
