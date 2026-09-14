#!/usr/bin/env bash
# Exercise the staged core with private headless outputs, config and D-Bus.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: smoke-core.sh PREFIX' >&2; exit 1; }
prefix=$(realpath -- "$1")
base=$(mktemp -d /tmp/aqueous-core-smoke.XXXXXXXX)
pid=
cleanup() {
    if [[ -n $pid ]]; then kill -- "-$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    rm -rf -- "$base"
}
trap cleanup EXIT
for name in ${!AQUEOUS_@}; do unset "$name"; done
unset DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS LD_PRELOAD LD_LIBRARY_PATH
export HOME=$base/home XDG_CONFIG_HOME=$base/config XDG_STATE_HOME=$base/state XDG_RUNTIME_DIR=$base/run
install -dm700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
export WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman PATH="$prefix/bin:$PATH"
setsid dbus-run-session -- "$prefix/bin/aqueous" -no-xwayland \
    -c 'printenv AQUEOUS_SOCKET WAYLAND_DISPLAY > "$XDG_RUNTIME_DIR/socket"' > "$base/log" 2>&1 &
pid=$!
deadline=$((SECONDS+15))
while [[ ! -f $base/run/socket || $(wc -l < "$base/run/socket") != 2 ]]; do
    if ! kill -0 "$pid" 2>/dev/null || (( SECONDS > deadline )); then cat "$base/log" >&2; exit 1; fi
    sleep .05
done
mapfile -t connection < "$base/run/socket"
export AQUEOUS_SOCKET=${connection[0]} WAYLAND_DISPLAY=${connection[1]}
timeout 30 "$prefix/bin/aqueous-config" snapshot --shell none > "$base/snapshot.json"
jq -e .ok "$base/snapshot.json" >/dev/null
jq '{protocol:1,expected_generation:.generation,changes:{}}' "$base/snapshot.json" > "$base/request.json"
timeout 30 "$prefix/bin/aqueous-config" validate --shell none --request - < "$base/request.json" > "$base/candidate.json"
jq -e .ok "$base/candidate.json" >/dev/null
timeout 10 "$prefix/bin/aqueousctl" outputs --json >/dev/null
mapped=false
while IFS= read -r child; do
    if [[ -r /proc/$child/maps ]] && grep -qF "$prefix/lib/aqueous/libwlroots-0.20.so" "/proc/$child/maps"; then mapped=true; fi
done < <(pgrep -P "$pid")
$mapped || { echo 'Staged wlroots was not mapped' >&2; exit 1; }
printf 'PASS: shell-driven core startup, bundled library, helper snapshot/validate and aqueousctl outputs\n'
