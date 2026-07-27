#!/usr/bin/env bash
set -euo pipefail

# Verify that new-window focus is opt-in and independent of pointer focus.
# Each case maps one window, waits for its fallback focus, then maps a second
# window without moving the pointer.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
GHOSTTY_CONFIG="$here/scripts/fixtures/scrolling-viewport-ghostty.conf"

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] ||
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] ||
    die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
[ -r "$GHOSTTY_CONFIG" ] || die "missing Ghostty fixture"
for tool in ghostty jq wlrctl; do
    have "$tool" || die "$tool is required"
done

TEST_ROOT=$(mktemp -d /tmp/aqueous-new-window-focus.XXXXXX)
COMPOSITOR_PID=""
CLIENT_PIDS=()

cleanup_processes() {
    for pid in "${CLIENT_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${CLIENT_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    CLIENT_PIDS=()
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    COMPOSITOR_PID=""
}

cleanup() {
    cleanup_processes
    if [ "${AQUEOUS_KEEP_TEST_OUTPUT:-0}" = 1 ]; then
        echo "test artifacts: $TEST_ROOT" >&2
    else
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT

window_is_focused() {
    local id=$1
    "$AQUEOUSCTL_BIN" windows --json 2>/dev/null |
        jq -e --arg id "$id" \
            'any(.[]; .title == $id and (.states | index("focused") != null))' \
            >/dev/null
}

wait_for_focus() {
    local id=$1
    for _ in $(seq 1 200); do
        window_is_focused "$id" && return 0
        sleep 0.025
    done
    return 1
}

launch_window() {
    local id=$1
    ghostty \
        --config-file="$GHOSTTY_CONFIG" \
        --config-default-files=false \
        --gtk-single-instance=false \
        --window-decoration=false \
        --class="$id,$id" \
        --title="$id" \
        -e sleep 30 >/dev/null 2>&1 &
    CLIENT_PIDS+=("$!")
}

run_case() {
    local label=$1
    local config=$2
    local second_should_focus=$3
    local case_root="$TEST_ROOT/$label"
    local runtime="$case_root/runtime"
    local log="$case_root/compositor.log"
    mkdir -p "$runtime/config" "$case_root/home"
    chmod 700 "$runtime"

    env --default-signal=INT --default-signal=TERM -u LD_PRELOAD \
        WLR_BACKENDS=headless \
        WLR_HEADLESS_OUTPUTS=1 \
        WLR_RENDERER=pixman \
        XDG_RUNTIME_DIR="$runtime" \
        XDG_CONFIG_HOME="$runtime/config" \
        HOME="$case_root/home" \
        AQUEOUS_CONFIG="$config" \
        GDK_BACKEND=wayland \
        "$AQUEOUS_COMPOSITOR_BIN" -no-xwayland -log-level info -c true \
        >"$log" 2>&1 &
    COMPOSITOR_PID=$!

    local socket=""
    for _ in $(seq 1 200); do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
            tail -100 "$log" >&2
            die "$label compositor exited during startup"
        }
        socket=$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
        [ -z "$socket" ] || break
        sleep 0.025
    done
    [ -n "$socket" ] || die "$label compositor did not create a Wayland socket"

    export XDG_RUNTIME_DIR="$runtime"
    export XDG_CONFIG_HOME="$runtime/config"
    export HOME="$case_root/home"
    export WAYLAND_DISPLAY="$socket"
    export GDK_BACKEND=wayland

    # Establish output selection once. No pointer event occurs after either
    # window maps, so focus_follows_mouse cannot satisfy the assertion.
    wlrctl pointer move 100 100

    local first="aq-new-focus-$label-one"
    local second="aq-new-focus-$label-two"
    launch_window "$first"
    for _ in $(seq 1 200); do
        [ "$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null | jq 'length')" = 1 ] && break
        sleep 0.025
    done
    [ "$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null | jq 'length')" = 1 ] ||
        die "$label first window did not map"
    wait_for_focus "$first" || {
        tail -100 "$log" >&2
        die "$label first window did not receive fallback focus: $("$AQUEOUSCTL_BIN" windows --json 2>/dev/null | jq -c .)"
    }

    launch_window "$second"
    for _ in $(seq 1 200); do
        [ "$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null | jq 'length')" = 2 ] && break
        sleep 0.025
    done
    [ "$("$AQUEOUSCTL_BIN" windows --json 2>/dev/null | jq 'length')" = 2 ] ||
        die "$label second window did not map"

    if [ "$second_should_focus" = true ]; then
        wait_for_focus "$second" || {
            tail -100 "$log" >&2
            die "$label enabled policy did not focus the second window"
        }
    else
        sleep 0.2
        window_is_focused "$first" ||
            die "$label disabled policy did not preserve first-window focus"
        ! window_is_focused "$second" ||
            die "$label disabled policy focused the second window"
    fi

    cleanup_processes
}

run_case \
    default-off \
    "$here/scripts/fixtures/new-window-focus-off-wm.toml" \
    false
run_case \
    enabled \
    "$here/scripts/fixtures/new-window-focus-on-wm.toml" \
    true

echo "PASS: new-window focus is disabled by default and focuses the newest window when enabled"
