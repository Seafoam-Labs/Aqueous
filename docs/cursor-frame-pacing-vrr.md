# Cursor motion clocks the frame cadence (and VRR refresh) to the input rate

**Finding, 2026-11-23.** Moving the pointer drags the whole presentation
pipeline — compositor commits, FIFO client frame rate, and (with VRR) the
panel refresh — down to the pointer's polling rate. Documented for future
work; no fix applied.

## Empirical observation

On the `cursor-linear-gpu-copy` build (NVIDIA RTX 5070 Ti, driver 620.73.04,
**hardware-cursor fix applied**, **VRR enabled**, DP-1 3840x2160@160.001 Hz):

- A vsync-locked (FIFO) `vkcube` in a window, measured with MangoHud, runs at
  **~157 Hz** when the pointer is still — just under the 160 Hz mode, limited
  by per-frame compositor overhead rather than a clean vblank lock.
- Moving the cursor in circles — **not even over the vkcube window** — drops
  the measured rate to **~125 Hz**, exactly the mouse polling rate.
- With VRR on, the panel syncs to that same ~125 Hz during cursor motion.

## Mechanism (code-traced)

The frame loop is event/damage-driven and idles between events; it is not a
fixed vblank timer.

1. Pointer motion (125 Hz) → `queueMotionRelative` (Cursor.zig) →
   `Seat.queueEvent` → `processEvents` when the WM is idle →
   `processInteractiveMotionBatch` (Seat.zig:463) consumes the motion burst as
   one manage transaction. Burst coalescing is why the ceiling lands on exactly
   the device polling rate.
2. The transaction moves the cursor. With the hardware cursor:
   `wlr_output_cursor_move` (types/output/cursor.c:436) →
   `output_move_hardware_cursor` (cursor.c:39). The DRM `move_cursor` impl
   (`drm_connector_move_cursor`, backend/drm/drm.c:1357) only stores
   `cursor_x/y` for the next commit, **but `output_move_hardware_cursor` then
   calls `wlr_output_update_needs_frame`** (cursor.c:44).
3. `update_needs_frame` (types/output/output.c:1037) emits `needs_frame` →
   `scene_output_handle_needs_frame` (types/scene/wlr_scene.c:2224) →
   `wlr_output_schedule_frame` (output.c:909) arms an idle timer →
   `handleFrame` → `renderAndCommit` (Output.zig:2467), which does **not** skip
   because `needsFrame()` is true (Output.zig:2470) → a full output commit
   (cursor plane advanced to the new position).

So every hardware-cursor move still produces an output commit, clocked by the
125 Hz input batches.

### FIFO clients inherit the cadence

`vkcube` is FIFO via `fifo-v1`: it renders one frame per barrier release, and
barriers release on commit/presentation (`types/wlr_fifo_v1.c`, `idle()` →
`wlr_output_schedule_frame`; `FifoManager.finish`/`present` feed it from the
render path). Its present rate therefore tracks the compositor commit rate:
~157 Hz free-running (client-driven), 125 Hz when cursor motion becomes the
commit clock. The cursor does not add work on top of the client loop — it
**replaces the clock** that paces it, which is why motion *lowers* the rate
rather than raising it.

### VRR makes the panel follow too

The DRM commit is a non-blocking page-flip (`DRM_MODE_PAGE_FLIP_EVENT`,
drm.c:1158); `adaptive_sync_enabled` programs the VRR property
(backend/drm/atomic.c:385). With VRR the panel refreshes when a frame lands, so
the commit cadence (125 Hz under cursor motion) becomes the refresh cadence.

Two distinct effects:

| Effect | Needs VRR? |
|---|---|
| FIFO client FPS drops to 125 Hz (MangoHud reading) | No — paced to commit cadence regardless |
| Panel refresh drops to 125 Hz | Yes — without VRR the panel keeps scanning at 160 Hz while the client still presents at 125 Hz |

(`DRM_MODE_PAGE_FLIP_ASYNC` is separate, only for tearing flips, drm.c:1161.)

## Why the hardware-cursor fix does not resolve this

The `cursor-linear-gpu-copy` fix removes the **software-cursor whole-output
damage** (`output_cursor_damage_whole`) and the full-composition cost: the
cursor is rendered into an internal tiled image and GPU-copied to a LINEAR
plane buffer. But `output_move_hardware_cursor` still raises `needs_frame`, so
a commit still happens per move. The 125 Hz lock observed **with the fix
applied** confirms the coupling is the `needs_frame` → commit chain, not the
software-cursor damage.

## Possible decoupling (future work, not implemented)

- **(a) Drop `needs_frame` on hardware-cursor move.** Cursor position would
  update only on the next content-driven frame. Simple, but on an idle VRR
  desktop the cursor lags until something else renders — poor responsiveness.
- **(b) Cursor-plane-only commit.** Advance the cursor plane without flipping
  the primary / triggering a VRR refresh and without the full `renderAndCommit`
  path. Keeps responsiveness while leaving the display cadence to content.
  Requires a dedicated cursor commit path in the DRM backend (wlroots currently
  defers cursor x/y to the next full commit). Whether a cursor-only atomic
  commit avoids a VRR refresh is driver behavior to verify on the 5070 Ti first.

Option (b) is the principled direction.

## References

- wlroots paths cited against the 0.20.2 + patches 0001–0047 tree
  (`.qwen/tmp/master-base` at the time of writing).
- Related: `docs/color-pipeline-nvidia-wip.md` (paused post-blend track, on
  branch `wip/nvidia-color-pipeline`); the cursor fix itself is patch
  `0047-cursor-linear-gpu-copy.patch` on this branch.