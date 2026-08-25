#!/usr/bin/env bash
set -euo pipefail

# End-to-end regression for X11 _NET_WM_MOVERESIZE requests. The same managed
# XWayland client is exercised as an explicit float, a normal tiled window,
# and a tiled-policy window presented by the floating workspace layout.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/xwayland-floating-request.c"
WM_CONFIG="$here/scripts/fixtures/xwayland-floating-wm.toml"
RULES="$here/scripts/fixtures/xwayland-floating-rules.toml"
VIRTUAL_POINTER_PROTOCOL="$here/protocol/upstream/wlr-virtual-pointer-unstable-v1.xml"
XWAYLAND_SCALING=${AQUEOUS_XWAYLAND_SCALING:-legacy}
POINTER_EXTENT=${AQUEOUS_XWAYLAND_POINTER_EXTENT:-1280x720}
SCALE_NUMERATOR=${AQUEOUS_XWAYLAND_SCALE_NUMERATOR:-1}
SCALE_DENOMINATOR=${AQUEOUS_XWAYLAND_SCALE_DENOMINATOR:-1}

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || \
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN (build with: zig build -Dxwayland)"
[ -x "$AQUEOUSCTL_BIN" ] || die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing XWayland floating fixture"
[ -r "$WM_CONFIG" ] || die "missing XWayland floating WM config"
[ -r "$RULES" ] || die "missing XWayland floating rules"
[ -r "$VIRTUAL_POINTER_PROTOCOL" ] || die "wlr virtual pointer protocol XML is unavailable"
for tool in cc jq pkg-config wayland-scanner Xwayland; do
    have "$tool" || die "$tool is required for XWayland floating integration tests"
done
[[ "$XWAYLAND_SCALING" = legacy || "$XWAYLAND_SCALING" = native ]] ||
    die "AQUEOUS_XWAYLAND_SCALING must be legacy or native"
[[ "$POINTER_EXTENT" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] ||
    die "AQUEOUS_XWAYLAND_POINTER_EXTENT must be WIDTHxHEIGHT"
[[ "$SCALE_NUMERATOR" =~ ^[1-9][0-9]*$ && "$SCALE_DENOMINATOR" =~ ^[1-9][0-9]*$ ]] ||
    die "XWayland test scale numerator and denominator must be positive integers"
POINTER_WIDTH=${POINTER_EXTENT%x*}
POINTER_HEIGHT=${POINTER_EXTENT#*x}
pkg-config --exists x11 wayland-client || \
    die "X11 and Wayland client development files are required"

TEST_ROOT=$(mktemp -d /tmp/aqueous-xwayland-floating.XXXXXX)
FIXTURE_BIN="$TEST_ROOT/xwayland-floating-request"
COMPOSITOR_PID=""
CLIENT_PID=""

cleanup_session() {
    [ -z "$CLIENT_PID" ] || kill "$CLIENT_PID" 2>/dev/null || true
    [ -z "$CLIENT_PID" ] || wait "$CLIENT_PID" 2>/dev/null || true
    CLIENT_PID=""
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    COMPOSITOR_PID=""
}
cleanup() {
    cleanup_session
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

wayland-scanner client-header "$VIRTUAL_POINTER_PROTOCOL" \
    "$TEST_ROOT/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code "$VIRTUAL_POINTER_PROTOCOL" \
    "$TEST_ROOT/wlr-virtual-pointer-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" \
    "$TEST_ROOT/wlr-virtual-pointer-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs x11 wayland-client)

geometry() {
    jq -r '[.geometry.x, .geometry.y, .geometry.width, .geometry.height] | @tsv'
}

run_session() {
    local mode=$1 class=$2
    local runtime="$TEST_ROOT/$mode-runtime"
    local sync_dir="$TEST_ROOT/$mode-sync"
    local compositor_log="$TEST_ROOT/$mode-compositor.log"
    local client_log="$TEST_ROOT/$mode-client.log"
    local socket="" json=""
    mkdir -p "$runtime/config" "$runtime/home" "$sync_dir"
    chmod 700 "$runtime"

    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    WLR_RENDERER=pixman \
    XDG_RUNTIME_DIR="$runtime" \
    XDG_CONFIG_HOME="$runtime/config" \
    HOME="$runtime/home" \
    AQUEOUS_CONFIG="$WM_CONFIG" \
    AQUEOUS_RULES="$RULES" \
        "$AQUEOUS_COMPOSITOR_BIN" -policy internal -log-level debug \
        -xwayland-scaling "$XWAYLAND_SCALING" \
        -c "$FIXTURE_BIN $sync_dir $class >$client_log 2>&1" \
        >"$compositor_log" 2>&1 &
    COMPOSITOR_PID=$!

    for _ in $(seq 1 240); do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
            tail -160 "$compositor_log" >&2 || true
            cat "$client_log" >&2 || true
            die "$mode compositor failed during startup"
        }
        socket=$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
        [ -n "$socket" ] && [ -f "$sync_dir/ready" ] && break
        sleep 0.05
    done
    [ -n "$socket" ] && [ -f "$sync_dir/ready" ] || {
        tail -160 "$compositor_log" >&2 || true
        cat "$client_log" >&2 || true
        die "$mode fixture did not become ready"
    }
    CLIENT_PID=$(pgrep -P "$COMPOSITOR_PID" -f "$FIXTURE_BIN" | head -1 || true)

    window_json() {
        XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$socket" \
            "$AQUEOUSCTL_BIN" windows --json |
            jq -c --arg class "$class" '.[] | select(.class == $class)'
    }
    wait_window() {
        for _ in $(seq 1 200); do
            json=$(window_json)
            [ -n "$json" ] && { printf '%s\n' "$json"; return 0; }
            sleep 0.05
        done
        tail -160 "$compositor_log" >&2 || true
        cat "$client_log" >&2 || true
        die "timed out waiting for $class"
    }
    wait_geometry() {
        local expected=$1 current=""
        for _ in $(seq 1 200); do
            current=$(geometry <<<"$(window_json)")
            [ "$current" = "$expected" ] && return 0
            sleep 0.05
        done
        tail -160 "$compositor_log" >&2 || true
        die "$class geometry was '$current', expected '$expected'"
    }
    wait_geometry_change() {
        local previous=$1 current="" last="" stable=0
        for _ in $(seq 1 200); do
            current=$(geometry <<<"$(window_json)")
            if [ -n "$current" ] && [ "$current" != "$previous" ]; then
                if [ "$current" = "$last" ]; then
                    stable=$((stable + 1))
                else
                    last=$current
                    stable=1
                fi
                if [ "$stable" -ge 3 ]; then
                    printf '%s\n' "$current"
                    return 0
                fi
            fi
            sleep 0.05
        done
        die "$class geometry did not change from '$previous'"
    }
    wait_position() {
        local expected_x=$1 expected_y=$2 current="" current_x current_y
        local last="" stable=0
        for _ in $(seq 1 200); do
            current=$(geometry <<<"$(window_json)")
            read -r current_x current_y _ _ <<<"$current"
            if [ "$current_x" = "$expected_x" ] && [ "$current_y" = "$expected_y" ]; then
                if [ "$current" = "$last" ]; then
                    stable=$((stable + 1))
                else
                    last=$current
                    stable=1
                fi
                if [ "$stable" -ge 3 ]; then
                    printf '%s\n' "$current"
                    return 0
                fi
            fi
            sleep 0.05
        done
        die "$class did not settle at position $expected_x,$expected_y (last geometry '$current')"
    }
    request() {
        local verb=$1 start_x=$2 start_y=$3 end_x=$4 end_y=$5
        rm -f "$sync_dir/done"
        printf '%s %d %d %d %d %d %d\n' \
            "$verb" "$start_x" "$start_y" "$end_x" "$end_y" \
            "$POINTER_WIDTH" "$POINTER_HEIGHT" >"$sync_dir/request"
        for _ in $(seq 1 200); do
            kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "compositor exited during $verb"
            [ -f "$sync_dir/done" ] && return 0
            sleep 0.05
        done
        tail -160 "$compositor_log" >&2 || true
        cat "$client_log" >&2 || true
        die "timed out waiting for $verb"
    }

    local initial initial_x initial_y initial_w initial_h
    initial=$(wait_window)
    read -r initial_x initial_y initial_w initial_h < <(geometry <<<"$initial")

    if [ "$XWAYLAND_SCALING" = native ]; then
        local root_w root_h x11_x x11_y x11_w x11_h
        read -r root_w root_h x11_x x11_y x11_w x11_h <"$sync_dir/x11-state"
        local expected_x expected_y expected_w expected_h
        [ "$root_w" = 1280 ] && [ "$root_h" = 720 ] ||
            die "native X11 root was ${root_w}x${root_h}, expected physical 1280x720"
        for _ in $(seq 1 200); do
            initial=$(window_json)
            read -r initial_x initial_y initial_w initial_h < <(geometry <<<"$initial")
            expected_x=$(((initial_x * SCALE_NUMERATOR + SCALE_DENOMINATOR / 2) / SCALE_DENOMINATOR))
            expected_y=$(((initial_y * SCALE_NUMERATOR + SCALE_DENOMINATOR / 2) / SCALE_DENOMINATOR))
            expected_w=$(((initial_w * SCALE_NUMERATOR + SCALE_DENOMINATOR / 2) / SCALE_DENOMINATOR))
            expected_h=$(((initial_h * SCALE_NUMERATOR + SCALE_DENOMINATOR / 2) / SCALE_DENOMINATOR))
            if [ "$x11_x" = "$expected_x" ] && [ "$x11_y" = "$expected_y" ] &&
                [ "$x11_w" = "$expected_w" ] && [ "$x11_h" = "$expected_h" ]; then
                break
            fi
            sleep 0.05
        done
        [ "$x11_x" = "$expected_x" ] && [ "$x11_y" = "$expected_y" ] &&
            [ "$x11_w" = "$expected_w" ] && [ "$x11_h" = "$expected_h" ] ||
            die "native X11 geometry was $x11_x,$x11_y ${x11_w}x${x11_h}, expected $expected_x,$expected_y ${expected_w}x${expected_h}"
    fi

    if [ "$mode" = explicit ]; then
        jq -e '.states | index("floating") != null' <<<"$initial" >/dev/null ||
            die "explicit XWayland float was not floating"

        # X11 has no Wayland grab serial. A ClientMessage without a real press
        # focused on this top-level must not be able to initiate an operation.
        request move-unpressed \
            $((initial_x + 40)) $((initial_y + 40)) \
            $((initial_x + 100)) $((initial_y + 80))
        sleep 0.1
        wait_geometry "$initial_x"$'\t'"$initial_y"$'\t'"$initial_w"$'\t'"$initial_h"

        request move \
            $((initial_x + 40)) $((initial_y + 40)) \
            $((initial_x + 100)) $((initial_y + 80))
        local moved_x=$((initial_x + 60)) moved_y=$((initial_y + 40))
        wait_geometry "$moved_x"$'\t'"$moved_y"$'\t'"$initial_w"$'\t'"$initial_h"

        request resize-top-left \
            $((moved_x + 40)) $((moved_y + 40)) \
            $((moved_x + 20)) $((moved_y + 25))
        local resized_x=$((moved_x - 20)) resized_y=$((moved_y - 15))
        local resized_w=$((initial_w + 20)) resized_h=$((initial_h + 15))
        wait_geometry "$resized_x"$'\t'"$resized_y"$'\t'"$resized_w"$'\t'"$resized_h"

        # A second operation verifies that button release ended both the seat
        # operation and the policy drag.
        request move \
            $((resized_x + 50)) $((resized_y + 50)) \
            $((resized_x + 65)) $((resized_y + 60))
        wait_geometry "$((resized_x + 15))"$'\t'"$((resized_y + 10))"$'\t'"$resized_w"$'\t'"$resized_h"
    else
        jq -e '(.states | index("floating")) == null and .layout == "tiled"' \
            <<<"$initial" >/dev/null || die "ordinary XWayland window did not start tiled"
        local initial_geometry
        initial_geometry=$(geometry <<<"$initial")

        # A raw Xlib window can map its initial 320x200 pixmap before applying
        # the compositor's first tiled configure. The first interaction also
        # forces the fixture to damage any pending configured pixmap; use the
        # resulting tiled rectangle as the rejection baseline.
        request move \
            $((initial_x + 80)) $((initial_y + 80)) \
            $((initial_x + 140)) $((initial_y + 120))
        sleep 0.1
        local rejected_geometry
        rejected_geometry=$(geometry <<<"$(window_json)")
        initial_geometry=$rejected_geometry
        read -r initial_x initial_y initial_w initial_h <<<"$initial_geometry"
        jq -e '(.states | index("floating")) == null and .layout == "tiled"' \
            <<<"$(window_json)" >/dev/null ||
            die "XWayland move request detached a tiled-policy window"

        request move \
            $((initial_x + 80)) $((initial_y + 80)) \
            $((initial_x + 140)) $((initial_y + 120))
        sleep 0.1
        rejected_geometry=$(geometry <<<"$(window_json)")
        [ "$rejected_geometry" = "$initial_geometry" ] ||
            die "XWayland move request changed tiled geometry from '$initial_geometry' to '$rejected_geometry'"
        request resize-top-left \
            $((initial_x + 80)) $((initial_y + 80)) \
            $((initial_x + 60)) $((initial_y + 65))
        sleep 0.1
        rejected_geometry=$(geometry <<<"$(window_json)")
        [ "$rejected_geometry" = "$initial_geometry" ] ||
            die "XWayland resize request changed tiled geometry from '$initial_geometry' to '$rejected_geometry'"

        XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$socket" \
            "$AQUEOUSCTL_BIN" layout --output HEADLESS-1 --set floating --json >/dev/null
        local floating_geometry floating_x floating_y floating_w floating_h
        floating_geometry=$(wait_geometry_change "$initial_geometry")
        read -r floating_x floating_y floating_w floating_h <<<"$floating_geometry"
        # Position animation snapshots are deliberately input-inert. Wait for
        # the cosmetic transition to finish before starting a client drag.
        sleep 0.6
        jq -e '(.states | index("floating")) == null and .layout == "tiled"' \
            <<<"$(window_json)" >/dev/null ||
            die "floating workspace changed the XWayland window's policy ownership"

        request move \
            $((floating_x + 40)) $((floating_y + 40)) \
            $((floating_x + 100)) $((floating_y + 80))
        local moved_x=$((floating_x + 60)) moved_y=$((floating_y + 40))
        local moved_geometry
        moved_geometry=$(wait_position "$moved_x" "$moved_y")
        read -r _ _ floating_w floating_h <<<"$moved_geometry"

        request resize-bottom-right \
            $((moved_x + floating_w - 40)) $((moved_y + floating_h - 40)) \
            $((moved_x + floating_w - 10)) $((moved_y + floating_h - 15))
        local resized_w=$((floating_w + 30)) resized_h=$((floating_h + 25))
        wait_geometry "$moved_x"$'\t'"$moved_y"$'\t'"$resized_w"$'\t'"$resized_h"
    fi

    touch "$sync_dir/finish"
    for _ in $(seq 1 100); do
        [ -z "$(window_json)" ] && break
        sleep 0.05
    done
    if [ -n "$(window_json)" ]; then
        cat "$client_log" >&2 || true
        die "$mode fixture window did not close"
    fi
    CLIENT_PID=""
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "$mode compositor crashed"
    cleanup_session
}

run_session explicit AqueousXwaylandExplicitFloat
run_session layout AqueousXwaylandLayoutFloat

echo "PASS: $XWAYLAND_SCALING XWayland client move/resize honors explicit and workspace floating policy"
