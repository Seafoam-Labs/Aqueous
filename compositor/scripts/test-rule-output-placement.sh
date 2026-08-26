#!/usr/bin/env bash
set -euo pipefail

# Window-rule output placement regression:
#   1. output-only rules use the destination's active workspace;
#   2. output + workspace rules use that numbered destination workspace;
#   3. workspace-only rules retain the normal admission output;
#   4. unavailable output names fall back without disrupting the compositor.

unset LD_PRELOAD

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
WM_CONFIG="$here/scripts/fixtures/parity-wm.toml"
GHOSTTY_CONFIG="$here/scripts/fixtures/ghostty.conf"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for tool in ghostty jq; do
    have "$tool" || die "$tool is required for output-rule integration tests"
done

TEST_ROOT=$(mktemp -d /tmp/aqueous-rule-output.XXXXXX)
RUNTIME="$TEST_ROOT/runtime"
RULES="$TEST_ROOT/rules.toml"
COMPOSITOR_LOG="$TEST_ROOT/compositor.log"
COMPOSITOR_PID=""
CLIENT_PIDS=()

cleanup() {
    for pid in "${CLIENT_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${CLIENT_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$RUNTIME/config" "$RUNTIME/home"
chmod 700 "$RUNTIME"
: >"$RULES"

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=2 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$WM_CONFIG" \
AQUEOUS_RULES="$RULES" \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -policy internal -log-level debug -c true \
    >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -120 "$COMPOSITOR_LOG" >&2
        die "compositor failed during startup"
    }
    socket=$(find "$RUNTIME" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -n "$socket" ] && break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"

export XDG_RUNTIME_DIR="$RUNTIME" XDG_CONFIG_HOME="$RUNTIME/config" HOME="$RUNTIME/home"
export WAYLAND_DISPLAY="$socket" GDK_BACKEND=wayland

outputs=""
for _ in $(seq 1 160); do
    outputs=$("$AQUEOUSCTL_BIN" outputs --json 2>/dev/null || true)
    [ "$(jq 'length' <<<"$outputs" 2>/dev/null || echo 0)" -eq 2 ] && break
    sleep 0.05
done
[ "$(jq 'length' <<<"$outputs")" -eq 2 ] || die "aqueousctl did not report two outputs"
SOURCE=$(jq -r 'sort_by(.name) | .[0].name' <<<"$outputs")
DEST=$(jq -r 'sort_by(.name) | .[1].name' <<<"$outputs")
[ "$SOURCE" != "$DEST" ] || die "headless outputs did not have distinct names"

launch_window() {
    local identity=$1
    ghostty \
        --config-file="$GHOSTTY_CONFIG" \
        --config-default-files=false \
        --gtk-single-instance=false \
        --window-decoration=false \
        --class="$identity,$identity" \
        --title="$identity" \
        -e sleep 30 >/dev/null 2>&1 &
    CLIENT_PIDS+=("$!")
}

wait_window() {
    local title=$1 n=0 result=""
    while [ "$n" -lt 200 ]; do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited; see $COMPOSITOR_LOG"
        result=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null |
            jq -c --arg title "$title" '.[] | select(.title == $title)' 2>/dev/null |
            head -1 || true)
        if [ -n "$result" ]; then
            printf '%s\n' "$result"
            return 0
        fi
        sleep 0.05
        n=$((n + 1))
    done
    "$AQUEOUSCTL_BIN" windows --json >&2 || true
    tail -120 "$COMPOSITOR_LOG" >&2
    die "timed out waiting for $title"
}

# Capture the compositor's normal admission output rather than assuming a
# particular headless connector ordering.
launch_window aq-rule-baseline
baseline=$(wait_window aq-rule-baseline)
ADMISSION=$(jq -r '.output' <<<"$baseline")
# Exercise a real cross-output transfer even when the compositor's normal
# admission output happens to be the lexicographically later connector.
if [ "$DEST" = "$ADMISSION" ]; then DEST="$SOURCE"; fi

printf '%s\n' \
    '[[window]]' \
    'title = "aq-rule-output-only"' \
    "output = \"$DEST\"" \
    '' \
    '[[window]]' \
    'title = "aq-rule-output-workspace"' \
    "output = \"$DEST\"" \
    'workspace = 3' \
    '' \
    '[[window]]' \
    'title = "aq-rule-workspace-only"' \
    'workspace = 2' \
    '' \
    '[[window]]' \
    'title = "aq-rule-missing-output"' \
    'output = "AQUEOUS-MISSING-OUTPUT"' >"$RULES"

for _ in $(seq 1 60); do
    grep -q 'configuration hot-reloaded' "$COMPOSITOR_LOG" && break
    sleep 0.05
done
grep -q 'configuration hot-reloaded' "$COMPOSITOR_LOG" || die "rules did not hot-reload"

launch_window aq-rule-output-only
output_only=$(wait_window aq-rule-output-only)
[ "$(jq -r '.output' <<<"$output_only")" = "$DEST" ] || die "output-only rule missed $DEST"
[ "$(jq -r '.workspace' <<<"$output_only")" = 1 ] || die "output-only rule did not use the active workspace"

launch_window aq-rule-output-workspace
combined=$(wait_window aq-rule-output-workspace)
[ "$(jq -r '.output' <<<"$combined")" = "$DEST" ] || die "combined rule missed $DEST"
[ "$(jq -r '.workspace' <<<"$combined")" = 3 ] || die "combined rule missed destination workspace 3"

launch_window aq-rule-workspace-only
workspace_only=$(wait_window aq-rule-workspace-only)
[ "$(jq -r '.output' <<<"$workspace_only")" = "$ADMISSION" ] || die "workspace-only rule changed the admission output"
[ "$(jq -r '.workspace' <<<"$workspace_only")" = 2 ] || die "workspace-only rule missed workspace 2"

launch_window aq-rule-missing-output
missing=$(wait_window aq-rule-missing-output)
[ "$(jq -r '.output' <<<"$missing")" != 'AQUEOUS-MISSING-OUTPUT' ] || die "missing output rule created invalid membership"
kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited after unavailable output rule"
grep -q "window rule target output 'AQUEOUS-MISSING-OUTPUT'.*is unavailable" "$COMPOSITOR_LOG" ||
    die "unavailable output rule was not diagnosed"

echo "PASS: window rules place on outputs and workspaces with safe fallback"
