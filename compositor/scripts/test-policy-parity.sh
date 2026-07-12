#!/usr/bin/env bash
set -euo pipefail

# End-to-end internal-policy parity test. Each run creates a real headless
# compositor, maps Ghostty windows, and drives Aqueous through wlroots virtual
# keyboard/pointer protocols. Checkpoints compare the implicit default policy
# mode with explicit `-policy internal` after identical user-visible actions.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURES="$here/scripts/fixtures"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
for tool in ghostty wlrctl timeout; do
    have "$tool" || die "$tool is required for real-window policy integration tests"
done
[ -r "$FIXTURES/parity-wm.toml" ] || die "missing parity-wm.toml fixture"
[ -r "$FIXTURES/parity-rules.toml" ] || die "missing parity-rules.toml fixture"

TEST_ROOT=$(mktemp -d /tmp/aqueous-policy-parity.XXXXXX)
COMPOSITOR_PID=""
CLIENT_PIDS=()
cleanup_session() {
    for pid in "${CLIENT_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    COMPOSITOR_PID=""
    CLIENT_PIDS=()
}
cleanup() { cleanup_session; rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

trace_line() {
    grep 'source=internal phase=render_finish' "$SESSION_LOG" 2>/dev/null | tail -1
}

trace_field() {
    local line=$1 key=$2
    sed -n "s/.* ${key}=\([^ ]*\).*/\1/p" <<<"$line"
}

wait_windows() {
    local wanted=$1 n=0 line value
    while [ "$n" -lt 200 ]; do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited; see $SESSION_LOG"
        line=$(trace_line || true)
        value=$(trace_field "$line" windows)
        [ "$value" = "$wanted" ] && return 0
        sleep 0.05
        n=$((n + 1))
    done
    tail -80 "$SESSION_LOG" >&2
    die "timed out waiting for windows=$wanted (last=${value:-none})"
}

wait_field_eq() {
    local key=$1 wanted=$2 n=0 line value
    while [ "$n" -lt 160 ]; do
        line=$(trace_line || true)
        value=$(trace_field "$line" "$key")
        [ -n "$value" ] && [ "$value" = "$wanted" ] && return 0
        sleep 0.05
        n=$((n + 1))
    done
    die "timed out waiting for $key=$wanted (last=${value:-none})"
}

wait_field_ne() {
    local key=$1 old=$2 n=0 line value
    while [ "$n" -lt 160 ]; do
        line=$(trace_line || true)
        value=$(trace_field "$line" "$key")
        [ -n "$value" ] && [ "$value" != "$old" ] && return 0
        sleep 0.05
        n=$((n + 1))
    done
    die "timed out waiting for $key to change from $old"
}

checkpoint() {
    local name=$1 line
    line=$(trace_line)
    printf '%s windows=%s order=%s geometry=%s workspace=%s focus=%s\n' \
        "$name" \
        "$(trace_field "$line" windows)" \
        "$(trace_field "$line" order)" \
        "$(trace_field "$line" geometry)" \
        "$(trace_field "$line" workspace)" \
        "$(trace_field "$line" focus)" >>"$RESULT_FILE"
}

press() {
    local text=$1 modifiers=$2
    wlrctl keyboard type "$text" modifiers "$modifiers"
}

launch_ghostty() {
    local identity=$1
    ghostty \
        --config-file=/dev/null \
        --config-default-files=false \
        --initial-window=false \
        --gtk-single-instance=false \
        --window-decoration=false \
        --class="$identity,$identity" \
        --title="$identity" \
        -e sleep 60 >/dev/null 2>&1 &
    CLIENT_PIDS+=("$!")
}

start_session() {
    local label=$1 mode=$2 runtime="$TEST_ROOT/$label-runtime" n=0 socket=""
    mkdir -p "$runtime/config" "$runtime/home"
    chmod 700 "$runtime"
    SESSION_LOG="$TEST_ROOT/$label.log"
    RESULT_FILE="$TEST_ROOT/$label.checkpoints"
    : >"$RESULT_FILE"

    local args=()
    [ -z "$mode" ] || args=(-policy "$mode")
    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    WLR_RENDERER=pixman \
    XDG_RUNTIME_DIR="$runtime" \
    XDG_CONFIG_HOME="$runtime/config" \
    HOME="$runtime/home" \
    AQUEOUS_CONFIG="$FIXTURES/parity-wm.toml" \
    AQUEOUS_RULES="$FIXTURES/parity-rules.toml" \
    AQUEOUS_MOD=Super \
    GDK_BACKEND=wayland \
        "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -log-level info "${args[@]}" -c true \
        >"$SESSION_LOG" 2>&1 &
    COMPOSITOR_PID=$!

    while [ "$n" -lt 160 ]; do
        if ! kill -0 "$COMPOSITOR_PID" 2>/dev/null; then
            tail -80 "$SESSION_LOG" >&2
            die "compositor failed during $label startup"
        fi
        socket=$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
        [ -n "$socket" ] && break
        sleep 0.05
        n=$((n + 1))
    done
    [ -n "$socket" ] || die "$label compositor did not create a Wayland socket"
    export XDG_RUNTIME_DIR="$runtime" XDG_CONFIG_HOME="$runtime/config" HOME="$runtime/home"
    export WAYLAND_DISPLAY="$socket" GDK_BACKEND=wayland

    grep -q 'policy mode=internal' "$SESSION_LOG" || die "$label did not start internal policy"
}

exercise_session() {
    local baseline focus0 focus1 focus2 return_focus cycle_focus geom1 geom2 geom_mono ws1 ws2 moved_geom fullscreen_geom manual_geom closed_geom fallback_geom tile_after_fallback

    baseline=$(trace_line)
    focus0=$(trace_field "$baseline" focus)
    ws1=$(trace_field "$baseline" workspace)

    echo "CHECK: real Ghostty mapping and pointer focus"
    launch_ghostty aq-parity-one
    wait_windows 1
    wlrctl pointer move 300 300
    wait_field_ne focus "$focus0"
    focus1=$(trace_field "$(trace_line)" focus)
    geom1=$(trace_field "$(trace_line)" geometry)
    checkpoint one_window_focused

    echo "CHECK: spawn keybinding and tiled geometry"
    press $'\n' SUPER
    wait_windows 2
    geom2=$(trace_field "$(trace_line)" geometry)
    [ "$geom2" != "$geom1" ] || die "tiling geometry did not change for the second window"
    checkpoint two_window_tile

    echo "CHECK: directional focus and layout geometry"
    press l SUPER
    wait_field_ne focus "$focus1"
    focus2=$(trace_field "$(trace_line)" focus)
    checkpoint directional_focus

    press m SUPER
    wait_field_ne geometry "$geom2"
    geom_mono=$(trace_field "$(trace_line)" geometry)
    checkpoint monocle_geometry
    press t SUPER
    wait_field_eq geometry "$geom2"
    checkpoint tile_geometry_restored
    [ "$geom_mono" != "$geom2" ] || die "monocle and tile geometry traces are identical"

    echo "CHECK: repeated workspace switching"
    press 2 SUPER
    wait_field_ne workspace "$ws1"
    ws2=$(trace_field "$(trace_line)" workspace)
    checkpoint workspace_2_empty
    press 1 SUPER
    wait_field_eq workspace "$ws1"
    wait_field_ne focus "$focus0"
    return_focus=$(trace_field "$(trace_line)" focus)
    checkpoint workspace_1_return
    press 2 SUPER
    wait_field_eq workspace "$ws2"
    press 1 SUPER
    wait_field_eq workspace "$ws1"
    wait_field_eq focus "$return_focus"
    checkpoint workspace_repeat_return

    echo "CHECK: move window and repeat workspace switching"
    press 2 SHIFT,SUPER
    wait_field_ne geometry "$geom2"
    moved_geom=$(trace_field "$(trace_line)" geometry)
    checkpoint window_moved_to_workspace_2
    press 2 SUPER
    wait_field_eq workspace "$ws2"
    wait_field_eq focus "$return_focus"
    checkpoint moved_window_focused
    press 1 SUPER
    wait_field_eq workspace "$ws1"
    press 2 SUPER
    wait_field_eq workspace "$ws2"
    wait_field_eq focus "$return_focus"
    checkpoint workspace_repeat_with_window

    echo "CHECK: floating workspace rule"
    launch_ghostty aq-parity-rule
    wait_windows 3
    wait_field_ne geometry "$moved_geom"
    checkpoint floating_workspace_rule

    echo "CHECK: fullscreen rule lifecycle and manual override"
    # fullscreen client; a manual toggle must survive a rules reload.
    launch_ghostty aq-parity-fullscreen
    wait_windows 4
    fullscreen_geom=$(trace_field "$(trace_line)" geometry)
    press c SUPER
    wait_field_ne focus "$return_focus"
    cycle_focus=$(trace_field "$(trace_line)" focus)
    press c SUPER
    wait_field_ne focus "$cycle_focus"
    press f SHIFT,SUPER
    wait_field_ne geometry "$fullscreen_geom"
    manual_geom=$(trace_field "$(trace_line)" geometry)
    checkpoint manual_fullscreen_override
    press r SUPER
    sleep 0.35
    wait_field_eq geometry "$manual_geom"
    checkpoint override_survives_reload

    echo "CHECK: close keybinding"
    press q SUPER
    wait_windows 3
    closed_geom=$(trace_field "$(trace_line)" geometry)
    checkpoint close_keybinding

    echo "CHECK: game-mode Rows remainder with a real anchor"
    launch_ghostty aq-parity-game
    wait_windows 4
    wait_field_ne geometry "$closed_geom"
    checkpoint game_mode_rows_remainder

    echo "CHECK: game-mode Tile fallback after the anchor closes"
    press g SUPER
    press q SUPER
    wait_windows 3
    fallback_geom=$(trace_field "$(trace_line)" geometry)
    checkpoint game_mode_tile_fallback
    press t SUPER
    sleep 0.15
    tile_after_fallback=$(trace_field "$(trace_line)" geometry)
    [ "$fallback_geom" = "$tile_after_fallback" ] || die "game-mode fallback_layout=tile does not match the Tile engine"
    checkpoint tile_matches_game_mode_fallback
}

run_case() {
    local label=$1 mode=$2
    start_session "$label" "$mode"
    exercise_session
    cleanup_session
}

run_case default ""
run_case explicit internal

cmp -s "$TEST_ROOT/default.checkpoints" "$TEST_ROOT/explicit.checkpoints" || {
    echo "--- implicit default ---" >&2
    cat "$TEST_ROOT/default.checkpoints" >&2
    echo "--- explicit internal ---" >&2
    cat "$TEST_ROOT/explicit.checkpoints" >&2
    die "default/internal real-window checkpoints differ"
}

set +e
external_output=$(WLR_BACKENDS=headless WLR_RENDERER=pixman \
    "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -policy external -c true 2>&1)
external_status=$?
set -e
[ "$external_status" -ne 0 ] || die "external policy unexpectedly enabled"
case "$external_output" in
    *"requires a build with -Dexternal-policy=true"*) ;;
    *) printf '%s\n' "$external_output" >&2; die "external policy gate returned the wrong error" ;;
esac

echo "policy integration passed: Ghostty windows, rules, geometry, focus, repeated workspaces, game-mode Rows and Tile fallback, fullscreen overrides, and keybindings"
