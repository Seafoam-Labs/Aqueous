# Use a narrow wlroots Vulkan render hook

Date: 2026-07-23

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
  transparent shader pixels do not incorrectly cull lower scene content.

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
- Production blur still needs explicit scene-order checkpoints and
  Aqueous-owned metadata; this decision establishes the command-recording seam
  but does not implement blur.

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

## Rejected alternatives

- A separate Aqueous queue submission: rejected because it is outside
  wlroots' output release and scanout synchronization.
- A copy of `wlr_scene_output_build_state`: rejected because it transfers too
  much scene, damage, capture, and presentation ownership into Aqueous.
- A replacement `wlr_renderer`: rejected because wlroots must continue to own
  rendering, allocation, and output synchronization.
