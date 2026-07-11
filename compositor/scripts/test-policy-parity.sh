#!/usr/bin/env bash
set -euo pipefail

# Verify the final policy cutover under the headless backend: the implicit
# default and explicit internal mode produce the same state trace, while a
# normal production build rejects the retired external policy mode.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || {
    echo "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN" >&2
    exit 2
}
command -v timeout >/dev/null 2>&1 || { echo "timeout is required" >&2; exit 2; }

run_session() {
    local mode=$1
    local status
    local args=()

    [ -z "$mode" ] || args=(-policy "$mode")
    set +e
    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    WLR_RENDERER=pixman \
    AQUEOUS_NESTED=1 \
        timeout 8s "$AQUEOUS_COMPOSITOR_BIN" \
            -no-xwayland -log-level info "${args[@]}" -c "sleep 2" 2>&1
    status=$?
    set -e

    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
}

default_output=$(run_session "")
case "$default_output" in
    *"policy mode=internal"*"source=internal"*) ;;
    *) printf '%s\n' "$default_output" >&2; exit 1 ;;
esac

internal_output=$(run_session internal)
case "$internal_output" in
    *"policy mode=internal"*"source=internal"*) ;;
    *) printf '%s\n' "$internal_output" >&2; exit 1 ;;
esac
case "$internal_output" in
    *"source=external"*) printf '%s\n' "$internal_output" >&2; exit 1 ;;
esac

default_trace=$(printf '%s\n' "$default_output" | sed -n 's/.*source=internal /source=internal /p')
internal_trace=$(printf '%s\n' "$internal_output" | sed -n 's/.*source=internal /source=internal /p')
[ "$default_trace" = "$internal_trace" ] || {
    echo "default/internal state trace mismatch" >&2
    exit 1
}

set +e
external_output=$(WLR_BACKENDS=headless WLR_RENDERER=pixman \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -policy external -c true 2>&1)
external_status=$?
set -e
[ "$external_status" -ne 0 ] || { echo "external policy unexpectedly enabled" >&2; exit 1; }
case "$external_output" in
    *"requires a build with -Dexternal-policy=true"*) ;;
    *) printf '%s\n' "$external_output" >&2; exit 1 ;;
esac

echo "policy cutover passed: internal default parity and external-policy gate"
