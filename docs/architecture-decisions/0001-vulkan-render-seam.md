# Use a narrow wlroots Vulkan render hook

Date: 2026-07-23
Updated: 2026-11-02

Status: accepted

## Context

wlroots 0.20 exposes the Vulkan instance, physical device, logical device,
queue family, queue, and texture images. Its public render-pass interface does
not expose the active command buffer, compatible Vulkan render pass, output
target, or a custom draw operation.

Submitting an Aqueous-owned command buffer after
`wlr_scene_output_build_state` is not safe. wlroots owns the acquire and
release timelines, and the backend may consume or scan out the buffer as soon
as wlroots' submission signals. A second submission would not be part of that
contract. Reimplementing scene-output rendering would also duplicate scene
traversal, visibility, damage, buffer age, color handling, capture,
presentation feedback, and output synchronization.

## Decision

Carry a small, versioned downstream patch against wlroots 0.20.2.

The patch adds:

- a one-shot scene-buffer callback after wlroots prepares the texture
  descriptor, sampler, transforms, color data, and synchronization, but before
  the stock texture draw;
- a return value that lets Aqueous replace that stock texture draw while
  retaining wlroots' common texture lifetime, damage, and synchronization work;
- a matching scene-rectangle replacement callback;
- a Vulkan-only query for the active command buffer, compatible render pass,
  render extent, subpass, and presence of the output signal timeline; and
- explicit force-blend flags for effect-bearing buffers and rectangles, so
  transparent shader pixels do not incorrectly cull lower scene content;
- render-begin and pre-node callbacks that preserve wlroots' bottom-to-top
  scene traversal order; and
- a pre-pass predicate over visible scene nodes that requests a sampleable
  backdrop only when needed; and
- a Vulkan-only offscreen callback that samples wlroots' FP16 linear
  intermediate, suspends the active pass after already-rendered content is
  complete, and resumes the same command buffer with its contents preserved.

Render-hook API 11 separates backdrop requirements from color-transform
requirements. Direct linear/sRGB paths remain eligible without backdrop sampling;
gamma-2.2, HDR, LUTs and unsupported direct attachments still require FP16.
An intermediate retained across a path change is reclaimed after eight direct
uses of that target and proven timeline completion. The path change invalidates
preserved scene contents. No second submission or frame-path queue-idle wait is
introduced.

Aqueous records its effect commands into that same command buffer and render
pass. It uses wlroots' transformed destination box and damage clip. wlroots
continues to own the target buffer, image layouts, acquire/release timelines,
submission, capture, and output commit.

The scene output also accepts a needs-composition predicate. Direct scanout is
disabled only when the sole visible buffer has effect metadata that requires
the custom draw; fullscreen and effect-free buffers retain the normal scanout
path.

The dependency is pinned to the official wlroots 0.20.2 source archive with
SHA-256
`972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343`.
The patch has a compile-time API version check, a reproducible build script,
and a CI job that builds Aqueous against the patched library.

## Consequences

- Effect commands participate in the exact wlroots submission that renders
  and releases the output buffer.
- Normal frames and OutputManager swapchain transactions use one seam.
- Damage, transforms, fractional scale, and screencopy use wlroots' existing
  coordinate and synchronization model.
- Aqueous owns only its Vulkan pipeline objects and shaders; it creates no
  second renderer, instance, device, or queue.
- The wlroots patch must be reviewed and rebased for every wlroots upgrade.
- Direct scanout remains available when no visible custom effect requires
  composition.
- Scene-ordered uncached blur uses the same submission, with one checkpoint
  before the first rendered node in each blurred window tree.
- Cached and uncached blur use cropped half-resolution effect domains. A shared
  scratch pool retains at most four sets and 64 MiB, except for a single larger
  effect. Submitted uses retain evicted resources until completion. Pass-local
  source descriptors avoid retaining borrowed render-target image views.
- Persistent caches map output coordinates to local texels while preserving
  partial damage, odd-pixel alignment and reflected sampling at effect edges.

## Validation

The production nested test renders the client texture through an antialiased
rounded mask and its decoration as one outer-minus-inner SDF outline. On the
reference RTX 5090 run it produced rounded screencopies at scales 1, 1.25, 1.5,
and 2 with 90°, 180°, and 270° output rotations, confined a localized update to
exactly `160x120+440+320`, and completed 4,096 single-buffer reuse frames.

The final counters recorded 4,116 texture draws and 4,116 rectangle draws:
8,222 through normal output rendering, 10 through the OutputManager swapchain
path, and all 8,232 with wlroots' output signal timeline. No Vulkan error or
VUID was logged. The workstation did not have
`VK_LAYER_KHRONOS_validation` installed, so the required validation-layer rerun
remains open; the harness requires that layer by default.

The uncached-blur extension completed a separate 64-frame hardware run with
376 scene-ordered checkpoints, 6,392 offscreen draws, and 376 masked
composites. Live backdrop motion, an expanded localized update, overlapping
blurred windows, transformed fractional-scale output, explicit sync, and
screencopy passed without a logged Vulkan error. Mixed-output and validation
layer runs remain open.

The 2026-11-02 implementation passed the full Zig unit suite, 21 mocked GPU
resource tests, and the patched wlroots build checks. On the RTX 5090, real
Vulkan tests with the Khronos validation layer checked direct/FP16 transitions,
sRGB and alpha parity, gamma-2.2 fallback, allocation-failure retries and
intermediate reclamation. Synchronization validation exposed missing attachment
load/store access masks in the existing dependencies; patch 0042 corrects those
and the blur-resume/acquire barriers. The transition fixture and both blur-domain
paths then passed synchronization validation on the RTX 5090. The
render-seam runs covered 64 cached and 256 uncached reused-buffer frames,
rotated/scaled outputs, partial damage, cursor damage, workspace animation,
capture and output resume without validation errors. Six blur-domain images
matched the original installed compositor pixel-for-pixel; cached and uncached
stable render-seam images also matched. These isolated headless checks do not
replace physical mixed-monitor HDR/VRR qualification.

## Rejected alternatives

- A separate Aqueous queue submission: rejected because it is outside
  wlroots' output release and scanout synchronization.
- A copy of `wlr_scene_output_build_state`: rejected because it transfers too
  much scene, damage, capture, and presentation ownership into Aqueous.
- A replacement `wlr_renderer`: rejected because wlroots must continue to own
  rendering, allocation, and output synchronization.
