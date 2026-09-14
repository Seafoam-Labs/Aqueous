#!/usr/bin/env bash
# Public suffixed commands enter their private toolchain, never the stable one.
set -euo pipefail
instance=@INSTANCE@
private=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
command=${1:?Missing private command}; shift
case $command in aqueous|aqueousctl|aqueous-config) ;; *) echo 'Unknown Aqueous Git command' >&2; exit 2;; esac
if [[ ${AQUEOUS_INSTANCE:-} != "$instance" ]]; then
    # Starting from a stable desktop must not inherit its source files or IPC.
    unset AQUEOUS_CONFIG AQUEOUS_LAYOUT AQUEOUS_INPUT AQUEOUS_OUTPUTS AQUEOUS_RULES AQUEOUS_APPEARANCE AQUEOUS_SOCKET
    if [[ $command != aqueous ]]; then
        # libwayland falls back to wayland-0 when WAYLAND_DISPLAY is absent.
        export WAYLAND_DISPLAY=aqueous-git-unselected
    fi
fi
for key in CONFIG LAYOUT INPUT OUTPUTS RULES APPEARANCE SOCKET; do
    override=AQUEOUS_GIT_$key
    if [[ -v $override ]]; then export "AQUEOUS_$key=${!override}"; fi
done
if [[ $command != aqueous && -v AQUEOUS_GIT_WAYLAND_DISPLAY ]]; then
    export WAYLAND_DISPLAY=$AQUEOUS_GIT_WAYLAND_DISPLAY
fi
export AQUEOUS_INSTANCE=$instance
export PATH="$private/bin:${PATH:-/usr/bin:/bin}"
# The same SONAME exists in stable; always prefer this build's patched library.
export LD_LIBRARY_PATH="$private/lib/aqueous${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$private/bin/$command" "$@"
