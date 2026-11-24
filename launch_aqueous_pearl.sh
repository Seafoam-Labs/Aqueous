#!/bin/bash
# Launches an in-tree Aqueous session with the *development* Pearl shell built
# from the sibling Pearl repository (../pearl by default), instead of the
# installed pearl/pearl-git package used by launch_aqueous.sh.
#
# Logs:
#   /tmp/aqueous.log     – Aqueous compositor/policy log
#   /tmp/pearl.log       – Pearl stdout/stderr
#
# Env:
#   PEARL_DIR            Pearl source repository (default: ../pearl next to
#                        this repo). Must contain build.zig.
#   PEARL_OPTIMIZE       Zig optimize mode for the Pearl build (default: safe).
#   AQUEOUS_PEARL_CMD    Override the shell command entirely; skips the Pearl
#                        build (same contract as launch_aqueous.sh).
#   AQUEOUS_DEV_SSD=1    Opt-in: run the session with a private wm.toml that
#                        selects [decoration] renderer = "shell", so Pearl
#                        draws server-side titlebars. Ignored when
#                        AQUEOUS_CONFIG is already set.
#   AQUEOUS_COMPOSITOR_BIN / AQUEOUS_OPTIMIZE / AQUEOUS_LOG_SINK /
#   AQUEOUS_PEARL_LOG_SINK behave exactly as in launch_aqueous.sh.
set -euo pipefail

fail() { echo "[launch_aqueous_pearl] $*" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"

# Build and select the development Pearl binary. An explicit AQUEOUS_PEARL_CMD
# wins and skips the build, matching the installed-shell script's contract.
if [ -z "${AQUEOUS_PEARL_CMD:-}" ]; then
    PEARL_DIR="${PEARL_DIR:-$HERE/../pearl}"
    [ -f "$PEARL_DIR/build.zig" ] || fail "Pearl sources not found at $PEARL_DIR. Set PEARL_DIR to the Pearl repository."
    PEARL_DIR="$(cd "$PEARL_DIR" && pwd)"
    PEARL_BIN="$PEARL_DIR/zig-out/bin/pearl"
    command -v zig >/dev/null 2>&1 || fail 'zig not found in PATH. Install zig >= 0.17.0 to build Pearl.'

    needs_build=0
    if [ ! -x "$PEARL_BIN" ]; then
        needs_build=1
    else
        # Rebuild when the build recipe or any Pearl source/protocol/resource
        # is newer than the binary. Ignore caches and generated output.
        if [ "$PEARL_DIR/build.zig" -nt "$PEARL_BIN" ] ||
            [ "$PEARL_DIR/build.zig.zon" -nt "$PEARL_BIN" ] ||
            [ -n "$(find "$PEARL_DIR/src" "$PEARL_DIR/bindings" "$PEARL_DIR/resources" \
                \( -name .zig-cache -o -name zig-out -o -name .cache \) -prune -o \
                -type f -newer "$PEARL_BIN" -print -quit)" ]; then
            needs_build=1
        fi
    fi
    if [ "$needs_build" = "1" ]; then
        echo "[launch_aqueous_pearl] Building development Pearl in $PEARL_DIR..."
        (
            cd "$PEARL_DIR"
            export ZIG_GLOBAL_CACHE_DIR="$PEARL_DIR/.cache/zig"
            zig build -Doptimize="${PEARL_OPTIMIZE:-safe}"
        )
    fi
    [ -x "$PEARL_BIN" ] || fail "Pearl build produced no binary at $PEARL_BIN"
    AQUEOUS_PEARL_CMD="exec '$PEARL_BIN'"
    echo "[launch_aqueous_pearl] Using development Pearl: $PEARL_BIN"
fi
export AQUEOUS_PEARL_CMD

# Ensure Aqueous is available. Prefer an explicit override, then the
# locally-built ./bin/aqueous (built from compositor/ in this repo).
LOCAL_COMPOSITOR="$HERE/bin/aqueous"
if [ -n "${AQUEOUS_COMPOSITOR_BIN:-}" ]; then
    [ -x "$AQUEOUS_COMPOSITOR_BIN" ] || fail "Compositor is not executable: $AQUEOUS_COMPOSITOR_BIN"
    COMPOSITOR_BIN="$AQUEOUS_COMPOSITOR_BIN"
else
    needs_build=0
    if [ ! -x "$LOCAL_COMPOSITOR" ] || [ ! -f "$HERE/lib/aqueous/libwlroots-0.20.so" ]; then
        needs_build=1
    else
        # Include native sources, protocols and dependency patches. Ignore
        # generated output and caches when deciding whether staging is stale.
        if [ "$HERE/scripts/build-compositor.sh" -nt "$LOCAL_COMPOSITOR" ] ||
            [ -n "$(find "$HERE/compositor" "$HERE/settingsApplication" \
                \( -name .deps -o -name .zig-cache -o -name zig-out \) -prune -o \
                -type f \( -name '*.zig' -o -name '*.zon' -o -name '*.c' -o -name '*.h' \
                    -o -name '*.xml' -o -name '*.patch' -o -name '*.sh' \) \
                -newer "$LOCAL_COMPOSITOR" -print -quit)" ]; then
            needs_build=1
        fi
    fi
    if [ "$needs_build" = "1" ]; then
        echo "[launch_aqueous_pearl] Building in-tree Aqueous from compositor/..."
        AQUEOUS_OPTIMIZE="${AQUEOUS_OPTIMIZE:-debug}" "$HERE/scripts/build-compositor.sh"
    fi
    COMPOSITOR_BIN="$LOCAL_COMPOSITOR"
fi
COMPOSITOR_BIN="$(readlink -f -- "$COMPOSITOR_BIN")"
echo "[launch_aqueous_pearl] Using compositor: $COMPOSITOR_BIN"

# Keep control commands and wlroots paired with the selected compositor. The
# host session may export LD_LIBRARY_PATH pointing at an older installed build.
COMPOSITOR_DIR="$(dirname -- "$COMPOSITOR_BIN")"
export PATH="$COMPOSITOR_DIR:$PATH"
if [ -f "$COMPOSITOR_DIR/../lib/aqueous/libwlroots-0.20.so" ]; then
    export LD_LIBRARY_PATH="$COMPOSITOR_DIR/../lib/aqueous${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Detect "nested" run: if a host Wayland/X session is already visible, fall
# back to Alt for Aqueous bindings so drag-to-move / resize still work
# while developing from Rider. On a real TTY we keep Super.
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
    export AQUEOUS_MOD="Alt"
    export AQUEOUS_NESTED=1
else
    export AQUEOUS_MOD="Super"
    export AQUEOUS_NESTED=0
fi
echo "[launch_aqueous_pearl] AQUEOUS_NESTED=$AQUEOUS_NESTED AQUEOUS_MOD=$AQUEOUS_MOD"

# Pearl validates the desktop identity as well as the compositor's live IPC
# endpoint. These exports affect only this session and its children.
export XDG_CURRENT_DESKTOP=Aqueous
export XDG_SESSION_DESKTOP=aqueous
export XDG_SESSION_TYPE=wayland

# Aqueous creates XWayland through wlroots and exports its allocated DISPLAY
# to the session init command and all compositor-spawned children. Preserve a
# host DISPLAY here only when it is needed to run Aqueous nested on an X11
# backend; never guess :0 for the inner session.
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
export GDK_BACKEND="${GDK_BACKEND:-wayland,x11}"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland,x11}"
export MOZ_ENABLE_WAYLAND="${MOZ_ENABLE_WAYLAND:-1}"
export _JAVA_AWT_WM_NONREPARENTING=1

# Opt-in shell-drawn SSD session config for decoration development. Only when
# the caller has not selected their own configuration.
if [ "${AQUEOUS_DEV_SSD:-0}" = "1" ] && [ -z "${AQUEOUS_CONFIG:-}" ]; then
    AQUEOUS_CONFIG="/tmp/aqueous-pearl-dev-wm.toml"
    cat >"$AQUEOUS_CONFIG" <<'EOF'
# Generated by launch_aqueous_pearl.sh (AQUEOUS_DEV_SSD=1).
[decoration]
renderer = "shell"
EOF
    export AQUEOUS_CONFIG
    echo "[launch_aqueous_pearl] Shell SSD dev config -> $AQUEOUS_CONFIG"
fi

# Decide where Aqueous logs go.
if [ -n "${AQUEOUS_LOG_SINK:-}" ]; then
    AQ_SINK="$AQUEOUS_LOG_SINK"
else
    AQ_SINK="/tmp/aqueous.log"
fi
echo "[launch_aqueous_pearl] Aqueous logs -> $AQ_SINK"
# Aqueous runs -c through sh after exporting the inner WAYLAND_DISPLAY and
# AQUEOUS_SOCKET. Pass the command through the environment to preserve quoting
# and arguments in overrides. Pearl connects using this live environment.
export AQUEOUS_PEARL_LOG_SINK="${AQUEOUS_PEARL_LOG_SINK:-/tmp/pearl.log}"
echo "[launch_aqueous_pearl] Pearl command: $AQUEOUS_PEARL_CMD"
echo "[launch_aqueous_pearl] Pearl logs -> $AQUEOUS_PEARL_LOG_SINK"
exec "$COMPOSITOR_BIN" -log-level debug \
    -c 'exec sh -c "$AQUEOUS_PEARL_CMD" >"$AQUEOUS_PEARL_LOG_SINK" 2>&1' >"$AQ_SINK" 2>&1