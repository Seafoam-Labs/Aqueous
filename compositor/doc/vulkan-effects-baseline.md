# Vulkan effects validation

The effects harness produces repeatable images, damage measurements, cache
statistics, and render-path counters for the Aqueous Vulkan implementation.
The uncached blur mode is the visual oracle for the optimized cache.

## Build

```sh
cd compositor
scripts/build-wlroots-render-hook.sh
export PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig"
zig build -Dcpu=baseline -Doptimize=ReleaseSafe -Dexternal-policy=true
```

The default build enables Vulkan effects. It installs the exact patched
`libwlroots-0.20.so` under `zig-out/lib/aqueous`; the compositor carries an
origin-relative runtime path to that private library.

Use `-Dvulkan-effects=false` for the square/no-blur diagnostic build. That
configuration uses stock wlroots and does not require the render hook.

## Capture

Run the cached implementation and uncached oracle together:

```sh
AQUEOUS_VULKAN_PROBE_REQUIRE_VALIDATION=0 \
  scripts/test-vulkan-effects.sh /tmp/aqueous-vulkan-effects
```

Omit `AQUEOUS_VULKAN_PROBE_REQUIRE_VALIDATION=0` when the Khronos validation
layer is installed. The destination must be empty.

The harness defaults to 4,096 buffer-reuse frames. A shorter functional run can
set `AQUEOUS_VULKAN_PROBE_FRAMES`, for example:

```sh
AQUEOUS_VULKAN_PROBE_FRAMES=64 \
AQUEOUS_VULKAN_PROBE_REQUIRE_VALIDATION=0 \
  scripts/test-vulkan-effects.sh /tmp/aqueous-vulkan-effects
```

## Fixture

The native Wayland fixture renders:

| App ID | Content | Compositor state |
|---|---|---|
| `aqueous.effects.square` | Colored corner witnesses and an opaque gradient | Fullscreen, square corners, no blur |
| `aqueous.effects.clipped` | Edge bars and pixel rulers | Oversized scrolling window clipped by the output |
| `aqueous.effects.background` | Checker, diagonal stripes, gradients | Rounded, opaque background |
| `aqueous.effects.blur` | Translucent panel, popup, desynchronized subsurface | Rounded backdrop blur |
| `aqueous.effects.alpha` | Alpha gradient and transparent cells | Rounded, compositor opacity |

The background client accepts deterministic full and localized updates while
reusing compositor-released SHM buffers. This makes stale cache pixels,
self-sampling, over-expanded damage, and synchronization failures visible.

## Matrix

The harness covers:

- normal output commits and OutputManager swapchain commits;
- scales 1, 1.25, 1.5, and 2;
- normal, 90°, 180°, and 270° transforms;
- rounded textures, hollow rounded borders, clipping, alpha, and overlap;
- moving and localized backdrop damage;
- workspace animation snapshots;
- output disable/resume resource rebuilding;
- screencopy after final compositing;
- explicit synchronization and repeated buffer reuse.

`scripts/test-vulkan-shell-paths.sh` adds layer-shell capture and session-lock
presentation. `AQUEOUS_XWAYLAND_RENDER_ONLY=1
scripts/test-xwayland-input.sh` adds managed and override-redirect XWayland
rendering.

## Artifacts

Each cached or uncached directory contains:

| Artifact | Contents |
|---|---|
| `*.png` | Captures for geometry, effects, damage, animation, and output recovery |
| `results.txt` | Draw counts, render paths, cache activity, damage bounds, and image assertions |
| `output.json` | Final output state |
| `windows.json` | Window identities, geometry, layout, and state |
| `compositor.log` | Complete compositor log |
| `clients/*.log` | Fixture diagnostics |
| `SHA256SUMS` | Integrity manifest |

The parent directory also contains `comparisons.txt`, which records normalized
mean differences between selected cached and uncached captures. The default
tolerance is `0.0002` and can be changed with
`AQUEOUS_VULKAN_BLUR_REFERENCE_TOLERANCE`.

## Cache behavior

Each output owns a set of half-resolution FP16 scene checkpoints keyed by
window blur identity. Damage is expanded by the resolved kernel reach and
propagated backward through every separable pass. Stable checkpoints are
preserved, localized damage takes the partial path, and mode, scale, transform,
geometry, configuration, or uncertain scene changes force a safe full rebuild.

The harness records:

- cache hits;
- partial and full rebuilds;
- processed half-resolution pixels;
- rounded texture and rect draws;
- normal, swapchain, and explicit-sync paths;
- scene-ordered blur checkpoints, offscreen draws, and composites.

Static frames must not continuously rebuild the cache. Every cached capture
must remain within the configured tolerance of the uncached oracle.
