# Aqueous shell integration verification

The Aqueous implementation of [A1–A6](dms-integration-implementation-plan.md)
was checked with Zig 0.16 and the repository's pinned wlroots render-hook build.
The headless fixture creates private runtime, HOME and configuration directories,
starts two headless outputs, and cleans up its processes. It never connects to
the user's display. Local Wayland socket creation must be permitted.

## Build and unit checks

From `compositor/`, with `.deps/wlroots-render-hook` prepared using the existing
repository build instructions:

```sh
export PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig"
export ZIG_GLOBAL_CACHE_DIR=/tmp/aqueous-shell-zig-global
export ZIG_LOCAL_CACHE_DIR=/tmp/aqueous-shell-zig-local
zig build test -Dxwayland -Doptimize=ReleaseSafe -Dcpu=baseline
zig build -Dxwayland -Doptimize=ReleaseSafe -Dcpu=baseline
```

Result: **393 unit tests passed**, and the normal Vulkan/XWayland build and
manpages compiled. CLI tests cover malformed arguments, batch identity, session
and sequence validation, duplicate entity keys, and coalesced sequence jumps.
The protocol XML, Markdown contract and JSON schema are installed alongside the
existing Aqueous protocol files.

## Isolated native and XWayland regression

The test uses Pixman to avoid requiring a physical renderer. Build a separate
diagnostic binary; run the following from the repository root:

```sh
PKG_CONFIG_PATH="$PWD/compositor/.deps/wlroots-render-hook/lib/pkgconfig" \
ZIG_GLOBAL_CACHE_DIR=/tmp/aqueous-shell-test-global \
ZIG_LOCAL_CACHE_DIR=/tmp/aqueous-shell-test-local \
zig build --build-file compositor/build.zig -Dman-pages=false -Dxwayland \
  -Dvulkan-effects=false -Doptimize=ReleaseSafe -Dcpu=baseline \
  --prefix /tmp/aqueous-shell-test

export AQUEOUS_COMPOSITOR_BIN=/tmp/aqueous-shell-test/bin/aqueous
export AQUEOUSCTL_BIN=/tmp/aqueous-shell-test/bin/aqueousctl
python3 compositor/scripts/test-shell-integration.py
AQUEOUS_SHELL_TEST_XWAYLAND=1 python3 compositor/scripts/test-shell-integration.py
```

Dependencies include a C compiler, `wayland-scanner`, Wayland protocol XMLs,
Wayland/XKB development libraries and `wlr-randr`. The XWayland variant also
needs XWayland and Xlib development files.

Verified coverage:

- Capability discovery, initial state, stable IDs, changing/escaped titles,
  equal-title windows and ext-workspace handle correlation.
- Snapshot/delta sequencing, quiet idle behavior, reconnect snapshots, stale
  IDs and bounded delivery to a client withholding acknowledgements.
- Workspace rename/activation, empty workspace output selection, window
  activation/state/close, move without workspace activation and output movement.
- XDG activation using a token minted by a separate client from a delivered
  keyboard event: background-window focus and keyboard enter, minimized restore,
  workspace/output selection, and rejection of seatless or invalid-serial tokens.
  This exercises `xdg_activation_v1.activate`, independently of shell CLI actions.
- Keyboard layout switching through CLI and client modifier events, two
  independent groups, device/group removal, keymap reload and invalid indices.
- Focus-scoped shortcut inhibition, focus loss/re-entry, inhibitor destruction
  between key press/release, and normal overview bindings afterward.
- Existing overview show/hide, lock/unlock, mutation rejection while locked,
  orderly exit and old `windows`/`outputs` JSON compatibility.
- Four layer-shell frame reservations, usable-area changes and cleanup after
  abrupt client termination.
- Fractional scale and rotation with negative output coordinates in native mode.
  The XWayland variant uses positive coordinates because Aqueous's existing
  XWayland policy rejects negative origins. X11 identity, focus, move, fullscreen
  and graceful close are exercised separately.

An additional diagnostic build with `-Dexternal-policy -Danimations=false`
passed the XWayland fixture without animations. With that build, these probes
verify capability disabling and immediate mutation rejection even without an
external controller:

```sh
AQUEOUS_SHELL_TEST_POLICY=external python3 compositor/scripts/test-shell-integration.py
AQUEOUS_SHELL_TEST_POLICY=compare python3 compositor/scripts/test-shell-integration.py
```

## Configuration and DMS host checks

From the repository root:

```sh
AQUEOUS_PLUGIN_CACHE_ROOT=/tmp/aqueous-helper-shell-check bash plugin/tests/test-all.sh
bash dms-plugin/tests/test-all.sh
DMS_SOURCE=/path/to/pinned/DankMaterialShell \
AQUEOUS_COMPOSITOR_BIN=/tmp/aqueous-shell-test/bin/aqueous \
AQUEOUSCTL_BIN=/tmp/aqueous-shell-test/bin/aqueousctl \
bash dms-plugin/tests/test-host.sh
```

Result: shared helper, Noctalia plugin validation, packaging/init hooks, DMS
helper/packaging checks, 11 DMS draft-model QML tests, and asynchronous helper
client tests passed. Existing validation, stale-generation, mode and
toolkit-adapter regressions continue to pass with helper 0.7.1.

The host checkout was DMS commit `59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`
with common QML commit `26396ce432d6c71c3f5367438f96f4a8d667e160`. Its test
passed eight settings pages, four bar edges, helper Validate/Apply, typography
adaptation and IPC open. A simultaneous shell watch checked live window
lifecycle, session/sequence continuity and atomic workspace/output references.
This uses real DMS QML components with the Aqueous plugin, not the future DMS
core shell adapter or a complete running DMS daemon.

## Remaining release verification

Upstream integration is tracked in [the PR guide](dms-upstream-pr-guide.md).
Before advertising full DMS support, verify the actual upstream consumer with
real monitors and the DMS daemon, physical hotplug and multi-seat input,
suspend/resume, screenshot crop accuracy, PipeWire/browser recording, hardware
DPMS and gamma/HDR. Headless state and action tests do not establish those
hardware or desktop integration properties. The separate portal code was not
changed by this implementation.

## Native background blur

Use `DMS_SOURCE=/path/to/DankMaterialShell python3 compositor/scripts/test-background-effect.py`
with the Vulkan build and its pinned wlroots library. The additional QML fixture
loads the checkout's real `WindowBlur`, `BlurService`, and settings code, with
private runtime/configuration/cache/state directories and inherited DMS sockets
cleared. It checks `dms blur check`, rounded and intersected regions, blur toggle,
and hide/remap against a patterned background. With the repository
`plugin/helper` binary built, it also seeds the marked DMS fallback rules and
verifies that the real service removes only that block, preserves user rules,
and stops rewriting after settling. Normal runs compare cached and
uncached compositor rendering, including application and layer popups, nested
popups, synchronized subsurfaces, policy reload, and all eight output transforms
at fractional scale. Logs, scene dumps, and screenshots are retained.

The Seafoam DMS fork's `Common/AqueousBlur.js` already removes its marked fallback
rule block when it detects native support. Keep user-authored rules intact;
an explicit deny rule still overrides a native request. Global compositor blur
must be enabled independently of the DMS appearance toggle. The CLI's
registry-only probe reports protocol availability, not this runtime setting.
