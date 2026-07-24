# Aqueous compositor

This directory contains the Zig implementation of Aqueous: a wlroots-based
Wayland compositor with integrated window-management, input, and output policy.

## Building

Required development libraries include Wayland, wayland-protocols, wlroots
0.20, libxkbcommon, libinput, libevdev, pixman, and pkg-config. Vulkan-effects
builds also require Vulkan headers and the loader. Zig 0.16 or newer is
required; scdoc is optional for man pages.

```sh
zig build -Doptimize=ReleaseSafe -Dxwayland
zig build test
```

SceneFX is auto-detected and can be selected explicitly with
`-Dscenefx=true|false`. `-Dvulkan-effects=true` disables SceneFX auto-detection,
links the borrowed Vulkan context, and requires wlroots' Vulkan renderer at
startup. Explicitly enabling both effects backends is a build error. Production
builds run integrated policy by default. For legacy protocol compatibility testing only,
`-Dexternal-policy=true` enables the `external` and `compare` policy modes.

The render-seam probe uses the pinned wlroots hook and is not part of a normal
Vulkan-effects build:

```sh
scripts/build-wlroots-render-hook.sh .deps/wlroots-render-hook
PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" \
  zig build \
    -Dvulkan-effects=true \
    -Dvulkan-render-probe=true \
    -Dexternal-policy=true \
    -Dcpu=baseline \
    -Doptimize=ReleaseSafe
scripts/test-vulkan-render-seam.sh /tmp/aqueous-vulkan-render-seam
```

The test requires `VK_LAYER_KHRONOS_validation`, a parent Wayland display,
ImageMagick, grim, jq, netcat, a C compiler, and Wayland development tools. It
checks both compositor render paths, transformed fractional scaling, bounded
damage, screencopy, explicit synchronization, and 4,096 releases and reuses of
one client buffer. Set
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
scripts/test-scaling.sh
scripts/test-xwayland-input.sh
```

The xdg fullscreen harness compiles a small native Wayland client and verifies
application-requested fullscreen enter/exit configures, including repeated
requests, against the integrated policy. The policy harness requires Ghostty
and `wlrctl`; it maps real windows and injects virtual keyboard/pointer input
instead of testing an idle compositor.
The XWayland harness additionally requires a build with `-Dxwayland`,
XWayland, a C compiler, `wayland-scanner`, and X11/Wayland/xkbcommon development
files. It verifies active keyboard grabs and pointer confinement for real X11
clients under the headless backend.

SceneFX visual references and render metadata can be captured from a nested
session with:

```sh
scripts/capture-effects-baseline.sh
```

See `doc/vulkan-effects-baseline.md` for fixture geometry, artifacts, timing
semantics, and the current blur-cache invalidation inventory.

See `ORIGIN.md` and the repository-level README for source provenance,
packaging, and session integration.
