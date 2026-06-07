#!/usr/bin/env bash
# Builds the in-tree RiverDelta compositor and stages the binary at
# ./bin/riverdelta (relative to the repo root).
#
# Used by:
#   - launch_river.sh (dev-time, on demand)
#   - CI
#   - Rider "Aqueous (Release, AOT)" run config (with RIVERDELTA_OPTIMIZE=ReleaseSafe)
#
# Env:
#   RIVERDELTA_OPTIMIZE     Zig optimize mode (Debug, ReleaseSafe, ReleaseFast,
#                           ReleaseSmall). Default: Debug.
#   RIVERDELTA_LINKER_FLAG  Extra flag selecting the Zig linker backend.
#                           Default: -Dllvm (forces LLVM + LLD, needed because
#                           Zig 0.16.0's self-hosted ELF linker can't handle
#                           R_X86_64_PC64 in .sframe emitted by gcc >= 16).
#                           Set to an empty string once that's fixed upstream.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
optimize="${RIVERDELTA_OPTIMIZE:-Debug}"
linker_flag="${RIVERDELTA_LINKER_FLAG--Dllvm}"

if ! command -v zig >/dev/null 2>&1; then
    echo "[build-compositor] zig not found in PATH. Install zig >= 0.16.0" >&2
    echo "[build-compositor] (e.g. zig-master-bin from the AUR) or set" >&2
    echo "[build-compositor] AQUEOUS_RIVER_BIN to a prebuilt compositor." >&2
    exit 1
fi

echo "[build-compositor] zig $(zig version), optimize=$optimize, linker_flag=${linker_flag:-<none>}"
(cd "$here/compositor" && zig build -Doptimize="$optimize" -Dscenefx=true -Dxwayland ${linker_flag:+$linker_flag})

mkdir -p "$here/bin"
# Upstream RiverDelta names the produced binary `riverdelta` (older
# revisions called it `river`). Accept either for forward/back-compat.
if [ -x "$here/compositor/zig-out/bin/riverdelta" ]; then
    src="$here/compositor/zig-out/bin/riverdelta"
elif [ -x "$here/compositor/zig-out/bin/river" ]; then
    src="$here/compositor/zig-out/bin/river"
else
    echo "[build-compositor] no compositor binary produced under compositor/zig-out/bin/" >&2
    exit 1
fi
install -m 0755 "$src" "$here/bin/riverdelta"
echo "[build-compositor] -> $here/bin/riverdelta"
