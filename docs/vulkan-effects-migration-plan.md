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
known stale-cache behavior for ordinary-window damage. The Vulkan metrics
schema now receives real blur-cache hit, rebuild, and pixel counters; GPU
duration remains zero until timestamp-query ownership is implemented.

`-Dvulkan-effects=true` now selects and verifies wlroots' Vulkan renderer,
borrows its Vulkan handles, reports physical-device capabilities, owns a
pipeline cache and fence-backed retirement queue, and follows initial startup,
normal teardown, and renderer-loss recreation. A nested RTX 5090 run completed
an atomic 1920×1080 modeset, screencopy, and clean context teardown.

The render-seam decision is accepted and implemented in the production
Vulkan-effects build. A pinned wlroots 0.20.2 patch exposes narrow texture and
rectangle replacement callbacks plus the active Vulkan pass; Aqueous records
into wlroots' command buffer without creating a renderer, device, queue, or
second submission. The original probe established synchronization and capture
behavior before the production pipelines replaced it.

The current workstation still does not expose
`VK_LAYER_KHRONOS_validation`. The harness rejects validation messages and
requires the layer by default, but the validation-layer rerun remains the one
open Phase 2 gate. Renderer-loss recreation is wired and build-verified but has
not yet been forced on real hardware.

Effect state is now owned by Aqueous independently of the Vulkan context.
`EffectMetadata.zig` provides destruction-aware registries for scene buffers
and rects, generation-safe typed handles for window blur masks and output blur
caches, and generation counters for global blur configuration and cache
invalidation. The existing `fx.zig` entry points route to either SceneFX or the
Aqueous registry, while saved and animation snapshot buffers preserve metadata
through their existing copy path. The metadata registry survives renderer-loss
context replacement and is torn down after the scene graph.

Rounded corners and decoration outlines are now rendered by Aqueous-owned
Vulkan pipelines. The production seam replaces wlroots texture and rectangle
draws after wlroots prepares the source descriptor, sampling state, transform,
color metadata, clip, and synchronization. CPU-side radii are scale-correct and
clamped, fragment coverage is premultiplied and antialiased, and one SDF
subtracts the inner rounded shape from the outer shape for seamless outlines.

The nested RTX 5090 production run passed 4,096 reused-buffer frames at scales
1, 1.25, 1.5, and 2 with 90°, 180°, and 270° rotations. It recorded 4,116
rounded-texture draws and 4,116 rounded-rect draws: 8,222 through normal output
rendering, 10 through OutputManager swapchain rendering, and all 8,232 on
wlroots' explicit-sync output timeline. The localized update remained exactly
`160x120+440+320`. A validation-layer rerun and a formal SceneFX golden-image
tolerance comparison remain open validation items.

Uncached backdrop blur is now implemented in the Vulkan-effects build. The
wlroots seam pauses its forced linear two-pass target at a scene-node
checkpoint, exposes only pixels already rendered below that node, and resumes
the same render pass and submission after Aqueous records its offscreen work.
Aqueous downsamples the full output into an FP16 half-resolution image, applies
the configured horizontal and vertical passes, linearly upsamples during
composite, and masks the result with transformed rounded or square window
geometry before wlroots draws that window's translucent content.

A 2026-07-24 nested RTX 5090 run passed live backdrop motion, localized damage,
overlapping blur windows, screencopy, scales 1, 1.25, 1.5, and 2, rotations 90°,
180°, and 270°, normal and OutputManager swapchain rendering, explicit sync,
and 64 reused-buffer frames. It recorded 376 scene-ordered checkpoints, 6,392
offscreen draws, and 376 composites. The localized `160x120` source update
affected `186x147+428+308` after blur, demonstrating kernel expansion. All
capture checksums verify. Validation-layer and mixed-output hardware runs
remain open.

The per-output blur cache and damage model are now implemented. Each output
owns persistent half-resolution FP16 checkpoints keyed by generation-safe
window blur identity, preserving scene order for overlapping windows without
self-sampling. Ordinary scene damage is expanded before wlroots computes the
render and output damage, then each separable pass walks its exact dependencies
backward to update only the required cache rectangle. Mode, scale, transform,
effect geometry, blur configuration, and explicit invalidation changes force
safe rebuilds.

Cache images are retired through callbacks attached to wlroots' own Vulkan
command-buffer timeline, including reset and submission-failure paths; ordinary
cache replacement does not submit an Aqueous queue operation or wait for the
device. `AQUEOUS_VULKAN_BLUR_UNCACHED=1` retains the full-output implementation
as an oracle. A 64-frame cached RTX 5090 run recorded 15 preserved-cache hits,
71 partial rebuilds, 10 full rebuilds, and 51,054,704 processed half-resolution
pixels. The localized update affected `194x154+423+303`, all harness checks and
capture checksums passed, and cached-versus-uncached image mean differences
stayed below `0.00005`.

The compositor-path integration is now implemented. Normal commits and atomic
output configuration share one frame builder, saved transaction and animation
buffers retain their current radii, and animation damage is left to precise
scene-node movement instead of invalidating the whole output. Blur discovery
and buffer-state synchronization cover every output intersected by a window,
while each output retains its own transform, scale, damage, and cache state.
Direct scanout is blocked only when a visible rounded corner or backdrop blur
requires composition.

The expanded 64-frame cached and uncached RTX 5090 matrix passes popup and
subsurface content, workspace transitions, output disable/resume, screencopy,
atomic modesets, four scales, four transforms, overlap, damage, and buffer
reuse. Layer-shell capture, session-lock presentation, fullscreen, lifecycle,
mixed-output scrolling, scaling, policy parity, and managed and
override-redirect XWayland rendering also pass. Physical output hotplug,
forced GPU reset, mixed-scale cross-output blur, and direct-scanout restoration
still require suitable hardware or deterministic fault injection; the code
lifecycle for those paths is implemented and audited.

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
| `fx.setBlurParams` | SceneFX global blur data | `EffectMetadata.blur_config`, with generation-based cache invalidation |
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
| `Window.zig` | Done: `backdrop_blur` is a typed backend handle and retains the existing geometry and enable logic |
| `Scene.zig` | Done: saved and animation buffers copy Aqueous effect metadata through `fx.copyBufferFx` |
| `Output.zig` | Done through cached blur: owns output-local cache lifetime, visibility, damage, generation state, and counters while sharing the pipelines with normal frames |
| `OutputManager.zig` | Done through cached blur: atomic modesets use the same hooks, cache rebuild rules, expanded damage, and swapchain path |
| `WindowManager.zig` | Done for metadata: store generation-tracked blur configuration and invalidate output caches |
| `LayerSurface.zig` | Done: keep the backend-neutral trigger; Vulkan uses wlroots scene damage while SceneFX keeps its explicit invalidation |
| `Server.zig` | Done through cached blur: release output cache ownership before renderer-loss context replacement and rebuild lazily on the new context |
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
│           ├── rounded_texture.vert
│           ├── rounded_texture.frag
│           ├── rounded_rect.vert
│           ├── rounded_rect.frag
│           ├── fullscreen_triangle.vert
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

Vulkan render-seam and effect-pipeline support now present:

```text
.github/workflows/
└── vulkan-render-seam.yml
compositor/
├── aqueous/
│   └── render/
│       ├── BlurPipeline.zig
│       ├── RoundedPipeline.zig
│       └── shaders/
│           ├── blur_composite.frag
│           ├── blur_composite.vert
│           ├── blur_downsample.frag
│           ├── blur_fullscreen.vert
│           ├── blur_separable.frag
│           ├── rounded_texture.vert
│           ├── rounded_texture.frag
│           ├── rounded_rect.vert
│           └── rounded_rect.frag
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

The decision, synchronization evidence, rounded captures, and uncached-blur
extension are recorded in the architecture decision. Cached-blur acceptance
remains gated on the pending Khronos-validation-layer run.

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
creating the borrowed logical device. The effects renderer therefore does not
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
| Seam | wlroots prepares the texture descriptor and render state, then a one-shot callback may replace the stock draw in the same active pass; rectangles have a matching replacement hook |
| Vulkan ownership | Aqueous borrows wlroots handles and records into its command buffer; no second submission is created |
| Pipeline safety | Custom draws invalidate wlroots' cached pipeline binding, and wlroots retains common texture lifetime, damage, and synchronization bookkeeping |
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

- [x] Implement typed metadata for scene buffers, scene rects, window blur masks,
      and output blur caches.
- [x] Attach destroy listeners so pointer reuse cannot resurrect stale metadata.
- [x] Preserve metadata in `Scene.SaveableSurfaces.save` and `cloneInto`.
- [x] Keep the existing `fx.zig` function names while routing them to the new backend.
- [x] Add generation counters for blur configuration and cache invalidation.
- [x] Add leak and stale-handle tests.

Exit condition: every current SceneFX call has an Aqueous-owned equivalent even
though most still render as stock visuals. Met on 2026-07-23; the registry
lifecycle suite includes destruction, pointer reuse, snapshot copying, stale
generation rejection, cache invalidation, and forced cleanup coverage.

### Phase 4 — Implement rounded corners and borders

Estimate: 2–3 weeks.

Status: implementation and functional real-GPU validation complete. The
production pipeline passes normal and swapchain rendering, screencopy, exact
localized damage, scales 1, 1.25, 1.5, and 2, rotations 90°, 180°, and 270°,
explicit synchronization, and 4,096 buffer reuse cycles. The Khronos validation
layer and formal SceneFX golden-image tolerance comparison remain pending.

- [x] Implement a scale-correct signed-distance rounded-rectangle mask.
- [x] Add premultiplied-alpha antialiasing for client textures.
- [x] Respect source boxes, destination sizes, transforms, clips, opacity,
      sampling mode, and color metadata.
- [x] Clamp radii to half the short side exactly once in CPU-side metadata.
- [x] Implement rounded solid rects.
- [x] Implement the hollow outline as outer SDF minus inner SDF so no seam appears.
- [x] Ensure a clipped window edge becomes square, matching current behavior.
- [x] Ensure hit testing and client opaque-region metadata remain based on the
      normal scene graph; only effect-bearing nodes are forced through blending
      so transparent shader pixels cannot cull content below.
- [x] Disable direct scanout only when a visible effect actually requires composition.

Exit condition: reference captures match within an agreed pixel tolerance at
1×, 1.25×, 1.5×, and 2× scale, including rotated outputs. The scale/rotation
matrix and exact pixel assertions pass; closing this condition still requires
recording the agreed SceneFX comparison tolerance.

### Phase 5 — Implement correct uncached backdrop blur

Estimate: 3–5 weeks.

Status: implementation and single-output functional hardware validation are
complete. The path deliberately does no content caching: it reprocesses the
full output at every visible blurred-window checkpoint. A validation-layer run,
formal SceneFX tolerance comparison, clipped-window capture, and mixed-output
hardware matrix remain open acceptance work.

- [x] Start with one output and one blurred window.
- [x] Capture only the already-rendered background beneath the window.
- [x] Implement downsample, horizontal, vertical, and upsample/composite passes.
- [x] Define how the existing `radius` and `passes` configuration maps to kernel
      size and pass count; preserve current visual behavior where practical.
- [x] Expand source regions for kernel reach and clamp safely at output edges.
- [x] Apply the window's rounded or square mask during composite.
- [x] Verify translucent client content blends above, rather than becoming part
      of, its own backdrop.
- [x] Add overlapping and nested-order test cases before optimizing.

Implementation record:

| Area | Result |
|---|---|
| Scene order | A render-begin hook resets output-local traversal state; the first renderable node in each visible window tree creates one checkpoint before any content from that window is drawn |
| wlroots seam | The Vulkan renderer is forced through its FP16 linear two-pass path; the seam finishes the current pass, exposes the sampled linear image, records Aqueous work, transitions it back, and resumes the same pass and command buffer with load preservation |
| Blur pipeline | One full-output downsample plus `passes` horizontal/vertical iterations in half-resolution FP16 images; the rounded composite's linear sampler performs the upsample |
| Configuration | Passes are clamped to 1–16; logical radius is scaled to output pixels and converted to a half-resolution sample step; exact tap support is reported as conservative kernel reach |
| Edges and damage | The uncached implementation processes the whole output and uses clamp-to-edge sampling, so every expanded source region is available; any visible blur promotes the frame to full output damage |
| Mask and alpha | Window-local blur geometry reuses existing clipping state, becomes square when clipping cuts an edge, and is transformed before SDF masking; wlroots draws translucent client buffers afterward |
| Resource safety | Scratch images are keyed by source image view and extent, preventing separate outputs or in-flight swapchain buffers from sharing writable ping-pong images |
| Validation | The 64-frame hardware run produced 376 checkpoints, 6,392 offscreen draws, and 376 composites; motion, localized expansion, overlap, transforms, fractional scales, explicit sync, and checksummed screencopy passed |

Exit condition: blur is visually correct under moving content, multiple windows,
alpha, clipping, transforms, and mixed output scales with caching disabled.
Motion, multiple windows, alpha, transforms, fractional scales, and uncached
operation pass on the reference hardware. Close the condition after the
clipped-window, mixed-output, SceneFX-tolerance, and validation-layer runs.

### Phase 6 — Add the per-output blur cache and damage model

Estimate: 3–6 weeks.

- [x] Move the cache lifetime into `Output`.
- [x] Allocate cache images in output pixel coordinates and reallocate on mode,
      scale, transform, or format changes.
- [x] Convert existing `markBlurDirty` triggers into explicit cache damage.
- [x] Expand cache damage by every blur level's kernel radius.
- [x] Track scene/config generations to prevent stale reuse.
- [x] Support partial updates where safe.
- [x] Keep a full-output invalidation path for uncertain scene changes.
- [x] Skip all cache work when no visible window requests blur.
- [x] Add counters for cache hits, partial rebuilds, full rebuilds, and pixels processed.
- [x] Retire replaced cache images only after the last GPU submission completes.

Implementation record:

| Area | Result |
|---|---|
| Ownership | `Output` owns one cache collection; each visible blurred window has a persistent scene-order checkpoint in output pixel coordinates |
| Damage | The scene hook receives original buffer-space damage, returns the required kernel expansion to wlroots, and uses the unexpanded bounds to plan partial cache work |
| Partial updates | Half-resolution scissor rectangles are derived backward through every horizontal and vertical pass; only the final affected rectangle is copied into the persistent image |
| Invalidation | Stable window identity, window/config/output generations, transformed geometry, kernel parameters, and output extent prevent stale reuse; uncertain changes retain a full rebuild path |
| Lifetime | Cache use increments a resource reference tied to the active wlroots command buffer; completion, reset, and renderer teardown release it before retired Vulkan images are destroyed |
| Observability | Per-output frame metrics and pipeline totals report preserved hits, partial rebuilds, full rebuilds, and processed pixels |
| Oracle | `AQUEOUS_VULKAN_BLUR_UNCACHED=1` rebuilds every checkpoint; `scripts/test-vulkan-effects.sh` runs both modes and checks selected captures within a configurable tolerance |
| Validation | 162 unit tests pass; cached and uncached 64-frame RTX 5090 runs pass motion, localized damage, overlap, four scales, rotations, capture, atomic modesets, and checksum verification |

Exit condition: static frames do not rebuild the cache, localized background
damage does not leave stale pixels, and the optimized result matches the
uncached reference.

### Phase 7 — Integrate all compositor paths

Estimate: 2–4 weeks.

- [x] Saved transaction buffers and position-animation snapshots preserve radii.
- [x] Workspace animation does not continuously invalidate an unrelated background.
- [x] Popups, subsurfaces, layer shell, fullscreen, session lock, and XWayland render correctly.
- [x] Atomic output configuration uses the same effect frame builder as normal commits.
- [x] Screencopy and output capture include the final composited effects.
- [x] Output add/remove, suspend/resume, GPU reset, and renderer recreation rebuild resources.
- [x] Multi-output windows use output-local scale, transform, damage, and caches.
- [x] Direct scanout returns when no visible effects require composition.

Implementation record:

| Area | Result |
|---|---|
| Snapshots | Transaction saves and animation clones use the existing effect-metadata copy path; every render sequence applies the requested radius to live, saved, and active animation trees |
| Animation damage | Position and workspace animations rely on wlroots scene-node old/new damage; the former unconditional whole-output invalidation is removed |
| Scene coverage | The render seam remains attached to the scene output, so XDG popups, desynchronized subsurfaces, layer shell, fullscreen, session lock, and XWayland use the same wlroots Vulkan pass |
| Frame construction | `Output.buildSceneState` synchronizes visual state, prepares blur damage, selects the normal or OutputManager swapchain target, records metrics, and builds both commit paths |
| Capture | Screencopy observes the final wlroots output state after rounded draws and every scene-ordered blur checkpoint; output disable/resume reproduces the same capture |
| Lifetime | Output teardown destroys its cache, disable clears effect resources, resume invalidates them, and renderer-loss recovery releases caches before replacing the context and rebuilding from compositor-owned metadata |
| Multiple outputs | Blur visibility is computed by intersection in each output's logical origin, physical scale, and transform; windows are synchronized at every output frame boundary and caches remain output-owned |
| Scanout | A pure composition predicate and the wlroots candidate hook require composition for visible radii or blur and restore eligibility when both are absent |
| Validation | 163 unit tests pass; cached and uncached 64-frame hardware matrices, shell paths, XWayland rendering, fullscreen, lifecycle, scaling, mixed-output scrolling, and policy parity pass |

Exit condition: the full visual matrix passes and all existing compositor
integration scripts still pass. The automated functional matrix is green.
Physical hotplug, forced reset/recreation, mixed-scale cross-output blur, and
direct-scanout restoration remain explicit hardware acceptance runs.

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
scripts/test-vulkan-shell-paths.sh
AQUEOUS_XWAYLAND_RENDER_ONLY=1 scripts/test-xwayland-input.sh
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
- Phase 4 validation: `zig build test -Dcpu=baseline --summary all` passes
  158/158 tests, including effect-metadata lifecycle and CPU radius-clamping
  coverage
- Phase 5 validation: the Vulkan-effects ReleaseSafe build and
  `zig build test` pass 159/159 tests against the reproduced wlroots 0.20.2
  dependency; all five blur SPIR-V modules pass
  `spirv-val --target-env vulkan1.0`
- Phase 6 validation: `zig build test -Dcpu=baseline --summary all` passes
  162/162 tests, including cache damage expansion, backward dependency planning,
  clipping, and odd-pixel half-resolution coverage
- Phase 7 validation: `zig build test -Dcpu=baseline --summary all` passes
  163/163 tests, including direct-scanout composition eligibility
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
  library from the pinned official archive and verifies the texture, rectangle,
  force-blend, pass-attribute, direct-scanout, and XWayland symbols
- the wlroots patch applies cleanly in a fresh 0.20.2 source tree, and all four
  rounded shader binaries reproduce byte-for-byte from their GLSL sources and
  pass `spirv-val --target-env vulkan1.0`
- the production Vulkan-effects build succeeds against that reproduced
  dependency while SceneFX and effects-disabled builds continue to compile
- `AQUEOUS_VULKAN_PROBE_REQUIRE_VALIDATION=0
  scripts/test-vulkan-render-seam.sh` passes 4,096 buffer-reuse frames on the
  RTX 5090, recording 4,116 texture and 4,116 rectangle draws: 8,222 ordinary,
  10 swapchain, and 8,232 explicit-sync draws
- rounded corners, hollow outlines, localized damage, scales 1, 1.25, 1.5, and
  2, rotations 90°, 180°, and 270°, and post-stress screencopies pass their
  assertions; every generated checksum verifies
- the expanded uncached-blur harness passes 64 reused-buffer frames with
  explicit sync, live backdrop motion, a kernel-expanded localized update,
  translucent content, overlapping scene-ordered blur, and blur captures at
  scales 1, 1.25, 1.5, and 2 with 90°, 180°, and 270° rotations
- that run records 376 blur checkpoints, 6,392 offscreen draws, and 376
  composites; one downsample plus 16 separable draws is accounted for at every
  checkpoint and every artifact checksum verifies
- the cached 64-frame run records 15 preserved-cache hits, 71 partial rebuilds,
  10 full rebuilds, and 51,054,704 processed pixels; the uncached oracle
  rebuilds all 160 checkpoints, and selected cached captures differ by less
  than `0.00005` mean normalized channel value
- the expanded Phase 7 cached run records 1,321 effect draws, 103 blur
  checkpoints, 9 cache hits, 87 partial rebuilds, 16 full rebuilds, and
  94,258,332 processed pixels; its 64-frame uncached oracle records 671
  scene-ordered checkpoints
- the Phase 7 matrix renders a popup and desynchronized subsurface, preserves
  rounded snapshots through outgoing and incoming workspace animation, returns
  to within `0.0000022` of the pre-transition image, and exactly reproduces the
  pre-disable image after output resume
- all selected cached/uncached Phase 7 captures stay within the documented
  `0.0002` mean tolerance; the largest measured difference is approximately
  `0.0000527`
- `scripts/test-vulkan-shell-paths.sh` passes layer-shell screencopy and
  session-lock presentation; `AQUEOUS_XWAYLAND_RENDER_ONLY=1
  scripts/test-xwayland-input.sh` passes managed and override-redirect XWayland
  rendering
- the Vulkan build passes `scripts/test-policy-parity.sh`,
  `scripts/test-scaling.sh`, `scripts/test-scrolling-viewport.sh`,
  `scripts/test-window-lifecycle.sh`, and `scripts/test-xdg-fullscreen.sh`
- SceneFX and effects-disabled ReleaseSafe compatibility builds continue to
  compile after the shared frame-builder integration
- The Khronos validation layer was not installed for that run; the harness will
  require it by default and reject validation errors when available

The Vulkan runtime harnesses require a test build with
`-Dexternal-policy=true` and run `-policy compare` only so their private fixture
can request a graceful session exit. Internal Aqueous policy still performs the
rendering and modesets. Production Vulkan builds remain
`-Dexternal-policy=false`.

To repeat the functional run:

```sh
scripts/build-wlroots-render-hook.sh .deps/wlroots-render-hook
export PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig"
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
| Remaining work after the cached-blur implementation | 5–12 weeks, dominated by broad integration, performance, rollout, and hardware coverage |

The render seam, synchronization contract, rounded pipelines, and correct
scene-ordered cached blur are now implemented. Broad compositor integration,
performance hardening, rollout, and validation across more GPU drivers remain
the largest work items.

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
