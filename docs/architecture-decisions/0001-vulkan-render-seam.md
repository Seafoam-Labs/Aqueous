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

- a scene-output callback immediately after an ordinary scene-buffer texture
  draw, while the wlroots render pass remains active;
- a Vulkan-only query for the active command buffer, compatible render pass,
  render extent, subpass, and presence of the output signal timeline; and
- invalidation of wlroots' cached pipeline binding when Aqueous requests those
  attributes, ensuring the next wlroots draw binds its own pipeline again.

Aqueous records its effect commands into that same command buffer and render
pass. It uses wlroots' transformed destination box and damage clip. wlroots
continues to own the target buffer, image layouts, acquire/release timelines,
submission, capture, and output commit.

Installing the callback disables direct scanout for that scene output because
the custom draw must be included in the composited result. The callback is
installed only in builds with `-Dvulkan-render-probe=true` until production
effect metadata and pipelines replace the probe.

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
- Direct scanout remains unavailable while custom effects are active.
- Production blur still needs explicit scene-order checkpoints and
  Aqueous-owned metadata; this decision establishes the command-recording seam
  but does not implement blur.

## Validation

The nested probe renders an antialiased rounded rectangle over one known
client buffer. On the reference RTX 5090 run it produced a rounded
screencopy, confined a localized update to exactly
`160x120+440+320`, survived a 1.25 scale with a 90-degree transform, and
completed 4,096 single-buffer reuse frames.

The final counters recorded 4,110 draws: 4,107 through normal output rendering,
3 through the OutputManager swapchain path, and all 4,110 with wlroots' output
signal timeline. No Vulkan error or VUID was logged. The workstation did not
have `VK_LAYER_KHRONOS_validation` installed, so the required validation-layer
rerun remains open; the harness requires that layer by default.

## Rejected alternatives

- A separate Aqueous queue submission: rejected because it is outside
  wlroots' output release and scanout synchronization.
- A copy of `wlr_scene_output_build_state`: rejected because it transfers too
  much scene, damage, capture, and presentation ownership into Aqueous.
- A replacement `wlr_renderer`: rejected because wlroots must continue to own
  rendering, allocation, and output synchronization.
