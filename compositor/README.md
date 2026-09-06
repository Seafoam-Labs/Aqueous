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

The headless cutover and output checks are:

```sh
scripts/test-policy-parity.sh
scripts/test-server-decoration.sh
scripts/test-rule-output-placement.sh
scripts/test-xdg-fullscreen.sh
scripts/test-xdg-floating.sh
scripts/test-qt-transient-natural-size.sh
scripts/test-floating-outputs.sh
scripts/test-output-rotation-keybinding.sh
python3 scripts/test-output-focus.py
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

Shell integrations use `aqueousctl shell capabilities --json`,
`aqueousctl shell snapshot --json`, and the persistent
`aqueousctl shell watch --json` stream. Typed window, workspace, keyboard,
overview and session commands share stable runtime identities. See the
[protocol and CLI contract](protocol/aqueous-shell-v1.md) and
[isolated regression instructions](../docs/dms-integration-testing.md).
