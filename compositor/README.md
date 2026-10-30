# Aqueous compositor

This directory contains the Zig implementation of Aqueous: a wlroots-based
Wayland compositor with integrated window-management, input, and output policy.

To enable VRR only for fullscreen applications, configure a monitor in
`~/.config/aqueous/outputs.toml`:

```toml
[[output]]
name = "DP-1"
adaptive_sync = true
fullscreen_only_adaptive_sync = true
```

The modifier defaults to false and requires `adaptive_sync = true`. It follows
mapped fullscreen applications on that monitor's active workspace, including
Xwayland windows. Maximized windows and hidden/minimized applications do not
qualify. Focus changes and notifications do not interrupt VRR; overview, session
lock/inactivity and disabled outputs turn the conditional target off. Mirror
destinations still require `adaptive_sync = false`.

Profiles and partial output edits preserve the policy. `aqueousctl outputs
--json` adds `fullscreen_only_adaptive_sync`, `effective_adaptive_sync`,
`actual_vrr` and `adaptive_sync_error`; its existing `adaptive_sync` field keeps
its hardware meaning. The native display model also exposes configured policy
separately. Unsupported or rejected VRR requests retain the preference and the
last usable hardware state; a failed unchanged request is suppressed until a
target, configuration or capability change permits another attempt.

`scripts/test-fullscreen-adaptive-sync.py --compositor BIN --ctl CTL --helper
HELPER --xwayland` exercises policy, persistence, preview Keep/revert and
rejection recovery with two private headless outputs. Build with
`-Doutput-retry-testing=true -Dxwayland=true` for its explicit virtual VRR backend
and Xwayland coverage. These tests
verify state transitions; actual VRR timing, HDR interaction and flicker need
validation on physical displays.

Super + left-click drag moves a window between outputs in every non-stacking
layout (tile, monocle, grid, rows, dwindle, reverse-dwindle, scrolling, game-mode,
and non-stacking composable regions). Entering another output moves the window
to its active workspace, including an empty workspace, while keeping it tiled.
Continue dragging to rearrange it using the destination layout's usual behavior.
Entering a stacking layout completes the tiled gesture; the next drag uses the
stacking layout's freeform movement. The gesture follows the configured primary
modifier if overridden through `AQUEOUS_MOD`.

Run `python3 scripts/test-tiled-output-drag.py` against the diagnostic pixman
build to check output transfers with real pointer events. `--compositor` and
`--ctl` select an alternate build; `--modifier Alt` checks a modifier override.

## Workspace cycling

Dwindle and reverse dwindle stop splitting before windows become unreadable.
Their minimum content width is `max(client minimum, 320, ceil(usable width / 5))`;
minimum height is `max(client minimum, 200, ceil(usable height / 4))`. Dimensions
are logical pixels after output scaling and panel/strut reservations. Borders
and gaps consume additional space. The same checks apply to focused splits.
An output too small for even one minimum-sized window retains one bounded tile.

Overflow moves forward through workspaces on the same output, wrapping once
and counting existing residents. The selected workspace stays active and
dependent dialogs follow their parent. If every workspace lacks room,
workspace 9 switches to scrolling and receives the remaining overflow after
its existing windows. That layout remains until explicitly changed; increasing
available space does not automatically move windows back.

`python3 scripts/test-dwindle-overflow.py --compositor BIN --ctl CTL` checks
19/26-window transitions, dialog transfers, stable workspace membership,
navigation, and the all-workspaces-full fallback in a private headless session.
Use `--renderer vulkan` with the normal build, or a compositor built with
`-Dvulkan-effects=false` for pixman.

Super+Tab and Alt+Tab animate through eligible windows on the initiating seat's
current workspace; Shift reverses the order. `cycle_focus` and
`cycle_focus_reverse` share a stable workspace ring that survives focus changes
and dismissal. New or restored windows append; closed, moved, minimized, and
`skip_switcher` windows leave the ring. Modal parents are skipped in favor of
their active dialog. The stack displays three cards, but every eligible window
is reachable. Escape or 1.5 seconds of inactivity dismisses the stack and keeps
the selected window focused. Reduced motion uses the same selection order.
With `mouse_follows_focus`, the pointer moves into the selected window after
the stack closes; physical pointer input cancels that pending move.

Existing explicit bindings override defaults. To enable both shortcuts in an
existing configuration, set these entries in `[keybinds]`:

```toml
cycle_focus = ["Super+Tab", "Alt+Tab"]
cycle_focus_reverse = ["Super+Shift+Tab", "Alt+Shift+Tab"]
```

`window_switcher_next` and `window_switcher_previous` remain separate, unbound
actions for animated cycling across all workspaces and outputs.

Run `python3 scripts/test-workspace-cycle.py --compositor BIN --ctl CTL` to check
the shipped shortcuts, scope, stable order, animation, and window lifecycle in
a private headless session. Use `--renderer vulkan` with an effects build.

## Building

The toolchain is Zig 0.17.0. Bindings use the upstream Zig 0.17 releases of
zig-wayland (0.7.0), zig-pixman (0.4.0), zig-xkbcommon (0.5.0), and
translate-c (2.0.2). The portal picker uses the upstream zig-gobject
`0.11.0-zig-0.17.0-2026-10-02-38-1` release.

zig-wlroots has no Zig 0.17 release as of this migration. It remains pinned to
upstream v0.20.2. The build copies its sources into the generated build cache
and substitutes the two small MIT-licensed adapters in `build/wlroots-*.zig`:
these import headers generated by translate-c in place of the removed
`@cImport`. No complete dependency project is vendored. Remove these adapters
when upstream provides compatible bindings.

Required development libraries include Wayland, wayland-protocols 1.49 or newer,
libxkbcommon, libinput, libevdev, pixman, libsystemd with PIDFD identity APIs,
Vulkan headers and loader, and the
wlroots 0.20 build dependencies. Zig 0.17 or newer is required; scdoc is
optional for man pages.

```sh
zig build -Doptimize=safe -Dxwayland
zig build test
```

Vulkan effects are enabled by default, borrow wlroots' Vulkan context, require
wlroots' Vulkan renderer at startup, and use the pinned Aqueous wlroots render
hook. `-Dvulkan-effects=false` builds the square/no-blur diagnostic compositor
against the same pinned wlroots dependency. Production builds run integrated
policy by default. For legacy protocol compatibility testing only,
`-Dexternal-policy=true` enables the `external` and `compare` policy modes.

Rounded window content uses one mask aligned with window geometry, shared by
the main surface and its subsurfaces. Client-side shadow padding and buffer
transforms do not move the corners. Animation snapshots preserve the mask, and
overview thumbnails scale it with their content. Rebuild the pinned wlroots
dependency with patch 0033 before building Aqueous: masked single-pixel buffers
must use the texture hook instead of the rectangle shortcut.

Run `python3 scripts/test-rounded-window.py` against an effects build to check
padded/unpadded clients, SHM and single-pixel subsurfaces, buffer transforms,
fullscreen, resizing, overview, workspace snapshot crops, and tiled/scrolling windows.
It covers output scales 1, 1.25, 1.5, and 2 plus rotated/reflected outputs.
Use `--quick` for scale 1 only, `--compositor /path/to/aqueous` for an alternate
build, or `--no-effects --quick` with the diagnostic build. The private headless
sessions require a C compiler, Wayland development files, `wayland-scanner`,
`grim`, and Python/Pillow; logs and screenshots remain in the printed `/tmp`
directory. Selecting an older compositor reproduces issue #92 at the initial
padded-corner assertion.

pointer-warp-v1 is available in both renderer builds, including for sandboxed
applications and optional external/compare policy modes. Focused applications
can request surface-local pointer positions, including while holding a button.
Warps respect pointer locks/confinement and compositor input ownership. This
requires rebuilding the pinned wlroots dependency with patch 0022 before
building Aqueous.

Run `python3 scripts/test-pointer-warp.py --renderer pixman` with the diagnostic
build or `--renderer vulkan` with the effects build. Use `--compositor` and `--ctl`
for an alternate installation prefix, and `--policy external` or `--policy compare`
for the compatibility build. The harness uses private headless sessions and
requires a C compiler, Wayland/xkbcommon development tools, and `wayland-scanner`.
See the [implementation and validation record](../docs/pointer-warp-v1-implementation-plan.md)
for request policy and remaining hardware qualification.

commit-timing-v1 is available in both builds and all policy modes, including for
sandboxed clients. Rebuild the pinned wlroots dependency with patch 0023 before
building Aqueous. With `-Doutput-retry-testing=true`, run
`python3 scripts/test-commit-timing.py --renderer vulkan` (or `--renderer pixman`
for the diagnostic build). The scheduler conservatively holds commits until
their earliest presentation timestamp; predictive scheduling is deferred.
See the [performance and validation record](../docs/commit-timing-v1-performance-results.md)
for the immediate transaction path, bounded snapshot reuse, scheduling changes,
queue/subsurface and explicit-sync checks, and remaining performance/DRM gaps.

FIFO v1 is available in both builds. Private wlroots patch 0039 paces surfaces
with no active, non-suspended output at 40 Hz (one dependent commit per 25 ms).
Visible surfaces return to output-driven pacing when revealed. This is a fixed
FIFO policy, not a universal background FPS cap: clients that omit FIFO waits
are unaffected. Independent acquire synchronization and commit timestamps still
apply. Rebuild and ship the private wlroots library, then restart Aqueous to use
this change; editing or rebuilding only the compositor is insufficient.

The [hidden FIFO implementation record](../docs/hidden-fifo-40hz-plan.md) describes
the timer, regression coverage, and remaining hardware qualification. Run both
`test-fifo.py` and `test-commit-timing.py` to cover hidden pacing and its interaction
with cached locks/timestamps (`--unit-only` runs the protocol fixtures).
After building with
`-Doutput-retry-testing=true`, run `python3 scripts/test-fifo.py --renderer vulkan`
(or `--renderer pixman` for the diagnostic build). See the
[FIFO implementation and validation record](../docs/fifo-v1-implementation-plan.md)
for queue semantics, syncobj remap tests, and remaining hardware qualification.

xdg-toplevel-drag-v1 is available in both builds under integrated policy,
including for security-context clients. Movable windows follow pointer or touch
DnD while underlying windows remain eligible drop targets. Tiled/fixed/fullscreen
move restrictions remain in effect; detached tabs are not automatically floated.
Legacy external-WM mode hides the global.

Build with `-Dtoplevel-drag-testing=true` and run
`python3 scripts/test-xdg-toplevel-drag.py --renderer pixman` against the diagnostic
build, or `--renderer vulkan` against the effects build. See the
[implementation and validation record](../docs/xdg-toplevel-drag-v1-implementation-plan.md)
for lifecycle behavior, tests, and remaining hardware qualification.

The drag fixture also checks rendered pointer/touch icons, ordinary drag-and-drop,
icon destruction during a drag, cancellation, seat removal and client disconnect.
It waits for icon frames and uses `grim` plus Python/Pillow to verify positioning
and removal. Run the Vulkan variant both with and without `--blur`; disabling
blur still exercises scene-owner lookup in the effects render hook. Drag icons
use the same typed scene metadata as other nodes while remaining outside the
interactive tree.

xdg-shell v7 is available in both builds, including suspension and constrained
resize-edge states. Run `python3 scripts/test-xdg-shell-states.py --renderer vulkan`
with the effects build, or use `--renderer pixman` with the diagnostic build.
The fixture starts a private session and checks older clients, hide/resume,
capture, locking, output power, layout edges, and configure sequencing. See the
[implementation record](../docs/xdg-shell-v6-v7-implementation-plan.md) for policy
details and validation limits.

xdg-dialog-v1 is available in both builds, including for security-context
clients. Integrated policy follows modal hints when focusing a parent, preserves
transient natural-size placement, and keeps dialogs above fullscreen parents.
Clients still filter input to their own modal parents. External policy exposes
the protocol but keeps its window manager's focus and placement decisions;
modal metadata is not exported through the legacy external-policy protocol.

Run `python3 scripts/test-xdg-dialog.py --renderer vulkan` with the effects
build, or `--renderer pixman` with the diagnostic build. The private-session
fixture requires a C compiler, `wayland-scanner`, `grim`, Python Pillow, and
Wayland/xkbcommon development libraries. It checks lifecycle/error behavior,
sandboxed clients, immediate hints, nested dialogs, focus cycling, two seats,
locking, exclusive layers, remapping, and fullscreen pixels/hit testing. See the
[implementation record](../docs/xdg-dialog-v1-implementation-plan.md).

Build the pinned dependency before the default build:

```sh
scripts/build-wlroots-render-hook.sh .deps/wlroots-render-hook
PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" \
  zig build \
    -Dexternal-policy=true \
    -Dcpu=baseline \
    -Doptimize=safe
scripts/test-vulkan-render-seam.sh /tmp/aqueous-vulkan-render-seam
scripts/test-color-management-luminance.sh
scripts/test-proton-hdr-color-management.sh
```

The XWayland output projection refresh sends geometry only when the position
or size advertised to that client changes. Ordinary Wayland clients receive
logical geometry through layout updates; window-management transactions do
not resend unchanged xdg-output events. This fixes issue #80 and requires
rebuilding and shipping the patched wlroots library, then restarting Aqueous.
The dependency build checks xdg-output versions 1–3, client isolation, initial
bindings, projection changes, completion events, and resource destruction.
Run those checks separately with `python3 scripts/test-xdg-output.py PREFIX`,
where `PREFIX` is the patched wlroots installation (defaults to
`.deps/wlroots-render-hook`).
To also check active XWayland sessions in both scaling modes, add
`--compositor zig-out/bin/aqueous --ctl zig-out/bin/aqueousctl` (use
`--renderer vulkan` for the effects build). These private two-output sessions
check unchanged layout/window transactions, position, scale, rotation, mode,
rejected configuration, and output reenable with native clients at each
xdg-output version.

The pinned wlroots build includes an 8-bit XRGB shared-memory screencopy path
for 10-bit outputs, allowing clients such as grabit to capture with HDR enabled.
PQ captures are converted to SDR gamma/primaries using the configured SDR white
level; highlights and colors outside SDR's range clip. DMA-BUF captures retain
their existing format and behavior. This requires rebuilding and shipping the
patched wlroots library, then restarting Aqueous. The dependency build runs
`scripts/fixtures/screencopy-sdr.c` to check format selection, channel ordering,
row padding, and HDR color conversion. Verify full-output and region captures
with grabit on an HDR display, including after toggling HDR and with a rotated
or scaled output; these live GPU cases are not covered by the conversion test.

HDR-to-SDR gamma encoding uses a shared 5 KiB lookup table, initialized once
with `pthread_once` before processing pixels. It records the original float
encoder's output thresholds and uses a coarse index followed by threshold
correction, preserving quantization near black and at rounding boundaries.
There are no `powf` or `lroundf` calls in the pixel loop. The per-frame PQ decode
table and gamut matrix still use the current output description and SDR white.
Initialization assumes the normal floating-point environment; build this color
conversion without unsafe fast-math transformations.

The dependency build runs encoder boundary/dense/random tests, concurrent
initialization checks, and byte-for-byte pixel comparisons with the original
conversion. To also check every binary32 input in [0, 1] and benchmark just the
conversion, run from `compositor/`:

```sh
CFLAGS=-O2 AQUEOUS_CAPTURE_EXHAUSTIVE=1 AQUEOUS_CAPTURE_BENCHMARK=4k \
  scripts/build-wlroots-render-hook.sh /tmp/aqueous-wlroots-gamma
```

With an existing patched source tree and installed library, the same checks
can be run using `bash scripts/test-screencopy-sdr.sh SOURCE PREFIX`. Set
`AQUEOUS_CAPTURE_EXHAUSTIVE=1` for the exhaustive check and
`AQUEOUS_CAPTURE_BENCHMARK=1080p` or `4k` for timing. The conversion benchmark
compares against the original implementation in the same executable, checks
identical pixels, and reports median/p95 from 20 samples after three warmups.
It covers gradients, near-black, saturated and random pixels; readback,
allocation and PQ/table initialization are excluded and initialization is
timed separately. `CC` and `CFLAGS` select compiler and CPU target for this test.

Ext image-copy-capture output sessions additionally advertise native 10-bit SHM
alongside XRGB8888. The client selects a format by attaching its buffer. Native
capture retains all ten bits; XRGB8888 uses the SDR conversion above. Scene and
separate cursor sources retain their own constraints. Invalid or stale formats
fail with the protocol's recoverable buffer-constraints reason.

The experimental `aqueous-capture-color-v1` companion supplies destination color
metadata for an individual output SHM or supported isolated scene frame before
`ready`. Scene captures describe the rendered SDR destination with sRGB primaries
and gamma 2.2, including supported HDR-to-SDR conversion. Clients request metadata
before capture and must handle `unavailable`; output DMA-BUF and separate cursor
color metadata remain unqualified. Native HDR export requires this metadata and
an encoder that preserves its encoding. The XML is installed under
`share/aqueous-protocols/experimental/`. Existing grabit clients continue to use
the legacy path; adopting ext capture requires changes in grabit itself.

Run the protocol/copy tests without a GPU, or against generated Vulkan buffers:

```sh
scripts/test-ext-capture-formats.sh
scripts/test-ext-capture-formats.sh --vulkan /dev/dri/renderD128
python3 scripts/test-scene-capture.py
python3 scripts/test-scene-capture.py --renderer vulkan
AQUEOUS_CAPTURE_BENCHMARK=4k \
  AQUEOUS_CAPTURE_ARTIFACT_DIR=/tmp/aqueous-capture-4k \
  scripts/test-ext-capture-formats.sh --vulkan /dev/dri/renderD128
```

Set `AQUEOUS_WLROOTS_PREFIX` when testing a dependency installed elsewhere.
Benchmark sizes are `1080p` and `4k`; artifacts contain synthetic native/SDR
pixels and JSON frame metadata. Vulkan tests use a synthetic output and do not
capture the desktop. GPU allocation support can limit the tested native formats.
See [isolated capture colors](../docs/isolated-capture-color.md) for scene transport
coverage, client handling, private compositor checks and reference-pixel evidence.
The synchronous CPU fallback is intended for screenshots; measured dual-capture
cost was approximately 78 ms at 1080p and 317 ms at 4K on the tested AMD GPU.
Continuous recording needs a faster conversion path and separate qualification.
See the [color contract](../docs/architecture-decisions/0002-capture-format-and-color.md)
and [implementation status](../docs/capture-format-negotiation-plan.md).

Snapshot color-state regressions exercise the production buffer-cloning code:

```sh
PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" \
LD_LIBRARY_PATH="$PWD/.deps/wlroots-render-hook/lib" \
  zig build test-snapshot -Dcpu=baseline -Doptimize=safe
python3 scripts/test-snapshot-colors.py
python3 scripts/test-snapshot-colors.py --opacity 0.95
python3 scripts/test-snapshot-colors.py --blur
python3 scripts/test-snapshot-colors.py --opacity 0.95 --blur
python3 scripts/test-snapshot-colors.py --fullscreen --opacity 0.95
```

Run these graphical cases serially with a parent Wayland session and GPU access.
They need Pillow, grim, wlrctl, a C compiler, and Wayland development tools. The
fixture submits static gamma-2.2/BT.2020 patches and compares their rendered
colors during workspace animations and a resize transaction. Captures and JSON
results remain under the reported `/tmp/aqueous-snapshot-colors-*` directory.
`--compositor /path/to/old/aqueous` checks the same reproduction against an older
build. The nested output is SDR; verify actual Zed behavior on an HDR display
separately. See `../docs/snapshot-color-consistency-plan.md` for validation status.

The test requires `VK_LAYER_KHRONOS_validation`, ImageMagick, grim, jq, netcat,
a C compiler, and Wayland development tools. Its default nested-Wayland mode
also requires a parent Wayland display; set
`AQUEOUS_VULKAN_EFFECTS_BACKEND=headless` for the Vulkan-rendered headless
mode. It
checks rounded textures and hollow outlines through both compositor render
paths, scales 1, 1.25, 1.5, and 2 with rotations, bounded damage, screencopy,
explicit synchronization, and 4,096 releases and reuses of one client buffer.
Set
`AQUEOUS_VULKAN_PROBE_REQUIRE_VALIDATION=0` only for a functional smoke run on a
machine without the validation layer.

The color-management tests validate Proton's strict target/reference luminance
headroom after protocol rounding and exercise both Proton-EM's live version 1
output-discovery path and the version 3 Windows-scRGB/BT.2100 Wayland contract.
The live probe needs host GPU access for Aqueous's Vulkan renderer, but does not
require an HDR display; its headless SDR output also guards against false HDR
detection.

## Fullscreen workspace transition regression

Fullscreen workspace transitions have a dedicated pixel regression for issue
#53. It checks early slide motion, the opaque backing behind transparent
fullscreen content, neighboring-output containment, client dimensions/focus,
and cleanup after interrupted switches, window moves, overview, and output
changes. Run these graphical cases serially:

```sh
python3 scripts/test-fullscreen-workspace-transition.py --renderer vulkan
python3 scripts/test-fullscreen-workspace-transition.py --renderer vulkan --rate 3 --scale 1.25 --transform 90 --xwayland
python3 scripts/test-fullscreen-workspace-transition.py --renderer vulkan --rate 200
python3 scripts/test-fullscreen-workspace-transition.py --renderer vulkan --disabled
```

The test requires Pillow, grim, wlrctl, a C compiler, and Wayland development
tools. `--xwayland` also needs Xlib development files and an XWayland-enabled
build. `--renderer pixman` runs against a diagnostic build with
`-Dvulkan-effects=false`; add `--no-animations` when testing a build made with
`-Danimations=false`. Use `--compositor /path/to/aqueous` and optionally `--ctl`
to select isolated builds or the original failing build. Logs, screenshots,
and `results.json` remain in the printed `/tmp/aqueous-fullscreen-transition-*`
directory. Current policy permits one fullscreen window per output, so the
test preserves that constraint rather than creating two fullscreen workspaces
on the same output. See the
[implementation and validation notes](../docs/fullscreen-workspace-transition-plan.md).

## Headless window remapping regression

`scripts/test-window-remap.py` checks a persistent window hidden on one output
and reopened on another. By default, two tiled companion windows on each output
give the reopened window equal-size slots, exposing remaps that cannot rely on
a resize transaction to restore visibility.
It checks both window publication/geometry and actual pixels in screenshots,
including the absence of stale content on the old output. It runs fresh-process
controls before repeated remaps and keeps logs, scene dumps, screenshots, and
`results.json` under its printed `/tmp/aqueous-window-remap-*` directory.

```sh
python3 scripts/test-window-remap.py --renderer vulkan
python3 scripts/test-window-remap.py --renderer vulkan --timing interrupt --second-scale 1.5 \
  --electron /path/to/electron
```

Requires an XWayland-enabled build, `cc`, `pkg-config`, `wayland-scanner`, `grim`,
and Python Pillow. Vulkan requires a usable Vulkan device; a
`-Dvulkan-effects=false` build can run the default `--renderer pixman` path.
Use `--compositor` and `--ctl` to select separate build artifacts. Optional
`--backend wayland`, `x11`, `electron-wayland`, or `electron-x11` selects a subset;
repeat the option for multiple backends. Electron runs local solid-color content
with an isolated profile and intercepts Close to hide the same BrowserWindow.
It does not launch Discord or use its account/profile.

Add `--discord-lifecycle` to exercise taskbar visibility changes, explicit focus
on reopen, and Discord's 940×500 minimum window size. Each output can have its
own resolution and refresh rate:

```sh
python3 scripts/test-window-remap.py --renderer vulkan \
  --electron /path/to/electron --backend electron-wayland --discord-lifecycle \
  --timing cross-output --output-width 2560 --output-height 1440 --output-refresh 144 \
  --second-width 1920 --second-height 1080 --second-refresh 60 --cycles 5
```

`--timing cross-output` checks pixels on every destination after recording
passive scene state. `--reopen-wait 3` allows three seconds of passive settling;
`--electron-arg=--switch` forwards an extra diagnostic switch to Electron.

`--backend wayland-syncobj` runs a native DMA-BUF release-fence check: an empty
commit must retain the current buffer's release state, and explicit NULL detach
must signal its release before the client submits a replacement. This variant
checks fences and window mapping; the other fixtures check pixels. It requires
`libdrm` and `gbm` development files and a Vulkan render device with syncobj
support. The runner selects the compositor's logged render node; override with
`AQUEOUS_REMAP_DRM_DEVICE=/dev/dri/renderD…` if needed.

`--timing same-size` isolates a same-output, unchanged-size remap;
`--timing settled` checks ordinary cross-output remaps with screenshots between
steps. `--timing interrupt` hides during a confirmed output-transfer animation;
`--timing rapid` sends consecutive hide/show requests across outputs, and
`--timing transfer` moves a live window repeatedly. Timing cases keep one virtual
pointer alive and save passive scene state before post-sequence screenshots,
avoiding unrelated input-device changes or screencopy that could mask a stall.
The runner enables `AQUEOUS_DEBUG_WINDOW_STATE=1` for scene labels with lifecycle,
animation, configure, clip, and actual buffer-opacity state. Scene diagnostics
also tolerate backend destruction before the scene node has been released.

`--negative-control` deliberately acknowledges the native Wayland remap configure
without submitting another buffer. This command must fail after the fresh-process
and initial-map controls pass. Its failure artifacts distinguish an unpublished,
unmapped window from a published window whose pixels are missing. Passing the
normal fixture does not rule out Discord-specific behavior or different builds,
drivers, and configurations.

See [the remapping diagnosis](../docs/window-remap-diagnosis.md) for the
mixed-monitor syncobj release deadlock and the earlier native map defect.
The syncobj correction requires rebuilding and shipping the patched wlroots
library; updating only the Aqueous executable against the old library is insufficient.
To capture it in a live session, run
`python3 scripts/collect-window-remap.py --ctl ./zig-out/bin/aqueousctl` and
reproduce within 30 seconds. It saves passive scene, window, and output queries
under the printed temporary directory, without screenshots or focus changes.
The logs contain window titles; see the diagnosis for capture details.

`scripts/test-wheel-bindings.py` checks configurable wheel navigation, custom
actions on both physical axes, touchpad steps, hot reload, shortcut inhibition,
and application passthrough in an isolated headless session. It requires a
`-Dvulkan-effects=false` build, a C compiler, `wayland-scanner`, and
Wayland/xkbcommon development files:

```sh
AQUEOUS_COMPOSITOR_BIN=/path/to/no-effects/bin/aqueous python3 scripts/test-wheel-bindings.py
```

## Usage

Run `zig-out/bin/aqueous` nested in an existing Wayland/X11 session or from a
TTY using DRM/KMS. `-policy internal` is accepted explicitly but is also the
default. Aqueous loads its TOML configuration and directly manages layouts,
focus, workspaces, bindings, startup commands, screencopy, and outputs.

Embedded XWayland defaults to `-xwayland-scaling legacy`, which preserves the
traditional logical-resolution desktop. Use `-xwayland-scaling native` to give
XWayland each output's physical pixel dimensions while Aqueous projects its
surfaces into the logical scene. Native mode keeps X11 buffers sharp at
fractional output scales and converts X11 geometry, popups, pointer motion, and
pointer constraints at the output boundary. It requires the pinned wlroots
build above. Mixed-scale layouts may contain inert gaps in X11 root coordinates;
normal window placement and pointer delivery remain aligned with the Wayland
layout.

Native mode also derives X11 application DPI automatically from the applied
scale of the configured primary output (`96 × scale`). With no usable primary,
it uses the enabled non-mirrored output with the alphabetically first name;
with no usable outputs it uses 96 DPI. Focus and window movement do not change
this global setting. No additional configuration is needed. Legacy mode leaves
application DPI settings alone to avoid scaling twice.

A supervised worker publishes `Xft.dpi` and XSettings before normal session
autostart, with a bounded startup wait. It follows committed scale changes,
display preview/revert, primary changes and hotplug, and recovers after worker
or XWayland restarts. An existing XSettings manager retains ownership; the
worker reports `external` and leaves its settings alone. Unrelated X resources
are preserved, and shutdown restores the original DPI unless another client
has replaced it. Malformed, oversized or continued resource databases are
reported as publication failures rather than rewritten.

X11 application DPI is global: native mode cannot guarantee identical UI sizes
across differently scaled monitors or in applications that ignore DPI. GTK 3
uses an integer window scale with compensated font DPI, so fractional control
padding and fixed-size widgets can differ from native Wayland. Qt 6 can use the
fractional DPI directly. Existing explicit toolkit overrides still apply.
Legacy scaling remains the compatibility default.

`aqueousctl outputs --json` includes a session-wide `xwayland_scaling` object on
each output: `mode`, `dpi_status`, `target_dpi`, `published_dpi`, and
`source_output`. `published_dpi` is null unless the worker has acknowledged
publication; it does not claim that every running application has redrawn.
The output service's `list` response exposes the same object at the top level.

Run the worker's resource/ownership/recovery tests with
`python3 scripts/test-xwayland-dpi.py` (Xvfb enables lifecycle coverage). Add
`--compositor /path/to/aqueous --ctl /path/to/aqueousctl --toolkits` for private
headless compositor tests at 100%, 125%, 150% and 200%, startup ordering,
primary/fallback changes, XWayland restart and actual Qt 6/GTK 3 buffers. Add
`--helper /path/to/aqueous-config` to verify actual display preview/revert.
This requires the
toolkits' development packages; the default renderer is Vulkan, and
`--renderer pixman` supports a diagnostic build. Tests never use the session's
existing X server.

The same build produces `zig-out/bin/aqueousctl`. While running inside an
Aqueous session, use `aqueousctl windows`, `aqueousctl windows --json`, or
`aqueousctl inspect --rule` to inspect mapped native and XWayland windows.
`aqueousctl layout --output DP-1 --json` reports an output's active workspace
layout; add `--set grid` before `--json` to change it immediately.
`aqueousctl cursor --json` reports the effective cursor theme and size; use
`aqueousctl cursor set --theme NAME --size SIZE --json` for a live update.
`aqueousctl overlay-planes [--json]` reports per-output overlay eligibility,
rejection backoff, promotion transitions, and composed fallback counters.
Overlay mode requests libliftoff as an optional backend. Initialization or
unpromoted startup-commit failure falls back to ordinary atomic composition;
required overlay assignments are then rejected and their windows remain composed.
Enabling overlays clears the old `WLR_DRM_FORCE_LIBLIFTOFF` setting inherited
from earlier sessions; `-no-drm-overlay-planes` clears both backend settings.

DRM plane color conversion defaults to `auto`, attempting compatible hardware
pipelines with renderer fallback. Set `AQUEOUS_DRM_COLOR_PIPELINE=off` to disable
it. See [DRM color pipelines](../docs/color-pipeline.md) for supported
operations, renderer fallback, capture behavior and validation status.

For desktop slowdowns when a Proton game loses focus, use the
[focus-stall capture instructions](../docs/proton-wayland-focus-stall.md) to
record output state, compositor response times and NVIDIA load in the affected
session.

The headless cutover and output checks are:

```sh
scripts/test-policy-parity.sh
scripts/test-server-decoration.sh
scripts/test-rule-output-placement.sh
python3 scripts/test-rule-scrolling-width.py # diagnostic pixman build (-Dvulkan-effects=false)
scripts/test-xdg-fullscreen.sh
scripts/test-xdg-floating.sh
scripts/test-qt-transient-natural-size.sh
scripts/test-floating-outputs.sh
scripts/test-output-rotation-keybinding.sh
python3 scripts/test-output-focus.py # both mouse/focus options, reload and constraints
python3 scripts/test-focus-across-workspaces.py # Super+H/L crossing and wrapping workspaces, on and off
python3 scripts/test-primary-selection.py # middle-click transfers, focus ordering, modal/layer policy and target teardown (diagnostic pixman build)
python3 scripts/test-negative-output-position.py # Xwayland negative origins, rotation, reload and clicks (diagnostic pixman build)
python3 scripts/test-output-retry.py --compositor /tmp/aqueous-retry/bin/aqueous --ctl /tmp/aqueous-retry/bin/aqueousctl # requires -Doutput-retry-testing=true; see ../docs/output-commit-retry.md
python3 scripts/test-output-teardown.py --compositor /tmp/aqueous-retry/bin/aqueous # same test build; removes outputs with occluded live windows
scripts/test-scaling.sh
scripts/test-overlay-planes.sh
scripts/test-client-buffer-scaling.sh
scripts/test-xwayland-input.sh
scripts/test-xwayland-floating.sh
```

Client button presses that request focus are delivered after the normal focus
decision, so middle-click handlers receive the current primary-selection offer
before requesting its contents. Modal dialogs, exclusive layers and grabs keep
their existing focus policy. Pending presses are cancelled if their target
unmaps or is destroyed; the physical release is still consumed.

Run the XWayland floating and input coverage at 125% native scaling with:

```sh
AQUEOUS_OUTPUTS="$PWD/scripts/fixtures/xwayland-native-scaling-outputs.toml" \
AQUEOUS_XWAYLAND_SCALING=native \
AQUEOUS_XWAYLAND_POINTER_EXTENT=1024x576 \
AQUEOUS_XWAYLAND_SCALE_NUMERATOR=5 \
AQUEOUS_XWAYLAND_SCALE_DENOMINATOR=4 \
  scripts/test-xwayland-floating.sh
AQUEOUS_OUTPUTS="$PWD/scripts/fixtures/xwayland-native-scaling-outputs.toml" \
AQUEOUS_XWAYLAND_SCALING=native scripts/test-xwayland-input.sh
```

The xdg fullscreen harness compiles a small native Wayland client and verifies
application-requested fullscreen enter/exit configures, including repeated
requests, against the integrated policy. The xdg floating harness verifies
client-originated move, edge-aware resize, maximize, and minimize requests for
persistent floats and workspace-floating windows, while ordinary windows in
non-floating layouts ignore those requests. It also maps overlapping floats and
verifies that focusing either exposed edge raises that window for subsequent
overlap hit testing. The Qt transient harness requires Qt 6 Widgets development
files and verifies that a portal-style dialog reaches its natural size without
pointer input. The policy and floating harnesses require
`wlrctl`; the policy harness also requires Ghostty and maps real windows instead
of testing an idle compositor. The floating-output harness verifies pointer-led
workspace transfer across rotated mixed-scale outputs and recovery when the
source output is disabled during an active move.
The output-rotation harness verifies exact pointer-output targeting, transform
cycling, and preservation of unrelated output state.
The client-buffer scaling harness runs at 125%, verifies that the default
native `preferred_scale(150)` and an explicit test-only integer-ceil
`preferred_scale(240)` both precede initial root and popup configures, propagate
to subsurfaces, and keep all VSCodium/Shelly opt-ins confined to its fixture.
The XWayland harnesses additionally require a build with `-Dxwayland`,
XWayland, a C compiler, `wayland-scanner`, and X11/Wayland/xkbcommon development
files. The input harness verifies active keyboard grabs and pointer confinement
for real X11 clients under the headless backend, both at 1× and across mixed
1×/1.5× outputs. Set `AQUEOUS_XWAYLAND_SCALING=native` to exercise native X11
projection. The output-focus harness also checks locking and confinement on
static Wayland surfaces without an additional surface commit, including motion
against window edges. These grabs require the patched wlroots initial-region
fix; rebuild the dependency and restart Aqueous when updating from an older
library. The floating harness sends
real `_NET_WM_MOVERESIZE` requests and verifies titlebar-style move and resize
for persistent floats and workspace-floating windows without a compositor
modifier, while tiled-policy windows reject the same requests.

The Vulkan effects and uncached blur oracle can be captured from a nested
session with:

```sh
scripts/test-vulkan-effects.sh /tmp/aqueous-vulkan-effects
```

Window rounding is configured with `[decoration] corner_radius = 15` in
`wm.toml` (integer logical pixels, 0–128; zero disables compositor rounding).
It reloads live for content, borders and blur. A radius change ends any current
cosmetic window motion so frozen content and new borders cannot disagree.
Fullscreen and no-effects builds stay square; application-drawn transparent
corners remain transparent.

Check default rounding, live changes, borderless windows, geometry clamping and
fullscreen transitions in a private headless session:

```sh
python3 scripts/test-corner-radius.py --renderer vulkan
python3 scripts/test-corner-radius.py --renderer vulkan --scale 1.5 --uncached
python3 scripts/test-corner-radius.py --renderer pixman --compositor /path/to/no-effects/aqueous --ctl /path/to/no-effects/aqueousctl
```

The fixture uses temporary configuration and requires a C compiler,
`wayland-scanner`, Wayland development files, `grim`, and Python/Pillow. Vulkan
runs additionally need a render device. Screenshots and logs remain in the
printed `/tmp/aqueous-corners-*` directory.

See `doc/vulkan-effects-baseline.md` for fixture geometry, artifacts, timing
semantics, and the current blur-cache behavior.

See `ORIGIN.md` and the repository-level README for source provenance,
packaging, and session integration.

Shell integrations can connect directly to `AQUEOUS_SOCKET` using the
[persistent IPC v1 interface](protocol/aqueous-ipc-v1.md). The existing Wayland
adapter remains supported through `aqueousctl shell capabilities --json`,
`aqueousctl shell snapshot --json`, and the persistent
`aqueousctl shell watch --json` stream. Typed window, workspace, keyboard,
overview and session commands share stable runtime identities. See the
[protocol and CLI contract](protocol/aqueous-shell-v1.md) and
[isolated regression instructions](../docs/dms-integration-testing.md).

## Native background blur

Vulkan effects builds serve `ext-background-effect-v1` version 1. DMS can use
Quickshell's `BackgroundEffect.blurRegion` directly with global `[blur]` enabled;
namespace rules are optional. Exact regions, including holes and rounded
scanline masks, are composited through the existing cached and uncached blur
paths. See [rule precedence](../docs/rules.md#layer).

Run the isolated protocol and pixel regression with GPU access:

```sh
LD_LIBRARY_PATH="$PWD/.deps/wlroots-render-hook/lib" \
  python3 scripts/test-background-effect.py
```

It needs a C compiler, Wayland development files, `wayland-scanner`, `grim`,
Python/Pillow, and the companion `aqueousctl` build. All compositor, client,
configuration, logs, and screenshots are isolated under the printed `/tmp`
artifact directory. Set `DMS_SOURCE=/path/to/DankMaterialShell` to additionally
exercise the actual DMS `WindowBlur` component with `qs` and `dms`, including
preference toggles and absence of helper calls or compositor configuration writes.
Initialize that checkout's `dank-qml-common` submodule first. This uses temporary
settings and clears inherited DMS connections.

The regression covers unused effect objects, explicit empty/null requests,
commit boundaries, destruction/recreation, and frozen animation ownership in
both cached and uncached rendering. When GTK4 development files are installed,
it also compares an actual GTK window with native protocol discovery enabled
and disabled. Creating an unused effect object must preserve compositor fallback
blur; only an explicit committed region request overrides it. Override the test
binaries with `AQUEOUS_COMPOSITOR_BIN` and `AQUEOUS_CTL_BIN` (the latter defaults
to `aqueousctl` alongside the selected compositor).

With a separate `-Dvulkan-effects=false` build, verify the global stays absent:

```sh
AQUEOUS_COMPOSITOR_BIN=/path/to/no-effects/bin/aqueous \
AQUEOUS_TEST_NO_EFFECTS=1 python3 scripts/test-background-effect.py
```

`dms blur check` checks global discovery, so it still reports `supported` when
runtime blur is disabled on an effects build. The compositor sends capability
changes and retains requests across disable/re-enable. Builds without effects
report `unsupported`.

## Per-window icons

Aqueous advertises `xdg_toplevel_icon_manager_v1` version 1. Icons are synchronized
with surface commits, including cached commits, and remain assigned after the
client destroys its icon object. Pixel icons appear in the built-in overview;
name-only icons use a generic placeholder there. Shell clients receive optional
icon metadata and can request bounded PNGs over the existing IPC socket. DMS's
Aqueous service uses supplied pixels or theme names for individual window entries
and the focused-window widget; grouped and pinned launcher icons retain their
application identity.

Rebuild the pinned wlroots dependency (including patch 0016) before building
Aqueous. The compositor also requires libpng for asynchronous PNG encoding.
Run the isolated protocol, lifetime, shell, pixel and resource-limit checks:

```sh
python3 scripts/test-xdg-toplevel-icon.py --compositor /path/to/pixman/aqueous
python3 scripts/test-xdg-toplevel-icon.py --renderer vulkan --compositor /path/to/vulkan/aqueous
```

The harness requires a C compiler, wayland-scanner, Python/Pillow, and grim.
See [the implementation record](../docs/xdg-toplevel-icon-implementation-plan.md)
and [IPC contract](protocol/aqueous-ipc-v1.md) for limits and verification scope.

### System bell

Aqueous advertises `xdg_system_bell_v1` version 1 in both renderer builds,
including security-context clients and external-policy mode. The default bell
briefly highlights the associated output edge. Configure it under **Appearance →
System bell** through a configuration client such as Pearl, or in `wm.toml`:

```toml
[bell]
mode = "both" # visual | sound | both | off; default: visual
sound_file = "sounds/bell.wav"
volume = 0.5
```

Sound paths are absolute or relative to the loaded `wm.toml`, including an
`AQUEOUS_CONFIG` override. Shell expressions, variables and `~` are literal.
An empty path or zero volume disables audio. Install the PipeWire tools providing
`pw-play` for sounds; the Nix package supplies its runtime path. PCM WAV works;
Ogg Vorbis and other formats depend on the player's libsndfile build. Audio uses
the default sink and respects session mute/routing; volume affects only the bell.
Missing files, playback errors or an unavailable audio service preserve visual
feedback in `both` mode.

Feedback requires a mapped, visible toplevel on an awake output. A null surface
uses the requesting client's focused window, selecting the first eligible seat
in creation order; otherwise it does nothing. Bells do not change focus,
workspaces, urgency, idle state or output power. Requests share a 500 ms cooldown;
visual feedback lasts 150 ms, and only one sound plays at a time, for at most two
seconds plus a 100 ms termination grace. There is no queue. Locking and changes
to bell configuration cancel feedback, as do target output power/geometry changes.
Buffered audio may have a short backend-dependent tail when canceled.

Run the isolated test with the desired compositor and matching renderer:

```sh
python3 scripts/test-xdg-system-bell.py --renderer pixman --compositor /path/to/aqueous --ctl /path/to/aqueousctl
python3 scripts/test-xdg-system-bell.py --renderer vulkan --compositor /path/to/aqueous --ctl /path/to/aqueousctl
```

Add `--real-audio` to record WAV/Ogg playback and verify volume through a private
PipeWire null sink. This needs PipeWire tools, WirePlumber, D-Bus and FFmpeg;
hardware monitors are disabled. The base suite uses a fake player, two headless
outputs, `wlr-randr`, `grim`, and Pillow. `--policy external` runs the registry and
lifecycle smoke test against an external-policy-enabled build. See the
[implementation record](../docs/xdg-system-bell-v1-implementation-plan.md).

## Toplevel purpose tags

Aqueous advertises `xdg_toplevel_tag_manager_v1` version 1, including to
security-context clients and in external-policy builds. Native windows retain
owned, independently updated tags and translated descriptions. Updates take
effect without a surface commit; unmapping resets the metadata. Internal policy
supports `tag` globs in `rules.toml` and the settings rule editor.

`aqueousctl windows --json`, window-info version 8, and socket shell snapshots
expose nullable `tag` and `description` fields. `aqueousctl inspect --rule`
combines app ID with a literal non-empty tag. Older inspection bindings remain
supported. Descriptions are display text, not rule matchers or window IDs.

```sh
python3 scripts/test-xdg-toplevel-tag.py --renderer pixman --compositor /path/to/pixman/aqueous
python3 scripts/test-xdg-toplevel-tag.py --renderer vulkan --compositor /path/to/vulkan/aqueous
```

The Pixman fixture needs a `-Dvulkan-effects=false` build. See the
[implementation and validation record](../docs/xdg-toplevel-tag-v1-implementation-plan.md)
and [rule syntax](../docs/rules.md#window-purpose-tags).

### DRM leasing for VR headsets

`drm-lease-v1` version 1 offers DRM connectors marked non-desktop, while keeping
them out of desktop layouts, output configuration, workspaces, mirroring, and
capture. Eligible ordinary clients receive leases while the session is active
and unlocked; security-context clients cannot discover the lease globals.
Locking or switching away revokes leases, and clients must request new ones
when the session returns. Headless/nested backends expose no lease device.

Rebuild the pinned wlroots dependency when upgrading: the compositor requires
its DRM lease lifetime and allocation fixes. An unrecoverable kernel revocation
or active-display blanking error ends the session instead of reporting a
successful lock. Hardware and driver qualification remains outstanding.

For a headset on a second GPU, explicitly include all required cards in
`WLR_DRM_DEVICES` before startup; Aqueous's automatic GPU selection can otherwise
limit the backend to a single card. A headset without the DRM non-desktop flag
is not automatically eligible. No desktop-monitor override is provided.

```sh
zig build test-drm-lease
python3 scripts/test-drm-lease.py --renderer vulkan
python3 scripts/test-drm-lease.py --hardware --device /dev/dri/card1 --connector DP-3
```

The first integration command starts a private headless compositor. Hardware
mode connects to the current session and leases only the explicitly named,
already-advertised connector; it tests resource ownership and recovery, not
headset scanout. Use `--renderer pixman` with a no-effects build and
`--compositor`/`--ctl` for separate build prefixes. See the
[implementation and validation record](../docs/drm-lease-v1-implementation-plan.md)
for the complete policy, dependency fixes, tests, and remaining hardware checks.

## Input activity

The custom `aqueous-input-activity-v1` interface reports rate-limited keyboard/mouse
activity flags on the existing Wayland connection, without input values. Access
requires a process-bound, single-use capability from the packaged Pearl service
bootstrap. See the [protocol contract](protocol/aqueous-input-activity-v1.md) for
authorization, suspension, supported launch paths and the Pearl adapter handoff.

The isolated test requires a diagnostic build and never connects to the host display:

```sh
zig build -Dinput-activity-testing=true -Dvulkan-effects=false
python3 scripts/test-input-activity.py
python3 scripts/test-input-activity-latency.py
```

Never package a build with `input-activity-testing` enabled.

The latency fixture compares native keyboard/mouse delivery with the observer
bypassed, idle and actively publishing. It reports handler time and application
delivery percentiles, plus confidence intervals for paired differences. Use
`--max-p95-increase-us N` to enforce a delivery budget; the default records a
comparison without imposing an arbitrary performance threshold. See the
[measurement method and results](../docs/input-activity-latency.md).

Single-window tiling centering can be checked in a private ultrawide headless
session using a diagnostic `-Dvulkan-effects=false` build:

```sh
python3 scripts/test-single-window-centering.py
```

Use `--compositor` and `--ctl` to select matching binaries from a separate build.
The test exercises tile, grid, rows, dwindle and reverse-dwindle with opening,
closing, minimization, workspace moves, dialogs, floating overlays, fullscreen,
maximization and configuration reload. It uses temporary configuration only.
