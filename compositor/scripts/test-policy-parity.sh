#!/usr/bin/env bash
set -euo pipefail

# Exercises the migration-time policy selector under the headless backend and
# verifies that compare mode observes identical state at internal/external cycle
# boundaries. Build the compositor and transitional client before running.

here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/.." && pwd)

AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUS_WM_CLIENT_BIN=${AQUEOUS_WM_CLIENT_BIN:-"$repo/Aqueous/bin/Release/net10.0/aqueous-wm-client"}

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || {
    echo "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN" >&2
    exit 2
}
[ -x "$AQUEOUS_WM_CLIENT_BIN" ] || {
    echo "aqueous-wm-client not found at $AQUEOUS_WM_CLIENT_BIN" >&2
    exit 2
}
command -v timeout >/dev/null 2>&1 || { echo "timeout is required" >&2; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "awk is required" >&2; exit 2; }

run_session() {
    local mode=$1
    local child=$2
    local status

    set +e
    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    WLR_RENDERER=pixman \
    AQUEOUS_RIVER_WM=1 \
    AQUEOUS_NESTED=1 \
        timeout 12s "$AQUEOUS_COMPOSITOR_BIN" \
            -no-xwayland -log-level info -policy "$mode" -c "$child" 2>&1
    status=$?
    set -e

    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
}

internal_output=$(run_session internal "sleep 2")
case "$internal_output" in
    *"policy mode=internal"*"source=internal"*) ;;
    *) printf '%s\n' "$internal_output" >&2; exit 1 ;;
esac
case "$internal_output" in
    *"source=external"*) printf '%s\n' "$internal_output" >&2; exit 1 ;;
esac

external_output=$(run_session external "timeout 4s '$AQUEOUS_WM_CLIENT_BIN'")
case "$external_output" in
    *"policy mode=external"*"attached as window manager (v9)"*"source=external"*) ;;
    *) printf '%s\n' "$external_output" >&2; exit 1 ;;
esac

compare_output=$(run_session compare "timeout 4s '$AQUEOUS_WM_CLIENT_BIN'")
printf '%s\n' "$compare_output" | awk '
/state-trace/ {
    source = phase = fingerprint = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^source=/) { source = $i; sub(/^source=/, "", source) }
        if ($i ~ /^phase=/) { phase = $i; sub(/^phase=/, "", phase) }
        if ($i ~ /^fingerprint=/) { fingerprint = $i; sub(/^fingerprint=/, "", fingerprint) }
    }
    if (source == "internal") internal[phase SUBSEP fingerprint] = 1
    if (source == "external") {
        external[phase SUBSEP fingerprint]++
        phases[phase] = 1
    }
}
END {
    required["manage_start"] = required["manage_finish"] = 1
    required["render_start"] = required["render_finish"] = 1
    for (phase in required) {
        if (!(phase in phases)) {
            print "missing external trace phase: " phase > "/dev/stderr"
            failed = 1
        }
    }
    for (key in external) {
        if (!(key in internal)) {
            print "internal/external fingerprint mismatch" > "/dev/stderr"
            failed = 1
        }
    }
    exit failed
}'

echo "policy parity passed: internal, external, and compare modes"