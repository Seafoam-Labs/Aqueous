# Vulkan effects migration plan

## Goal

Replace the SceneFX features Aqueous actually uses with Aqueous-owned Vulkan
implementations while keeping wlroots responsible for:

- Wayland protocols and scene ownership
- backends, outputs, modesetting, and page flips
- allocation, swapchains, DMA-BUF, and synchronization
- input, seats, cursors, XWayland, and surface lifetimes
- the Vulkan instance, physical device, logical device, and queue

The replacement is deliberately limited to rounded window buffers, rounded
decoration outlines, and backdrop blur. Opacity already uses stock
`wlr_scene_buffer_set_opacity` and is not part of the Vulkan work.

The target is not a new `wlr_renderer` implementation. Aqueous should continue
to use wlroots' Vulkan renderer and add only the effect pipelines and metadata
that the stock render-pass API does not provide.

## Status

The baseline tooling and Vulkan backend/context foundation are implemented as
of 2026-07-23. The repository contains a deterministic effects fixture suite,
a nested SceneFX capture harness, opt-in scene timing and blur-cache event
instrumentation, and an exact inventory of the current invalidation behavior.

The harness was validated by producing reference captures at 1920×1080,
2560×1440, and 3840×2160. Generated artifacts include screencopies,
output/window state, environment and dependency versions, timing summaries,
logs, image statistics, and a portable checksum manifest.

The harness also captures isolated square-corner and compositor-clipped
variants, deterministic backdrop motion, a visible localized-damage control,
and localized damage wholly behind blur. That final SceneFX capture records the
known stale-cache behavior for ordinary-window damage. A custom Vulkan metrics
schema and aggregator are present, but correctly produce no samples until the
render seam owns real timestamp queries and the blur cache owns real counters.

`-Dvulkan-effects=true` now selects and verifies wlroots' Vulkan renderer,
borrows its Vulkan handles, reports physical-device capabilities, owns a
pipeline cache and fence-backed retirement queue, and follows initial startup,
normal teardown, and renderer-loss recreation. A nested RTX 5090 run completed
an atomic 1920×1080 modeset, screencopy, and clean context teardown.

The render-seam decision is accepted and implemented as an opt-in probe. A
pinned wlroots 0.20.2 patch exposes a narrow scene-buffer callback and the
active Vulkan pass; Aqueous records its rounded draw into wlroots' command
buffer without creating a renderer, device, queue, or second submission. The
full runtime harness recorded 4,110 draws, including 3 through the
OutputManager swapchain path and 4,107 through ordinary output rendering. All
4,110 used wlroots' output signal timeline. Screencopy, exact localized damage,
a 1.25 fractional scale, a 90-degree transform, and 4,096 releases and reuses
of one SHM buffer passed.

The current workstation still does not expose
`VK_LAYER_KHRONOS_validation`. The harness rejects validation messages and
requires the layer by default, but the validation-layer rerun remains the one
open Phase 2 gate. Renderer-loss recreation is wired and build-verified but has
not yet been forced on real hardware.

See [Effects reference capture](../compositor/doc/vulkan-effects-baseline.md)
for commands, fixture geometry, artifact descriptions, timing semantics, and
the current cache-invalidation inventory. See
[Use a narrow wlroots Vulkan render hook](architecture-decisions/0001-vulkan-render-seam.md)
for the render-seam decision.

## Scope

### In scope

- One radius applied to the client buffers belonging to a window
- Antialiased rounded client-buffer corners
- Antialiased rounded decoration rectangles
- A hollow rounded outline made from an outer rounded rect and clipped inner rect
- Window-local blur masks, including square masks when clipping cuts a window edge
- One damage-aware blur cache per output
- Preservation of corner metadata in saved and animation snapshot buffers
- Output scale, transform, clipping, opacity, and color metadata
- Effects in screencopy/capture output
- Renderer loss, output hotplug, modesets, and multi-output operation

### Out of scope

- SceneFX shadows, gradients, border gradients, and arbitrary effects
- A generic SceneFX-compatible ABI
- A new Wayland implementation or replacement for wlroots
- A complete Aqueous-owned scene renderer
- A GLES implementation
- Full HDR enablement

The internal image-format and color-metadata interfaces should not prevent a
future FP16/HDR path, but HDR is not a completion requirement for this project.

## Current-to-new replacement map

`compositor/aqueous/fx.zig` remains the public façade during the migration.
Callers should not import Vulkan or know which effect backend is active.

| Current operation | Current implementation | Replacement |
|---|---|---|
| `fx.createRenderer` | SceneFX uses `fx_renderer_create`; the Vulkan-effects build now forces and verifies wlroots Vulkan | Initialize the effect orchestration layer from the landed `VulkanContext` |
| `fx.setBufferRadius` | SceneFX field on `wlr_scene_buffer` | Radius metadata owned by Aqueous and consumed by the rounded-texture pipeline |
| `fx.setTreeRadius` | Walk tree and set SceneFX radii | Walk tree and update Aqueous buffer metadata |
| `fx.setRectRadius` | SceneFX field on `wlr_scene_rect` | Rect metadata plus the rounded-solid pipeline |
| `fx.setRectClippedRegion` | SceneFX clipped-region field | Inner SDF subtraction in the rounded-outline shader |
| `fx.setBlurParams` | SceneFX global blur data | `Effects.blur_config`, with generation-based cache invalidation |
| `fx.createWindowBlur` | SceneFX blur scene node | Aqueous `WindowBlur` metadata associated with the existing window tree |
| `fx.configureWindowBlur` | Mutate SceneFX blur node | Update the window blur box, radius, enabled bit, and generation |
| `fx.createOptimizedBlur` | SceneFX optimized blur node | Aqueous `BlurCache` owned by `Output` |
| `fx.configureOptimizedBlur` | Resize/enable SceneFX cache | Resize or enable the output cache and mark affected resources dirty |
| `fx.markOptimizedBlurDirty` | SceneFX dirty flag | Add damage to the cache or increment its conservative full-dirty generation |
| `fx.destroyOptimizedBlur` | Destroy SceneFX node | Defer Vulkan resource destruction until its last submission completes |
| `fx.copyBufferFx` | Copy SceneFX struct fields | Copy Aqueous metadata between live and saved scene buffers |
| `fx.setTreeOpacity` | Stock wlroots APIs | Keep unchanged |

Call-site replacements are intentionally small:

| Existing file | Change/status |
|---|---|
| `Window.zig` | Change `backdrop_blur` from `?*anyopaque` to a typed Aqueous handle; keep its existing geometry and enable logic |
| `Scene.zig` | Copy Aqueous effect metadata when cloning saved/animation buffers |
| `Output.zig` | Own `BlurCache`; call the effect-aware frame builder; retain the existing dirty triggers |
| `OutputManager.zig` | Use the same effect-aware frame builder for atomic modesets |
| `WindowManager.zig` | Store blur configuration in `Effects` and invalidate output caches |
| `LayerSurface.zig` | Keep the existing background-change invalidation call |
| `Server.zig` | Done for context lifetime: create on startup, destroy before the renderer, and replace around renderer-loss recovery; extend the same owner with effect resources |
| `build.zig` | Done: custom-effects option, mutual exclusion, Vulkan translation, and linking; remaining: shader compilation and SceneFX removal after rollout |

## Proposed source layout

```text
compositor/
├── aqueous/
│   ├── fx.zig                         compatibility façade and backend selection
│   └── render/
│       ├── Effects.zig                lifecycle, public API, and frame orchestration
│       ├── VulkanContext.zig          borrowed wlroots Vulkan handles and capabilities
│       ├── EffectMetadata.zig         buffer, rect, and window-effect registries
│       ├── EffectFrame.zig            per-output effect list, ordering, and damage
│       ├── RoundedPipeline.zig        rounded texture, solid, and outline pipelines
│       ├── BlurPipeline.zig           downsample, separable blur, and composite passes
│       ├── BlurCache.zig              per-output images, damage, generations, and lifetime
│       ├── DeferredDestroy.zig        fence/timeline-safe Vulkan resource retirement
│       └── shaders/
│           ├── fullscreen_triangle.vert
│           ├── rounded_texture.frag
│           ├── rounded_solid.frag
│           ├── rounded_outline.frag
│           ├── blur_downsample.frag
│           ├── blur_horizontal.frag
│           ├── blur_vertical.frag
│           └── blur_composite.frag
├── scripts/
│   └── test-vulkan-effects.sh         nested visual integration harness
└── doc/
    └── vulkan-effects-test-matrix.md  hardware and visual regression matrix
```

Keep effect metadata out of wlroots struct layouts. Use stable object identity
plus destruction listeners to remove registry entries. Prefer typed handles over
`anyopaque` once the Aqueous implementation is active.

Shader source is authoritative. Compile it to SPIR-V during the Zig build and
embed the result in the executable. Debug builds should enable Vulkan validation
when available, but validation must not be a runtime dependency.

Baseline support already present:

```text
compositor/
├── aqueous/
│   └── render_metrics.zig
├── scripts/
│   ├── capture-effects-baseline.sh
│   └── fixtures/
│       ├── visual-effects-reference.c
│       ├── visual-effects-rules.toml
│       └── visual-effects-wm.toml
└── doc/
    └── vulkan-effects-baseline.md
```

Vulkan context support now present:

```text
compositor/
├── aqueous/
│   └── render/
│       └── VulkanContext.zig
└── scripts/
    ├── test-vulkan-context.sh
    └── fixtures/
        └── exit-session.c
```

Render-seam support now present:

```text
.github/workflows/
└── vulkan-render-seam.yml
compositor/
├── aqueous/
│   └── render/
│       ├── RenderProbe.zig
│       └── shaders/
│           ├── render_probe.vert
│           └── render_probe.frag
├── patches/
│   └── wlroots/
│       └── 0001-aqueous-vulkan-render-hook.patch
└── scripts/
    ├── build-wlroots-render-hook.sh
    └── test-vulkan-render-seam.sh
```

Fence-backed retirement currently lives in `VulkanContext.zig`. Split it into
the proposed `DeferredDestroy.zig` only when the first production pipelines or
images need retirement; keeping the empty foundation together avoids an
abstraction with no independent caller.

## Render-seam decision gate

This is the first technical milestone because wlroots 0.20 exposes its Vulkan
instance, physical device, device, queue family, and texture images, but its
public render-pass operations only support ordinary textures and rectangles.
They do not expose a custom draw command, an active command buffer, rounded
metadata, or blur operations.

The spike must implement one rounded client buffer all the way to a committed
output and prove:

1. Aqueous can access the actual output render target at the correct time.
2. wlroots and Aqueous use compatible image layouts and queue ownership.
3. acquire and release synchronization remains correct with explicit sync.
4. output damage, buffer age, and screencopy see the finished effect.
5. the same path works in normal frames and `OutputManager` atomic modesets.

Choose one route at the end of the spike:

| Route | Decision |
|---|---|
| Public API plus a supported render hook | Rejected for wlroots 0.20; no public active-pass or custom-draw API exists |
| Small downstream wlroots hook | Selected: expose the scene-buffer callback and active Vulkan pass, keep all effect implementation in Aqueous, and pin the patch to wlroots 0.20.2 |
| Reimplement `wlr_scene_output_build_state` | Reject for this project unless the first two routes are impossible; it expands the work into scene traversal, occlusion, presentation, damage, direct scanout, and color handling |
| Replace `wlr_renderer` | Reject; it contradicts the goal of using wlroots' Vulkan renderer and allocator |

The decision, synchronization evidence, and captured test frame are recorded in
the architecture decision. Production blur work remains gated on the pending
Khronos-validation-layer run.

## Target frame flow

The selected render seam should produce this logical order:

1. Apply the existing frame-boundary visual-state synchronization.
2. Ask wlroots to acquire/prepare the output buffer and damage.
3. Collect effect metadata for visible nodes in scene order.
4. Expand damage by the blur kernel and intersect it with the output.
5. Render unaffected scene content through wlroots.
6. At each blur checkpoint, sample only content already below that window.
7. Update only dirty blur-cache regions, with a conservative full-output fallback.
8. Composite the blurred backdrop through the window's rounded mask.
9. Render the window content and decorations with rounded pipelines.
10. Complete the wlroots output state, explicit-sync signal point, capture, and commit.

The blur source must never include the window currently receiving the blur.
Overlapping blurred windows must follow scene order, not a global
"blur the final framebuffer" shortcut.

## Implementation steps

### Phase 0 — Freeze behavior and establish a baseline

Estimate: 3–5 engineer-days.

Status: all baseline fixtures and comparisons that can be implemented before
the custom render seam are complete. Custom GPU/cache measurement remains
assigned to the Vulkan rendering and cache implementation that can own the
underlying timestamp queries and counters.

- [x] Record the exact wlroots, SceneFX, Zig, Wayland, kernel, Vulkan loader,
      Vulkan device, and driver versions.
- [x] Capture rounded, blurred, opaque, and alpha-composited reference images at
      1080p, 1440p, and 4K.
- [x] Record wlroots scene-preparation timings and SceneFX cache creation,
      dirty-request, enable, disable, and destruction events at all three modes.
- [x] Record GPU-timer availability without treating unavailable or disjoint
      SceneFX GLES queries as valid measurements.
- [x] Add a deterministic visual test client with solid colors, alpha gradients,
      high-frequency backdrop content, and known geometry.
- [x] Document all existing blur invalidation paths and explicitly record that
      ordinary window and workspace damage is above the optimized backdrop
      cache rather than a cache-invalidating source.
- [x] Confirm `-Dscenefx=false` remains a clean square/no-blur fallback, is not
      linked to SceneFX, passes unit tests, and passes the XDG fullscreen
      integration regression.
- [x] Add explicit square-corner and compositor-clipped visual variants before
      rounded-pipeline golden comparisons begin.
- [x] Add controlled backdrop motion and localized damage before cached-blur
      correctness work begins.
- [ ] Capture true GPU duration and cache rebuild/hit counts from the custom
      Vulkan implementation, where timestamp queries and cache counters are
      owned by Aqueous.

Exit condition: repeatable reference captures and timings exist before rendering
code changes. This condition is met. The harness accepts real Vulkan GPU/cache
samples without inventing SceneFX equivalents; populating those samples remains
dependent on the rendering and cache code introduced in later phases.

### Phase 1 — Add backend selection and the Vulkan context

Estimate: 1–2 weeks.

Status: implementation and functional real-GPU validation complete. A
Khronos-validation-layer rerun remains pending because the layer is not
installed on the current workstation. Renderer-loss recreation is implemented
but still needs an injected-reset runtime test.

- [x] Add `-Dvulkan-effects=true|false`; initially make it mutually exclusive
      with `-Dscenefx=true`.
- [x] When selected, request or verify a wlroots Vulkan renderer and fail at
      startup with a precise error if it is unavailable.
- [x] Add Vulkan header translation/linking without creating a second instance,
      device, or queue.
- [x] Implement `VulkanContext` using borrowed wlroots handles.
- [x] Query required format, sampling, synchronization, and timestamp features.
- [x] Add pipeline-cache creation and fence-safe deferred destruction.
- [x] Add renderer-loss teardown/recreation hooks in both `Server.zig` paths.

Implementation record:

| Area | Result |
|---|---|
| Backend selection | `-Dvulkan-effects=true` disables SceneFX auto-selection, forces `WLR_RENDERER=vulkan`, and verifies `wlr_renderer_is_vk` |
| Ownership | Instance, physical device, logical device, queue family, and queue are borrowed; Aqueous creates no second Vulkan device or queue |
| Aqueous-owned state | Pipeline cache, retirement fences, and the deferred-resource list |
| Capability query | FP16/BGRA8 sampled and color-attachment support, linear filtering, anisotropy support, wlroots timeline support, physical timeline/synchronization2 support, and timestamp availability/period |
| Normal lifetime | Context is created after the renderer and destroyed before the renderer |
| Recovery lifetime | Replacement context is created before the renderer swap; the old context is destroyed before the old renderer |
| Failure behavior | Renderer selection, borrowed-handle, queue, pipeline-cache, and recovery failures retain distinct error names and diagnostics |

Treat the queried timeline-semaphore and synchronization2 values as physical
device support only. They do not prove that wlroots enabled those features when
creating the borrowed logical device. The render-seam probe therefore does not
issue Aqueous-owned timeline, synchronization2, command-buffer, or queue
operations. It records into wlroots' active pass, whose output signal timeline
was present on every tested draw. Fence submission remains the only
Aqueous-owned retirement mechanism approved for later resources.

Exit condition: Aqueous runs with stock visuals on wlroots Vulkan, survives an
output modeset, and creates/destroys its empty effects context without validation
errors. The functional portion passes on the named reference hardware. The
harness rejects validation messages and VUIDs, but must be rerun on a host with
the Khronos validation layer installed to close the remaining validation gate.
An injected renderer-loss run is also required before renderer recovery can be
called runtime-validated rather than implementation-verified.

### Phase 2 — Prove and select the render seam

Estimate: 2–3 weeks.

Status: implementation and functional real-GPU validation complete. The
selected seam records Aqueous commands into wlroots' active render pass and
submission. It uses the borrowed context and creates no replacement renderer,
instance, device, queue, command buffer, target image, or submission. The
Khronos-validation-layer rerun remains pending because the layer is not
installed on the current workstation.

- [x] Prototype a custom fragment pipeline that changes one known scene buffer.
- [x] Test it through both `Output.renderAndCommit` and the
      `OutputManager` swapchain-manager path.
- [x] Prove transforms, fractional scaling, damage, explicit sync, and capture.
- [ ] Test buffer reuse for at least several thousand frames under validation.
- [x] Write a short architecture decision record choosing the route above.
- [x] Package and CI-build any wlroots patch as a pinned, auditable dependency.
- [x] Remove unsafe spike shortcuts before moving on.

Implementation record:

| Area | Result |
|---|---|
| Seam | Scene-buffer callback runs after wlroots' ordinary texture draw while the same Vulkan pass is active |
| Vulkan ownership | Aqueous borrows wlroots handles and records into its command buffer; no second submission is created |
| Pipeline safety | Requesting pass attributes invalidates wlroots' cached pipeline binding, forcing the next wlroots draw to rebind |
| Output paths | Final counters recorded 4,107 normal draws and 3 OutputManager swapchain draws |
| Coordinates and damage | wlroots supplies the transformed destination and clip; the localized case changed exactly 19,200 pixels in `160x120+440+320` |
| Synchronization | All 4,110 recorded draws were part of a pass with wlroots' output signal timeline |
| Capture | The rounded buffer is visible in ordinary and transformed screencopies |
| Reuse | One released SHM buffer completed 4,096 paced repaint/commit/release cycles |
| Dependency | Official wlroots 0.20.2 archive, fixed SHA-256, versioned patch, API macro check, reproducible build script, and CI build |

Exit condition: a rounded test buffer is visible in a screencopy and no Vulkan
layout, lifetime, or synchronization warnings occur. The functional and
explicit-sync portions pass. No warning or VUID was logged, but the validation
layer was unavailable, so this condition is not fully closed until the default
`scripts/test-vulkan-render-seam.sh` run passes on a host with
`VK_LAYER_KHRONOS_validation`.

### Phase 3 — Move SceneFX state into Aqueous metadata

Estimate: 4–7 engineer-days.

- [ ] Implement typed metadata for scene buffers, scene rects, window blur masks,
      and output blur caches.
- [ ] Attach destroy listeners so pointer reuse cannot resurrect stale metadata.
- [ ] Preserve metadata in `Scene.SaveableSurfaces.save` and `cloneInto`.
- [ ] Keep the existing `fx.zig` function names while routing them to the new backend.
- [ ] Add generation counters for blur configuration and cache invalidation.
- [ ] Add leak and stale-handle tests.

Exit condition: every current SceneFX call has an Aqueous-owned equivalent even
though most still render as stock visuals.

### Phase 4 — Implement rounded corners and borders

Estimate: 2–3 weeks.

- [ ] Implement a scale-correct signed-distance rounded-rectangle mask.
- [ ] Add premultiplied-alpha antialiasing for client textures.
- [ ] Respect source boxes, destination sizes, transforms, clips, opacity,
      sampling mode, and color metadata.
- [ ] Clamp radii to half the short side exactly once in CPU-side metadata.
- [ ] Implement rounded solid rects.
- [ ] Implement the hollow outline as outer SDF minus inner SDF so no seam appears.
- [ ] Ensure a clipped window edge becomes square, matching current behavior.
- [ ] Ensure hit testing and opaque regions remain based on the normal scene graph.
- [ ] Disable direct scanout only when a visible effect actually requires composition.

Exit condition: reference captures match within an agreed pixel tolerance at
1×, 1.25×, 1.5×, and 2× scale, including rotated outputs.

### Phase 5 — Implement correct uncached backdrop blur

Estimate: 3–5 weeks.

- [ ] Start with one output and one blurred window.
- [ ] Capture only the already-rendered background beneath the window.
- [ ] Implement downsample, horizontal, vertical, and upsample/composite passes.
- [ ] Define how the existing `radius` and `passes` configuration maps to kernel
      size and pass count; preserve current visual behavior where practical.
- [ ] Expand source regions for kernel reach and clamp safely at output edges.
- [ ] Apply the window's rounded or square mask during composite.
- [ ] Verify translucent client content blends above, rather than becoming part
      of, its own backdrop.
- [ ] Add overlapping and nested-order test cases before optimizing.

Exit condition: blur is visually correct under moving content, multiple windows,
alpha, clipping, transforms, and mixed output scales with caching disabled.

### Phase 6 — Add the per-output blur cache and damage model

Estimate: 3–6 weeks.

- [ ] Move the cache lifetime into `Output`.
- [ ] Allocate cache images in output pixel coordinates and reallocate on mode,
      scale, transform, or format changes.
- [ ] Convert existing `markBlurDirty` triggers into explicit cache damage.
- [ ] Expand cache damage by every blur level's kernel radius.
- [ ] Track scene/config generations to prevent stale reuse.
- [ ] Support partial updates where safe.
- [ ] Keep a full-output invalidation path for uncertain scene changes.
- [ ] Skip all cache work when no visible window requests blur.
- [ ] Add counters for cache hits, partial rebuilds, full rebuilds, and pixels processed.
- [ ] Retire replaced cache images only after the last GPU submission completes.

Exit condition: static frames do not rebuild the cache, localized background
damage does not leave stale pixels, and the optimized result matches the
uncached reference.

### Phase 7 — Integrate all compositor paths

Estimate: 2–4 weeks.

- [ ] Saved transaction buffers and position-animation snapshots preserve radii.
- [ ] Workspace animation does not continuously invalidate an unrelated background.
- [ ] Popups, subsurfaces, layer shell, fullscreen, session lock, and XWayland render correctly.
- [ ] Atomic output configuration uses the same effect frame builder as normal commits.
- [ ] Screencopy and output capture include the final composited effects.
- [ ] Output add/remove, suspend/resume, GPU reset, and renderer recreation rebuild resources.
- [ ] Multi-output windows use output-local scale, transform, damage, and caches.
- [ ] Direct scanout returns when no visible effects require composition.

Exit condition: the full visual matrix passes and all existing compositor
integration scripts still pass.

### Phase 8 — Performance, rollout, and SceneFX removal

Estimate: 4–8 weeks.

- [ ] Compare GPU time, bandwidth, allocations, and missed frames against the Phase 0 baseline.
- [ ] Avoid device-idle waits in normal rendering and resource destruction.
- [ ] Reuse descriptor sets, samplers, pipelines, command resources, and cache images.
- [ ] Test AMD, Intel, and NVIDIA; include at least one integrated and one discrete GPU.
- [ ] Test single-GPU and multi-GPU scanout/import paths.
- [ ] Run an opt-in A/B period with `scenefx` and `vulkan-effects` builds.
- [ ] Make Vulkan effects the default only after a full stable test cycle.
- [ ] Remove SceneFX linking, headers, renderer creation, and build detection.
- [ ] Keep `-Dvulkan-effects=false` as the square/no-blur diagnostic build.

Exit condition: custom effects are the default, SceneFX is absent from the
runtime dependency graph, and the fallback build still works.

## Test plan

### Unit tests

- Radius clamping and per-corner SDF inputs
- Inner/outer outline geometry
- Logical-to-pixel coordinate conversion
- Output transform and clip conversion
- Blur kernel reach and damage expansion
- Cache state transitions and generation invalidation
- Metadata copy and destruction-listener cleanup
- Direct-scanout eligibility with effects enabled and disabled

### Automated visual cases

Use `scripts/capture-effects-baseline.sh` for the current SceneFX reference and
extend it into the Vulkan golden-image harness. It selects a nested real-pixel
Wayland backend when available. The current headless tests remain useful for
protocol behavior but cannot validate pixels.

| Axis | Cases |
|---|---|
| Scale | 1.0, 1.25, 1.5, 2.0 |
| Transform | normal, 90°, 180°, 270° |
| Corners | 0, small, default, clamped-to-half-size |
| Borders | square, rounded, hollow, clipped on each edge |
| Buffers | opaque RGB, premultiplied alpha, subsurfaces, cropped source box |
| Blur | off, one window, overlapping windows, translucent window, clipped window |
| Motion | moving background, moving blurred window, workspace and position animations |
| Outputs | resize, scale change, transform change, hotplug, mixed-scale pair |
| Shells | XDG, XWayland, layer shell, fullscreen, session lock |
| Capture | screencopy and any internal output capture |

Keep uncached blur as a test oracle for cached blur. Golden comparisons should
use a small documented tolerance around antialiased and blurred edges and exact
comparison elsewhere.

### Existing regression suite

Run at minimum:

```sh
zig build test -Dllvm=true
scripts/test-policy-parity.sh
scripts/test-scaling.sh
scripts/test-scrolling-viewport.sh
scripts/test-window-lifecycle.sh
scripts/test-xdg-fullscreen.sh
scripts/test-xwayland-input.sh
```

Current validation record:

- `zig build -Dcpu=baseline -Doptimize=ReleaseSafe -Dscenefx=true`
- `scripts/capture-effects-baseline.sh` at 1080p, 1440p, and 4K
- The expanded capture passes at 1080p, 1440p, and 4K with square, clipped,
  motion, visible localized-control, and behind-blur localized-damage artifacts;
  every generated checksum verifies
- `zig build test -Dllvm=true -Dscenefx=false`
- `zig build -Dcpu=baseline -Doptimize=ReleaseSafe -Dscenefx=false`
- `ldd zig-out/bin/aqueous` confirms no SceneFX dependency in the fallback build
- `scripts/test-xdg-fullscreen.sh` passes against the fallback build
- All capture artifacts pass `SHA256SUMS`
- `zig build test`
- `zig build -Dscenefx=true -Dvulkan-effects=false -Dcpu=baseline
  -Doptimize=ReleaseSafe`
- `zig build -Dscenefx=false -Dvulkan-effects=false -Dcpu=baseline
  -Doptimize=ReleaseSafe`
- `zig build -Dvulkan-effects=true -Dexternal-policy=true -Dcpu=baseline
  -Doptimize=ReleaseSafe`
- `-Dvulkan-effects=true -Dscenefx=true` fails with the expected mutual-exclusion
  error
- `readelf -d` confirms the Vulkan build directly needs `libvulkan` and not
  SceneFX, while SceneFX and stock fallback builds keep their intended direct
  dependencies
- `scripts/test-vulkan-context.sh` passes on an NVIDIA GeForce RTX 5090 with
  Vulkan 1.4.341, including a 1920×1080 atomic modeset, screencopy, and clean
  context teardown
- `scripts/build-wlroots-render-hook.sh` reproduces the patched wlroots 0.20.2
  library from the pinned official archive and exports both versioned hook
  symbols
- the render-probe build succeeds against that reproduced dependency while
  ordinary Vulkan-effects and effects-disabled builds continue to compile
- `AQUEOUS_VULKAN_PROBE_REQUIRE_VALIDATION=0
  scripts/test-vulkan-render-seam.sh` passes 4,096 buffer-reuse frames on the
  RTX 5090, recording 4,107 ordinary draws, 3 swapchain draws, and 4,110
  explicit-sync draws
- the rounded, localized-damage, transformed/fractional-scale, and post-stress
  screencopies pass their assertions and every generated checksum verifies
- The Khronos validation layer was not installed for that run; the harness will
  require it by default and reject validation errors when available

The Vulkan runtime harnesses require a test build with
`-Dexternal-policy=true` and run `-policy compare` only so their private fixture
can request a graceful session exit. Internal Aqueous policy still performs the
rendering and modesets. Production Vulkan builds remain
`-Dexternal-policy=false`.

To repeat the functional run:

```sh
zig build -Dvulkan-effects=true -Dexternal-policy=true \
  -Dcpu=baseline -Doptimize=ReleaseSafe
scripts/test-vulkan-context.sh
```

To close the remaining Phase 1 and Phase 2 validation gates, install the
Khronos validation layer and run both Vulkan harnesses without override
variables. Close acceptance only if the logs contain no validation errors or
VUIDs. Keep the renderer-loss runtime test tracked separately until a
deterministic reset-injection method exists.

### Performance gates

The current reference records CPU-side scene preparation on named hardware.
SceneFX GPU timing is explicitly reported as unavailable when its GLES query
cannot provide a valid result. Set GPU thresholds after Vulkan timestamp queries
are operational. Initial gates:

- No continuous cache rebuild on an unchanged frame.
- No full-output rebuild for localized damage when the partial path is enabled.
- No per-frame Vulkan allocation in steady state.
- No `vkDeviceWaitIdle` in steady-state rendering.
- No new missed-frame pattern at 4K60 relative to SceneFX.
- Effects-disabled performance remains within measurement noise of stock wlroots.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| wlroots has no sufficient public insertion point | Resolved with the pinned, versioned active-pass hook; reassess it at each wlroots upgrade |
| Incorrect Vulkan layout or queue synchronization | Borrow wlroots handles, use its synchronization contract, run validation and explicit-sync stress tests |
| Blur samples itself or content above the window | Use scene-ordered blur checkpoints and test overlapping translucent windows |
| Partial damage leaves stale cache pixels | Expand by kernel reach and fall back to generation-based full invalidation |
| Output changes invalidate resources in flight | Use deferred destruction tied to fences/timeline points |
| Direct scanout silently bypasses effects | Mark effect-bearing frames as composition-required; restore scanout when effects are absent |
| Capture differs from displayed output | Insert effects before the final output state is committed and test screencopy |
| Color/HDR work later requires a rewrite | Carry wlroots color metadata through effect draws and make intermediate format selection configurable |
| Downstream wlroots patch becomes expensive | Keep the hook small, add a compile-time API check, and reassess at every wlroots upgrade |

## Effort and staffing

For one engineer familiar with Aqueous, wlroots, and Vulkan:

| Outcome | Expected effort |
|---|---|
| Rounded-corner prototype | 3–6 weeks, including the render-seam spike |
| Correct rounded corners and uncached blur | 8–13 weeks |
| Feature parity with damage-aware cached blur | 12–20 weeks |
| Production hardening and broad GPU coverage | 20–32 weeks total |
| Remaining work from the completed context foundation | 15–30 weeks, dominated by the render seam, blur correctness, and hardware coverage |

The render seam and synchronization are the largest schedule uncertainty.
Rounded corners alone are a modest shader task after that seam exists. Correct,
damage-aware backdrop blur is most of the implementation and validation effort.

Two engineers can shorten hardware testing and blur optimization, but the
render-seam and frame-order design should have one owner to avoid incompatible
assumptions.

## First working sprint

The first sprint should end with evidence, not production shaders:

- [x] Add `-Dvulkan-effects` and enforce the backend-selection rules.
- [x] Add `VulkanContext` and log the borrowed device and queue capabilities.
- [x] Add empty effects initialization, renderer-loss teardown, and recreation.
- [x] Create the deterministic visual test client and save SceneFX references.
- [x] Exercise an atomic modeset and screencopy through wlroots Vulkan.
- [x] Exercise normal context creation and clean teardown on real hardware.
- [ ] Rerun the context harness with the Khronos validation layer enabled.
- [ ] Inject renderer loss and verify context recreation on real hardware.
- [x] Prototype a single rounded quad over a known scene buffer on the output path.
- [x] Exercise the rounded prototype through normal commit and fractional scale.
- [x] Run the explicit-sync buffer-reuse stress test for 4,096 frames.
- [ ] Rerun the render-seam harness with the Khronos validation layer enabled.
- [x] Write the render-seam decision record.

The public wlroots 0.20 API was insufficient. The selected downstream hook and
its maintenance boundary are recorded in the architecture decision.

## Definition of done

- SceneFX is no longer built, linked, loaded, or required.
- Rounded client buffers and rounded hollow borders match the approved references.
- Backdrop blur is scene-order correct and does not self-sample.
- Static and partially damaged scenes reuse the per-output blur cache correctly.
- Scale, transform, clipping, opacity, animations, and XWayland pass the matrix.
- Effects appear in capture output and recover after modesets, hotplug, and renderer loss.
- No Vulkan validation errors, stale metadata, resource leaks, or steady-state device-idle waits remain.
- The no-effects build continues to render correctly through stock wlroots.
