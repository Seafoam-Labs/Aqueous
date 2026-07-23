#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
AQUEOUS_COMPOSITOR_BIN=${AQUEOUS_COMPOSITOR_BIN:-"$here/zig-out/bin/aqueous"}
AQUEOUSCTL_BIN=${AQUEOUSCTL_BIN:-"$here/zig-out/bin/aqueousctl"}
FIXTURE_SOURCE="$here/scripts/fixtures/visual-effects-reference.c"
WM_CONFIG="$here/scripts/fixtures/visual-effects-wm.toml"
RULES_CONFIG="$here/scripts/fixtures/visual-effects-rules.toml"
CAPTURE_MODES=${AQUEOUS_BASELINE_MODES:-"1920x1080 2560x1440 3840x2160"}
SAMPLE_COUNT=${AQUEOUS_BASELINE_SAMPLES:-12}
CAPTURE_BACKEND=${AQUEOUS_BASELINE_BACKEND:-auto}

die() { echo "FAIL: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$#" -le 1 ] || die "usage: $0 [OUTPUT_DIRECTORY]"
if [ "$#" -eq 1 ]; then
    ARTIFACT_DIR=$(readlink -m "$1")
else
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    ARTIFACT_DIR="$here/baselines/effects-$timestamp"
fi

[ -x "$AQUEOUS_COMPOSITOR_BIN" ] ||
    die "aqueous binary not found at $AQUEOUS_COMPOSITOR_BIN"
[ -x "$AQUEOUSCTL_BIN" ] ||
    die "aqueousctl binary not found at $AQUEOUSCTL_BIN"
[ -r "$FIXTURE_SOURCE" ] || die "missing visual reference fixture"
[ -r "$WM_CONFIG" ] || die "missing visual reference compositor configuration"
[ -r "$RULES_CONFIG" ] || die "missing visual reference rules"
[[ "$SAMPLE_COUNT" =~ ^[1-9][0-9]*$ ]] ||
    die "AQUEOUS_BASELINE_SAMPLES must be a positive integer"
for tool in cc date grim jq ldd magick nc pkg-config readlink sha256sum wayland-scanner; do
    have "$tool" || die "$tool is required"
done
pkg-config --exists wayland-client wayland-protocols ||
    die "Wayland client development files and protocols are required"
ldd "$AQUEOUS_COMPOSITOR_BIN" | grep -q 'scenefx' ||
    die "the compositor binary is not linked with SceneFX"

mkdir -p "$ARTIFACT_DIR"
[ -z "$(find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    die "output directory is not empty: $ARTIFACT_DIR"

TEST_ROOT=$(mktemp -d /tmp/aqueous-effects-baseline.XXXXXX)
RUNTIME_DIR="$TEST_ROOT/runtime"
SANDBOX_HOME="$TEST_ROOT/user-home"
FIXTURE_BIN="$TEST_ROOT/visual-effects-reference"
COMPOSITOR_LOG="$ARTIFACT_DIR/compositor.log"
CLIENT_LOG_DIR="$ARTIFACT_DIR/clients"
COMPOSITOR_PID=""
CLIENT_PIDS=()

stop_processes() {
    for pid in "${CLIENT_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    CLIENT_PIDS=()
    [ -z "$COMPOSITOR_PID" ] || kill "$COMPOSITOR_PID" 2>/dev/null || true
    [ -z "$COMPOSITOR_PID" ] || wait "$COMPOSITOR_PID" 2>/dev/null || true
    COMPOSITOR_PID=""
}

cleanup() {
    stop_processes
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$RUNTIME_DIR/config" "$SANDBOX_HOME" "$CLIENT_LOG_DIR"
chmod 700 "$RUNTIME_DIR"

BACKEND_ENV=()
if [ "$CAPTURE_BACKEND" = auto ]; then
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] &&
        [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
        CAPTURE_BACKEND=wayland
    else
        CAPTURE_BACKEND=headless
    fi
fi
case "$CAPTURE_BACKEND" in
    wayland)
        HOST_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}
        HOST_WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
        [ -n "$HOST_RUNTIME_DIR" ] && [ -n "$HOST_WAYLAND_DISPLAY" ] ||
            die "the wayland backend requires XDG_RUNTIME_DIR and WAYLAND_DISPLAY"
        [ -S "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ] ||
            die "parent Wayland socket is unavailable"
        ln -s "$HOST_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" \
            "$RUNTIME_DIR/aqueous-baseline-host"
        BACKEND_ENV=(
            WLR_BACKENDS=wayland
            WLR_WL_OUTPUTS=1
            WAYLAND_DISPLAY=aqueous-baseline-host
        )
        ;;
    headless)
        BACKEND_ENV=(
            WLR_BACKENDS=headless
            WLR_HEADLESS_OUTPUTS=1
        )
        ;;
    *)
        die "AQUEOUS_BASELINE_BACKEND must be auto, wayland, or headless"
        ;;
esac

XDG_SHELL_PROTOCOL="$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml"
wayland-scanner client-header "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-client-protocol.h"
wayland-scanner private-code "$XDG_SHELL_PROTOCOL" \
    "$TEST_ROOT/xdg-shell-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -O2 -I"$TEST_ROOT" \
    "$FIXTURE_SOURCE" "$TEST_ROOT/xdg-shell-protocol.c" \
    -o "$FIXTURE_BIN" $(pkg-config --cflags --libs wayland-client)

env -u LD_PRELOAD \
    "${BACKEND_ENV[@]}" \
    AQUEOUS_RENDER_METRICS=1 \
    AQUEOUS_CONFIG="$WM_CONFIG" \
    AQUEOUS_RULES="$RULES_CONFIG" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_CONFIG_HOME="$RUNTIME_DIR/config" \
    HOME="$SANDBOX_HOME" \
    "$AQUEOUS_COMPOSITOR_BIN" \
        -no-xwayland -policy internal -log-level info -c true \
        >"$COMPOSITOR_LOG" 2>&1 &
COMPOSITOR_PID=$!

socket=""
for _ in $(seq 1 200); do
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || {
        tail -120 "$COMPOSITOR_LOG" >&2
        die "compositor failed during startup"
    }
    socket=$(find "$RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [ -z "$socket" ] || break
    sleep 0.05
done
[ -n "$socket" ] || die "compositor did not create a Wayland socket"

OUTPUT_SOCKET="$RUNTIME_DIR/aqueous/outputd.sock"
for _ in $(seq 1 200); do
    [ -S "$OUTPUT_SOCKET" ] && break
    sleep 0.05
done
[ -S "$OUTPUT_SOCKET" ] || die "output service did not create its socket"

output_request() {
    printf '%s\n' "$1" | nc -U -N -w 3 "$OUTPUT_SOCKET" 2>/dev/null | head -1
}

output_state=$(output_request '{"op":"list"}')
OUTPUT_NAME=$(jq -r '.outputs[0].name // empty' <<<"$output_state")
[ -n "$OUTPUT_NAME" ] || die "headless output was not reported"

set_mode() {
    local mode=$1 width height response
    width=${mode%x*}
    height=${mode#*x}
    [[ "$width" =~ ^[1-9][0-9]*$ && "$height" =~ ^[1-9][0-9]*$ ]] ||
        die "invalid capture mode: $mode"
    response=$(output_request \
        "{\"op\":\"set\",\"changes\":[{\"name\":\"$OUTPUT_NAME\",\"mode\":\"$mode\"}]}")
    jq -e '.ok == true' >/dev/null <<<"$response" ||
        die "output service rejected mode $mode: $response"
    for _ in $(seq 1 200); do
        output_state=$(output_request '{"op":"list"}')
        if jq -e \
            --argjson width "$width" \
            --argjson height "$height" \
            '.outputs[0].current_mode.width == $width and
             .outputs[0].current_mode.height == $height' \
            >/dev/null <<<"$output_state"; then
            return
        fi
        sleep 0.05
    done
    die "output did not settle at $mode"
}

FIRST_MODE=${CAPTURE_MODES%% *}
set_mode "$FIRST_MODE"

for role in background blur alpha; do
    ready="$TEST_ROOT/$role.ready"
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        "$FIXTURE_BIN" "$role" "$ready" \
        >"$CLIENT_LOG_DIR/$role.log" 2>&1 &
    CLIENT_PIDS+=("$!")
    for _ in $(seq 1 200); do
        [ -f "$ready" ] && break
        kill -0 "${CLIENT_PIDS[-1]}" 2>/dev/null || {
            cat "$CLIENT_LOG_DIR/$role.log" >&2
            die "$role fixture exited before mapping"
        }
        sleep 0.05
    done
    [ -f "$ready" ] || die "$role fixture did not map"
done

windows_json="[]"
for _ in $(seq 1 200); do
    windows_json=$(env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        "$AQUEOUSCTL_BIN" windows --json 2>/dev/null || echo '[]')
    [ "$(jq 'length' <<<"$windows_json")" = 3 ] && break
    sleep 0.05
done
[ "$(jq 'length' <<<"$windows_json")" = 3 ] ||
    die "the three reference windows were not enumerated"
jq . <<<"$windows_json" >"$ARTIFACT_DIR/windows.json"

printf 'mode\tcpu_samples\tcpu_minimum_ns\tcpu_average_ns\tcpu_maximum_ns\tgpu_samples\tgpu_minimum_ns\tgpu_average_ns\tgpu_maximum_ns\n' \
    >"$ARTIFACT_DIR/render-summary.tsv"

for mode in $CAPTURE_MODES; do
    set_mode "$mode"
    sleep 0.25
    first_log_line=$(wc -l <"$COMPOSITOR_LOG")
    warmup="$TEST_ROOT/warmup.png"
    for _ in $(seq 1 "$SAMPLE_COUNT"); do
        env -u LD_PRELOAD \
            XDG_RUNTIME_DIR="$RUNTIME_DIR" \
            WAYLAND_DISPLAY="$socket" \
            grim -o "$OUTPUT_NAME" "$warmup"
    done
    shot="$ARTIFACT_DIR/reference-$mode.png"
    env -u LD_PRELOAD \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$socket" \
        grim -o "$OUTPUT_NAME" "$shot"
    sleep 0.1
    last_log_line=$(wc -l <"$COMPOSITOR_LOG")
    metrics="$ARTIFACT_DIR/render-$mode.log"
    sed -n "$((first_log_line + 1)),${last_log_line}p" "$COMPOSITOR_LOG" \
        | grep 'render-metric' >"$metrics" || true
    awk -v mode="$mode" '
        /kind=scene/ {
            cpu = -1
            gpu = -1
            for (field_index = 1; field_index <= NF; field_index++) {
                if ($field_index ~ /^duration_ns=/) {
                    split($field_index, pair, "=")
                    gpu = pair[2] + 0
                }
                if ($field_index ~ /^pre_render_ns=/) {
                    split($field_index, pair, "=")
                    cpu = pair[2] + 0
                }
            }
            if (cpu >= 0) {
                if (cpu_samples == 0 || cpu < cpu_minimum) cpu_minimum = cpu
                if (cpu_samples == 0 || cpu > cpu_maximum) cpu_maximum = cpu
                cpu_total += cpu
                cpu_samples++
            }
            if (gpu >= 0) {
                if (gpu_samples == 0 || gpu < gpu_minimum) gpu_minimum = gpu
                if (gpu_samples == 0 || gpu > gpu_maximum) gpu_maximum = gpu
                gpu_total += gpu
                gpu_samples++
            }
        }
        END {
            cpu_average = cpu_samples > 0 ? cpu_total / cpu_samples : -1
            cpu_minimum = cpu_samples > 0 ? cpu_minimum : -1
            cpu_maximum = cpu_samples > 0 ? cpu_maximum : -1
            gpu_average = gpu_samples > 0 ? gpu_total / gpu_samples : -1
            gpu_minimum = gpu_samples > 0 ? gpu_minimum : -1
            gpu_maximum = gpu_samples > 0 ? gpu_maximum : -1
            printf "%s\t%d\t%d\t%.0f\t%d\t%d\t%d\t%.0f\t%d\n",
                mode,
                cpu_samples, cpu_minimum, cpu_average, cpu_maximum,
                gpu_samples, gpu_minimum, gpu_average, gpu_maximum
        }
    ' "$metrics" >>"$ARTIFACT_DIR/render-summary.tsv"
    output_request '{"op":"list"}' | jq . >"$ARTIFACT_DIR/output-$mode.json"
    magick identify "$shot" >"$ARTIFACT_DIR/image-$mode.txt"
    magick "$shot" -alpha on \
        -format 'mean_r=%[fx:mean.r]\nmean_g=%[fx:mean.g]\nmean_b=%[fx:mean.b]\nmean_a=%[fx:mean.a]\n' \
        info: >>"$ARTIFACT_DIR/image-$mode.txt"
done

{
    printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'git_commit=%s\n' "$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'aqueous=%s\n' "$("$AQUEOUS_COMPOSITOR_BIN" -version 2>/dev/null || echo unknown)"
    printf 'zig=%s\n' "$(zig version 2>/dev/null || echo unavailable)"
    printf 'wlroots=%s\n' "$(pkg-config --modversion wlroots-0.20 2>/dev/null || echo unavailable)"
    printf 'scenefx=%s\n' "$(pkg-config --modversion scenefx-0.5 2>/dev/null || echo unavailable)"
    printf 'wayland=%s\n' "$(pkg-config --modversion wayland-server 2>/dev/null || echo unavailable)"
    printf 'kernel=%s\n' "$(uname -srmo)"
    printf 'capture_modes=%s\n' "$CAPTURE_MODES"
    printf 'samples_per_mode=%s\n' "$SAMPLE_COUNT"
    printf 'backend=%s\n' "$CAPTURE_BACKEND"
    printf 'output=%s\n' "$OUTPUT_NAME"
    printf 'binary=%s\n' "$AQUEOUS_COMPOSITOR_BIN"
    printf '\ngit_status:\n'
    git -C "$here" status --short 2>/dev/null || true
    if have vulkaninfo; then
        printf '\nvulkan_summary:\n'
        env -u LD_PRELOAD vulkaninfo --summary 2>/dev/null || true
    fi
} >"$ARTIFACT_DIR/environment.txt"

stop_processes

(
    cd "$ARTIFACT_DIR"
    find . -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 sha256sum
) >"$ARTIFACT_DIR/SHA256SUMS"

echo "effects baseline written to $ARTIFACT_DIR"
