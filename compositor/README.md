# Aqueous compositor

This directory contains the Zig implementation of Aqueous: a wlroots-based
Wayland compositor with integrated window-management, input, and output policy.

## Building

Required development libraries include Wayland, wayland-protocols 1.49 or newer,
libxkbcommon, libinput, libevdev, pixman, Vulkan headers and loader, and the
wlroots 0.20 build dependencies. Zig 0.16 or newer is required; scdoc is
optional for man pages.

```sh
zig build -Doptimize=ReleaseSafe -Dxwayland
zig build test
```

Vulkan effects are enabled by default, borrow wlroots' Vulkan context, require
wlroots' Vulkan renderer at startup, and use the pinned Aqueous wlroots render
hook. `-Dvulkan-effects=false` builds the square/no-blur diagnostic compositor
against stock wlroots. Production builds run integrated policy by default. For
legacy protocol compatibility testing only,
`-Dexternal-policy=true` enables the `external` and `compare` policy modes.

Build the pinned dependency before the default build:

```sh
scripts/build-wlroots-render-hook.sh .deps/wlroots-render-hook
PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" \
  zig build \
    -Dexternal-policy=true \
    -Dcpu=baseline \
    -Doptimize=ReleaseSafe
scripts/test-vulkan-render-seam.sh /tmp/aqueous-vulkan-render-seam
scripts/test-color-management-luminance.sh
scripts/test-proton-hdr-color-management.sh
```

Snapshot color-state regressions exercise the production buffer-cloning code:

```sh
PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" \
LD_LIBRARY_PATH="$PWD/.deps/wlroots-render-hook/lib" \
  zig build test-snapshot -Dcpu=baseline -Doptimize=ReleaseSafe
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

The same build produces `zig-out/bin/aqueousctl`. While running inside an
Aqueous session, use `aqueousctl windows`, `aqueousctl windows --json`, or
`aqueousctl inspect --rule` to inspect mapped native and XWayland windows.
`aqueousctl layout --output DP-1 --json` reports an output's active workspace
layout; add `--set grid` before `--json` to change it immediately.
`aqueousctl cursor --json` reports the effective cursor theme and size; use
`aqueousctl cursor set --theme NAME --size SIZE --json` for a live update.
`aqueousctl overlay-planes [--json]` reports per-output overlay eligibility,
rejection backoff, promotion transitions, and composed fallback counters.

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
python3 scripts/test-output-retry.py --compositor /tmp/aqueous-retry/bin/aqueous --ctl /tmp/aqueous-retry/bin/aqueousctl # requires -Doutput-retry-testing=true; see ../docs/output-commit-retry.md
scripts/test-scaling.sh
scripts/test-overlay-planes.sh
scripts/test-client-buffer-scaling.sh
scripts/test-xwayland-input.sh
scripts/test-xwayland-floating.sh
```

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
for real X11 clients under the headless backend. The floating harness sends
real `_NET_WM_MOVERESIZE` requests and verifies titlebar-style move and resize
for persistent floats and workspace-floating windows without a compositor
modifier, while tiled-policy windows reject the same requests.

The Vulkan effects and uncached blur oracle can be captured from a nested
session with:

```sh
scripts/test-vulkan-effects.sh /tmp/aqueous-vulkan-effects
```

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

With a separate `-Dvulkan-effects=false` build, verify the global stays absent:

```sh
AQUEOUS_COMPOSITOR_BIN=/path/to/no-effects/bin/aqueous \
AQUEOUS_TEST_NO_EFFECTS=1 python3 scripts/test-background-effect.py
```

`dms blur check` checks global discovery, so it still reports `supported` when
runtime blur is disabled on an effects build. The compositor sends capability
changes and retains requests across disable/re-enable. Builds without effects
report `unsupported`.
