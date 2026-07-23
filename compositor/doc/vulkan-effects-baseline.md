# Effects reference capture

The effects reference tooling produces repeatable SceneFX images and timing
artifacts for comparison with the custom Vulkan implementation.

## Capture

Build an Aqueous binary linked with SceneFX:

```sh
cd compositor
zig build -Dcpu=baseline -Doptimize=ReleaseSafe -Dscenefx=true
scripts/capture-effects-baseline.sh
```

The default output is a timestamped directory under `compositor/baselines/`.
Pass a directory as the first argument to select a different destination:

```sh
scripts/capture-effects-baseline.sh /tmp/aqueous-effects-reference
```

The destination must be empty. Generated capture directories are intentionally
ignored by Git; approved reference images should be copied into a dedicated
tracked test-data directory only after review.

The capture uses a nested Wayland backend when a parent Wayland display is
available. Set `AQUEOUS_BASELINE_BACKEND=headless` to request the headless
backend explicitly. SceneFX needs a render-capable backend and may not start
with a headless backend that has no DRM render node.

The defaults exercise 1920×1080, 2560×1440, and 3840×2160. They can be changed:

```sh
AQUEOUS_BASELINE_MODES="1920x1080" \
AQUEOUS_BASELINE_SAMPLES=30 \
scripts/capture-effects-baseline.sh /tmp/aqueous-effects-reference
```

## Fixture

The harness compiles `visual-effects-reference.c` against the system xdg-shell
protocol and maps three fixed windows:

| App ID | Geometry at 1920×1080 | Content | Compositor state |
|---|---:|---|---|
| `aqueous.effects.background` | 1760×920 at 80,80 | Opaque checker, diagonal stripes, and gradients | Rounded, no blur, opacity 1 |
| `aqueous.effects.blur` | 760×520 at 260,210 | Low-alpha panel, opaque frame, and grid | Rounded, backdrop blur, opacity 0.88 |
| `aqueous.effects.alpha` | 560×360 at 1120,460 | Alpha gradient with transparent cells | Rounded, no blur, opacity 0.72 |

The background has high spatial frequencies so blur errors, stale cache
regions, clipping, and self-sampling are visually obvious. The alpha fixture
separately exposes premultiplication and compositor-opacity errors.

Placement and visual policy come from:

- `scripts/fixtures/visual-effects-wm.toml`
- `scripts/fixtures/visual-effects-rules.toml`

## Artifacts

Each capture directory contains:

| Artifact | Contents |
|---|---|
| `reference-WIDTHxHEIGHT.png` | Final screencopy for the requested output mode |
| `image-WIDTHxHEIGHT.txt` | Image dimensions and mean RGBA channels |
| `render-WIDTHxHEIGHT.log` | Render metrics observed during warmup and capture |
| `render-summary.tsv` | Minimum, mean, and maximum CPU/GPU timing values |
| `output-WIDTHxHEIGHT.json` | Output state at capture time |
| `windows.json` | Enumerated window identities, geometry, layout, and states |
| `environment.txt` | Git state, binary version, dependency versions, kernel, and Vulkan devices |
| `compositor.log` | Complete compositor log |
| `clients/*.log` | Per-fixture diagnostics |
| `SHA256SUMS` | Integrity manifest for every other artifact |

`AQUEOUS_RENDER_METRICS=1` records wlroots scene preparation time as
`pre_render_ns`. `AQUEOUS_RENDER_GPU_METRICS=1` additionally queries the
renderer timer. A negative GPU duration means the renderer or driver could not
provide a valid result. GPU timing is disabled in the default capture because
SceneFX's GLES timer can be disjoint on nested and multi-GPU configurations.

SceneFX does not expose cache hits or actual cache rebuild completions. The
following `blur-cache` events are request-side measurements:

| Event | Meaning |
|---|---|
| `create` | An optimized output cache node was created and marked dirty |
| `configure_dirty` | Configuration, creation, or output geometry requested regeneration |
| `damage_dirty` | Background or bottom-layer damage requested regeneration |
| `enable` / `disable` | The output cache node changed enabled state |
| `destroy` | The output cache node was destroyed |

These events are suitable for comparing invalidation behavior, but must not be
reported as measured GPU cache rebuilds.

## Current blur invalidation behavior

The SceneFX cache is output-local and represents the backdrop below ordinary
windows. Its current lifecycle is:

| Trigger | Path | Result |
|---|---|---|
| Blur configuration or global policy changes | `WindowManager.applyBlur` → `Output.syncBlur(true)` | Every output cache is created or marked dirty |
| First active blur configuration on an output | `Output.syncBlur` | Cache node is created and marked dirty |
| Output mode, logical size, or position changes | `OutputManager` → `Output.syncBlur(false)` | Geometry comparison marks the cache dirty |
| Blur becomes inactive | `Output.syncBlur` | Cache is disabled and remembered geometry is cleared |
| Blur becomes active again | `Output.syncBlur` | Cleared geometry forces regeneration |
| Background/bottom layer map, unmap, commit, or layer change | `LayerSurface.invalidateBlur` → `Output.markBlurDirty` | Output cache is marked dirty |
| Output destruction | `Output.handleDestroy` | Cache node is destroyed |

Ordinary window motion and damage do not dirty the optimized backdrop cache.
Those windows are above the cached background and use their own window-local
blur nodes to display it. A window-local mask is enabled only when global blur
is active, the rule permits blur, the window has positive dimensions, the
window is not fullscreen, and it is not displaying an animation snapshot.

Clipping intersects the mask with both window and content clips. If clipping
creates a new edge, the mask becomes square instead of retaining a radius.
Fullscreen disables both rounding and window-local blur.

## Square/no-blur build

The fallback remains a required diagnostic configuration:

```sh
cd compositor
zig build -Dcpu=baseline -Doptimize=ReleaseSafe -Dscenefx=false
```

This build uses stock wlroots rendering, keeps opacity behavior, and compiles
all SceneFX symbols out of `fx.zig`.
