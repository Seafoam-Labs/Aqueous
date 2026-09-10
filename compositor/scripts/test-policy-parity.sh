#!/usr/bin/env bash
set -euo pipefail

# End-to-end internal-policy parity test. Each run creates a real headless
# compositor, maps Ghostty windows, and drives Aqueous through wlroots virtual
# keyboard/pointer protocols. Checkpoints compare the implicit default policy
# mode with explicit `-policy internal` after identical user-visible actions.

here=$(cd "$(dirname "$0")/.." && pwd)
# The spawn-terminal fixture intentionally uses a repository-relative path.
# Pin the process working directory so invoking this script from compositor/ or
# elsewhere cannot make Ghostty open its "Configuration Errors" helper window.
cd "$here/.."
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURES="$here/scripts/fixtures"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
for tool in ghostty jq wlrctl timeout dbus-run-session; do
    have "$tool" || die "$tool is required for real-window policy integration tests"
done
[ -r "$FIXTURES/parity-wm.toml" ] || die "missing parity-wm.toml fixture"
[ -r "$FIXTURES/parity-rules.toml" ] || die "missing parity-rules.toml fixture"
[ -r "$FIXTURES/parity-dbus.conf" ] || die "missing parity-dbus.conf fixture"

# GTK falls back to "GTK Application" without a session bus. Always use a
# private bus, with service activation disabled, for deterministic app IDs.
if [ "${AQUEOUS_POLICY_PRIVATE_BUS:-0}" != 1 ]; then
    exec dbus-run-session --config-file="$FIXTURES/parity-dbus.conf" -- \
        env AQUEOUS_POLICY_PRIVATE_BUS=1 bash "$here/scripts/test-policy-parity.sh"
fi

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

wait_settled() {
    local previous="" current="" stable=0 n=0
    # Mapping and keyboard actions can complete several configure/focus cycles.
    # Compare state rather than the sequence number before taking a checkpoint.
    while [ "$n" -lt 200 ]; do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited while settling"
        current=$(trace_line | sed 's/^.*source=/source=/')
        if [ -n "$current" ] && [ "$current" = "$previous" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge 3 ] && return 0
        else
            stable=0
        fi
        previous=$current
        sleep 0.05
        n=$((n + 1))
    done
    die "compositor state did not settle"
}

wait_windows() {
    local wanted=$1 n=0 line value
    while [ "$n" -lt 200 ]; do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited; see $SESSION_LOG"
        line=$(trace_line || true)
        value=$(trace_field "$line" windows)
        if [ "$value" = "$wanted" ]; then
            wait_settled
            value=$(trace_field "$(trace_line)" windows)
            [ "$value" = "$wanted" ] && return 0
        fi
        sleep 0.05
        n=$((n + 1))
    done
    "$AQUEOUSCTL_BIN" windows --json 2>/dev/null |
        jq -c '[.[] | {identifier,title,app_id,class,states}]' >&2 || true
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
    wait_settled
}

focus_fixture() {
    local app_id="org.aqueous.test.$1" id
    id=$("$AQUEOUSCTL_BIN" windows --json | jq -er --arg app_id "$app_id" '
        map(select(.app_id == $app_id)) |
        if length == 1 then .[0].id else error("fixture is missing or ambiguous") end')
    "$AQUEOUSCTL_BIN" window activate --id "$id" --seat default --json >/dev/null
    wait_settled
}

wait_toplevel_title() {
    local title=$1 n=0 listing=""
    while [ "$n" -lt 100 ]; do
        listing=$(wlrctl toplevel list)
        grep -q "$title" <<<"$listing" && {
            printf '%s\n' "$listing"
            return 0
        }
        sleep 0.05
        n=$((n + 1))
    done
    return 1
}

launch_ghostty() {
    local identity=$1
    # Ghostty's class is a single GTK application ID, including on Wayland.
    # Keep this namespace in sync with parity-wm.toml and parity-rules.toml.
    ghostty \
        --config-file="$FIXTURES/ghostty.conf" \
        --config-default-files=false \
        --gtk-single-instance=false \
        --window-decoration=false \
        --class="org.aqueous.test.$identity" \
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
        "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -log-level debug "${args[@]}" -c true \
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

    n=0
    while [ "$n" -lt 160 ]; do
        if ! kill -0 "$COMPOSITOR_PID" 2>/dev/null; then
            tail -80 "$SESSION_LOG" >&2
            die "compositor exited before the first $label frame"
        fi
        [ -n "$(trace_line || true)" ] && return 0
        sleep 0.05
        n=$((n + 1))
    done
    die "$label did not complete its first frame"
}

exercise_session() {
    local baseline focus0 focus1 focus2 return_focus cycle_focus geom1 geom2 geom_moved geom_mono ws1 ws2 moved_geom fullscreen_geom manual_geom closed_geom game_pid fallback_geom dwindle_after_fallback tile_after_fallback legacy_list info_json rule_snippet

    baseline=$(trace_line)
    focus0=$(trace_field "$baseline" focus)
    ws1=$(trace_field "$baseline" workspace)

    echo "CHECK: real Ghostty mapping and pointer focus"
    launch_ghostty aq-parity-one
    wait_windows 1
    legacy_list=$(wait_toplevel_title aq-parity-one) || die "wlrctl did not enumerate the mapped window"
    info_json=$("$AQUEOUSCTL_BIN" windows --json)
    jq -e 'length == 1 and .[0].backend == "xdg" and
        .[0].app_id == "org.aqueous.test.aq-parity-one" and .[0].workspace == 1' \
        <<<"$info_json" >/dev/null || die "unexpected fixture app_id or workspace: $info_json"
    rule_snippet=$("$AQUEOUSCTL_BIN" inspect --rule)
    grep -Fxq 'app_id = "org.aqueous.test.aq-parity-one"' <<<"$rule_snippet" || die "aqueousctl did not generate a usable rule"
    wlrctl pointer move 300 300
    wait_field_ne focus "$focus0"
    focus1=$(trace_field "$(trace_line)" focus)
    geom1=$(trace_field "$(trace_line)" geometry)
    checkpoint one_window_focused
    # Keep subsequent resize/layout changes from moving a window under the
    # pointer and unintentionally changing keyboard focus during assertions.
    wlrctl pointer move -10000 -10000

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

    echo "CHECK: shifted-arrow spatial window swap"
    press Left SHIFT,SUPER
    wait_field_ne geometry "$geom2"
    geom_moved=$(trace_field "$(trace_line)" geometry)
    checkpoint shifted_arrow_window_swap
    [ "$geom_moved" != "$geom2" ] || die "Super+Shift+Left did not move the focused tiled window"
    geom2=$geom_moved

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
    "$AQUEOUSCTL_BIN" windows --json | jq -e 'any(.[];
        .app_id == "org.aqueous.test.aq-parity-rule" and .workspace == 2 and
        .matched_rule > 0 and (.states | index("floating")) != null)' >/dev/null ||
        die "floating fixture did not match its application-ID rule"
    checkpoint floating_workspace_rule

    echo "CHECK: fullscreen rule lifecycle and manual override"
    # fullscreen client; a manual toggle must survive a rules reload.
    launch_ghostty aq-parity-fullscreen
    wait_windows 4
    "$AQUEOUSCTL_BIN" windows --json | jq -e 'any(.[];
        .app_id == "org.aqueous.test.aq-parity-fullscreen" and
        .matched_rule > 0 and (.states | index("fullscreen")) != null)' >/dev/null ||
        die "fullscreen fixture did not match its application-ID rule"
    press c SUPER
    wait_field_ne focus "$return_focus"
    cycle_focus=$(trace_field "$(trace_line)" focus)
    press c SUPER
    wait_field_ne focus "$cycle_focus"
    # Cycling tests focus changes, but does not guarantee a particular target.
    focus_fixture aq-parity-fullscreen
    fullscreen_geom=$(trace_field "$(trace_line)" geometry)
    press f SHIFT,SUPER
    wait_field_ne geometry "$fullscreen_geom"
    "$AQUEOUSCTL_BIN" windows --json | jq -e 'any(.[];
        .app_id == "org.aqueous.test.aq-parity-fullscreen" and
        (.states | index("focused")) != null and (.states | index("fullscreen")) == null)' >/dev/null ||
        die "manual override did not unfullscreen the rule-matched fixture"
    manual_geom=$(trace_field "$(trace_line)" geometry)
    checkpoint manual_fullscreen_override
    press r SUPER
    wait_field_eq geometry "$manual_geom"
    "$AQUEOUSCTL_BIN" windows --json | jq -e 'any(.[];
        .app_id == "org.aqueous.test.aq-parity-fullscreen" and
        (.states | index("fullscreen")) == null)' >/dev/null ||
        die "reload lost the fixture's manual fullscreen override"
    checkpoint override_survives_reload

    echo "CHECK: close keybinding"
    focus_fixture aq-parity-fullscreen
    press q SUPER
    wait_windows 3
    "$AQUEOUSCTL_BIN" windows --json | jq -e 'all(.[];
        .app_id != "org.aqueous.test.aq-parity-fullscreen")' >/dev/null ||
        die "close keybinding did not remove the fullscreen fixture"
    closed_geom=$(trace_field "$(trace_line)" geometry)
    checkpoint close_keybinding

    echo "CHECK: game-mode Rows remainder with a real anchor"
    launch_ghostty aq-parity-extra-one
    launch_ghostty aq-parity-extra-two
    launch_ghostty aq-parity-extra-three
    wait_windows 6
    launch_ghostty aq-parity-game
    game_pid=${CLIENT_PIDS[${#CLIENT_PIDS[@]}-1]}
    wait_windows 7
    "$AQUEOUSCTL_BIN" windows --json | jq -e 'any(.[];
        .app_id == "org.aqueous.test.aq-parity-game" and .matched_rule > 0)' >/dev/null ||
        die "game fixture did not match its application-ID rule"
    wait_field_ne geometry "$closed_geom"
    checkpoint game_mode_rows_remainder

    echo "CHECK: game-mode Dwindle fallback after the anchor closes"
    press g SUPER
    kill "$game_pid"
    wait_windows 6
    fallback_geom=$(trace_field "$(trace_line)" geometry)
    checkpoint game_mode_dwindle_fallback
    press d SUPER
    dwindle_after_fallback=$(trace_field "$(trace_line)" geometry)
    [ "$fallback_geom" = "$dwindle_after_fallback" ] || die "game-mode fallback_layout=dwindle does not match the Dwindle engine"
    checkpoint dwindle_matches_game_mode_fallback
    press t SUPER
    tile_after_fallback=$(trace_field "$(trace_line)" geometry)
    [ "$fallback_geom" != "$tile_after_fallback" ] || die "Dwindle fallback unexpectedly matches Tile with four tiled windows"
    checkpoint tile_differs_from_game_mode_fallback
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

echo "policy integration passed: Ghostty windows, rules, geometry, focus, repeated workspaces, game-mode Rows and Dwindle fallback ownership, fullscreen overrides, and keybindings"
