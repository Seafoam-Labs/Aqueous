#!/usr/bin/env bash
set -euo pipefail

# Pixel-accurate validation for a cursor selected by an X11 application. Runs
# both XWayland coordinate policies because cursor scaling must not depend on
# whether application windows use legacy or native scaling.

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
FIXTURE_SOURCE="$here/scripts/fixtures/xwayland-cursor-scale.c"
KEEP_ARTIFACTS=${AQUEOUS_SCALING_KEEP_ARTIFACTS:-0}

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] || \
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN (build with: zig build -Dxwayland)"
[ -r "$FIXTURE_SOURCE" ] || die "missing XWayland cursor fixture"
for tool in cc grim jq magick nc pkg-config wlrctl Xwayland; do
    have "$tool" || die "$tool is required for XWayland cursor scaling tests"
done
pkg-config --exists x11 xcursor || die "X11 and Xcursor development files are required"
[[ "$KEEP_ARTIFACTS" = 0 || "$KEEP_ARTIFACTS" = 1 ]] || \
    die "AQUEOUS_SCALING_KEEP_ARTIFACTS must be 0 or 1"

TEST_ROOT=$(mktemp -d /tmp/aqueous-xwayland-cursor-scale.XXXXXX)
FIXTURE_BIN="$TEST_ROOT/xwayland-cursor-scale"
COMPOSITOR_PID=""

cleanup_session() {
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    COMPOSITOR_PID=""
}
cleanup() {
    cleanup_session
    if [ "$KEEP_ARTIFACTS" = 1 ]; then
        echo "XWayland cursor scaling artifacts: $TEST_ROOT"
    else
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT

cc -std=c11 -Wall -Wextra -Werror -O2 "$FIXTURE_SOURCE" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs x11 xcursor)

run_mode() {
    local mode=$1
    local runtime="$TEST_ROOT/$mode-runtime"
    local compositor_log="$TEST_ROOT/$mode-compositor.log"
    local client_log="$TEST_ROOT/$mode-client.log"
    local socket="" output_name="" response extent
    mkdir -p "$runtime/config" "$runtime/home"
    chmod 700 "$runtime"

    WLR_BACKENDS=headless \
    WLR_HEADLESS_OUTPUTS=1 \
    WLR_RENDERER=pixman \
    XDG_RUNTIME_DIR="$runtime" \
    XDG_CONFIG_HOME="$runtime/config" \
    HOME="$runtime/home" \
        "$AQUEOUS_COMPOSITOR_BIN" -policy internal -log-level debug \
        -xwayland-scaling "$mode" \
        -c "$FIXTURE_BIN >$client_log 2>&1" \
        >"$compositor_log" 2>&1 &
    COMPOSITOR_PID=$!

    for _ in $(seq 1 240); do
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
            tail -120 "$compositor_log" >&2
            die "$mode compositor failed during startup"
        }
        socket=$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
        [ -n "$socket" ] && break
        sleep 0.05
    done
    [ -n "$socket" ] || die "$mode compositor did not create a Wayland socket"

    local output_socket="$runtime/aqueous/outputd.sock"
    output_request() { printf '%s\n' "$1" | nc -U -q 1 "$output_socket" 2>/dev/null | head -1; }
    for _ in $(seq 1 240); do
        output_name=$(output_request '{"op":"list"}' | jq -r '.outputs[0].name // empty' 2>/dev/null || true)
        grep -Fq 'READY cursor=24x24' "$client_log" 2>/dev/null && [ -n "$output_name" ] && break
        sleep 0.05
    done
    if ! grep -Fq 'READY cursor=24x24' "$client_log" 2>/dev/null; then
        tail -120 "$compositor_log" >&2
        cat "$client_log" >&2 || true
        die "XWayland fixture did not start in $mode mode; verify the compositor was built with -Dxwayland"
    fi

    local client_env=(env XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$socket")
    "${client_env[@]}" wlrctl pointer move -10000 -10000
    "${client_env[@]}" wlrctl pointer move 200 200
    sleep 0.2

    capture_extent() {
        local scale=$1 expected=$2 label=$3
        local plain="$TEST_ROOT/$mode-$label-plain.png"
        local cursor="$TEST_ROOT/$mode-$label-cursor.png"
        response=$(output_request "{\"op\":\"set\",\"changes\":[{\"name\":\"$output_name\",\"scale\":$scale}]}")
        jq -e '.ok == true' >/dev/null <<<"$response" || \
            die "$mode mode rejected scale $scale: $response"
        sleep 0.2
        "${client_env[@]}" grim -s "$scale" -o "$output_name" "$plain"
        "${client_env[@]}" grim -s "$scale" -c -o "$output_name" "$cursor"
        extent=$(magick "$plain" "$cursor" -compose difference -composite \
            -alpha off -colorspace gray -threshold 50% -trim -format '%wx%h' info:)
        [ "$extent" = "${expected}x${expected}" ] || \
            die "$mode XWayland cursor rendered $extent at ${scale}x; expected ${expected}x${expected}"
        pass "$mode XWayland cursor rendered ${extent} at ${scale}x"
    }

    capture_extent 1 24 100
    capture_extent 1.25 30 125
    capture_extent 1.5 36 150
    capture_extent 2 48 200
    capture_extent 2.5 60 250
    capture_extent 3 72 300
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || die "$mode compositor exited during cursor checks"
    cleanup_session
}

run_mode legacy
run_mode native
echo "ALL XWAYLAND CURSOR SCALING CHECKS PASSED"
