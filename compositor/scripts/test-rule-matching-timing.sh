#!/usr/bin/env bash
set -euo pipefail

# Window-rule matching timing regression (issue #131):
#   1. matching = "once" binds a rule to the first claiming window; later
#      matching windows fall through to the next rule;
#   2. matching = "startup" applies only while the compositor is in its
#      startup phase (shortened here via AQUEOUS_RULE_STARTUP_MS); windows
#      admitted after the settle delay fall through instead.

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
    have "$tool" || die "$tool is required for matching-timing integration tests"
done

TEST_ROOT=$(mktemp -d /tmp/opencode/aqueous-rule-timing.XXXXXX)
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

# The rules must exist before startup so the startup-phase window can claim
# them. The startup settle delay is shortened from the 10-second default to
# keep the post-startup assertion quick without racing the compositor.
cat >"$RULES" <<'EOF'
[[window]]
title = "aq-once-*"
matching = "once"
workspace = 4
[[window]]
title = "aq-once-*"
workspace = 6

[[window]]
title = "aq-startup-*"
matching = "startup"
workspace = 7
[[window]]
title = "aq-startup-*"
workspace = 8
EOF

WLR_BACKENDS=headless \
WLR_HEADLESS_OUTPUTS=1 \
WLR_RENDERER=pixman \
XDG_RUNTIME_DIR="$RUNTIME" \
XDG_CONFIG_HOME="$RUNTIME/config" \
XDG_STATE_HOME="$RUNTIME/state" \
XDG_CACHE_HOME="$RUNTIME/cache" \
HOME="$RUNTIME/home" \
AQUEOUS_CONFIG="$WM_CONFIG" \
AQUEOUS_RULES="$RULES" \
AQUEOUS_RULE_STARTUP_MS=${AQUEOUS_RULE_STARTUP_MS:-4000} \
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
export XDG_STATE_HOME="$RUNTIME/state" XDG_CACHE_HOME="$RUNTIME/cache"
export WAYLAND_DISPLAY="$socket" GDK_BACKEND=wayland

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

wait_workspace() {
    local title=$1 expected=$2 n=0 actual=""
    while [ "$n" -lt 200 ]; do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited; see $COMPOSITOR_LOG"
        actual=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null |
            jq -r --arg title "$title" '[.[] | select(.title == $title)][0].workspace // empty' 2>/dev/null || true)
        [ -n "$actual" ] && [ "$actual" = "$expected" ] && return 0
        sleep 0.05
        n=$((n + 1))
    done
    "$AQUEOUSCTL_BIN" windows --json >&2 || true
    tail -120 "$COMPOSITOR_LOG" >&2
    die "window '$title' never reached workspace $expected (last: ${actual:-missing})"
}

wait_absent_or_workspace() {
    local title=$1 expected=$2 n=0 actual=""
    while [ "$n" -lt 200 ]; do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited; see $COMPOSITOR_LOG"
        actual=$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null |
            jq -r --arg title "$title" '[.[] | select(.title == $title)][0].workspace // empty' 2>/dev/null || true)
        [ -n "$actual" ] && break
        sleep 0.05
        n=$((n + 1))
    done
    [ -n "$actual" ] || { tail -120 "$COMPOSITOR_LOG" >&2; die "timed out waiting for $title"; }
    # Give rule reconciliation this transaction before reading the placement.
    sleep 0.5
    actual=$("$AQUEOUSCTL_BIN" windows --json |
        jq -r --arg title "$title" '[.[] | select(.title == $title)][0].workspace')
    [ "$actual" = "$expected" ] || {
        "$AQUEOUSCTL_BIN" windows --json >&2 || true
        die "window '$title' landed on workspace $actual instead of $expected"
    }
}

# Exercise startup immediately, before the other clients use up its deadline.
launch_window aq-startup-first
if [ "${AQUEOUS_RULE_STARTUP_MS:-4000}" = 0 ]; then
    wait_workspace aq-startup-first 8
else
    wait_workspace aq-startup-first 7
fi

# 1. The first matching window claims the once budget: workspace 4.
launch_window aq-once-first
wait_workspace aq-once-first 4

# 2. A later window with the same matcher falls through to the next rule.
launch_window aq-once-second
wait_absent_or_workspace aq-once-second 6

# 4. Once the shortened startup phase expires, a later window falls through
#    to the fallback rule instead: workspace 8.
sleep 5
launch_window aq-startup-late
wait_absent_or_workspace aq-startup-late 8

kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited during matching-timing test"

echo "PASS: once and startup rules bind to their first eligible windows only"
