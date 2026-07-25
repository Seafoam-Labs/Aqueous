# Aqueous compositor

This directory contains the Zig implementation of Aqueous: a wlroots-based
Wayland compositor with integrated window-management, input, and output policy.

## Building

Required development libraries include Wayland, wayland-protocols,
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

## Usage

Run `zig-out/bin/aqueous` nested in an existing Wayland/X11 session or from a
TTY using DRM/KMS. `-policy internal` is accepted explicitly but is also the
default. Aqueous loads its TOML configuration and directly manages layouts,
focus, workspaces, bindings, startup commands, screencopy, and outputs.

The same build produces `zig-out/bin/aqueousctl`. While running inside an
Aqueous session, use `aqueousctl windows`, `aqueousctl windows --json`, or
`aqueousctl inspect --rule` to inspect mapped native and XWayland windows.

The headless cutover and output checks are:

```sh
scripts/test-policy-parity.sh
scripts/test-xdg-fullscreen.sh
scripts/test-xdg-floating.sh
scripts/test-floating-outputs.sh
scripts/test-scaling.sh
scripts/test-xwayland-input.sh
```

The xdg fullscreen harness compiles a small native Wayland client and verifies
application-requested fullscreen enter/exit configures, including repeated
requests, against the integrated policy. The xdg floating harness verifies
client-originated move, edge-aware resize, maximize, and minimize requests and
confirms that tiled windows ignore those requests. It also maps overlapping
floats and verifies that focusing either exposed edge raises that window for
subsequent overlap hit testing. The policy and floating harnesses require
`wlrctl`; the policy harness also requires Ghostty and maps real windows instead
of testing an idle compositor. The floating-output harness verifies pointer-led
workspace transfer across rotated mixed-scale outputs and recovery when the
source output is disabled during an active move.
The XWayland harness additionally requires a build with `-Dxwayland`,
XWayland, a C compiler, `wayland-scanner`, and X11/Wayland/xkbcommon development
files. It verifies active keyboard grabs and pointer confinement for real X11
clients under the headless backend.

The Vulkan effects and uncached blur oracle can be captured from a nested
session with:

```sh
scripts/test-vulkan-effects.sh /tmp/aqueous-vulkan-effects
```

See `doc/vulkan-effects-baseline.md` for fixture geometry, artifacts, timing
semantics, and the current blur-cache behavior.

See `ORIGIN.md` and the repository-level README for source provenance,
packaging, and session integration.
