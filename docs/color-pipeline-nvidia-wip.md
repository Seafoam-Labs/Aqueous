# NVIDIA color pipeline — WIP status and resume guide

**Status: PAUSED (2026-11-22).** `color_pipeline_post_blend` and
`color_pipeline_fp16_fmt` are disabled in the live config. The hardware-cursor
fix is validated and works on its own; the post-blend color-pipeline path is
**not stable** on the local NVIDIA driver and wedges the kernel. This document
preserves the full state of the work so it can be pushed to a branch and
revisited. Companion design doc: `docs/color-pipeline-nvidia-plan.md`.

## Hardware / software context

- GPU: **RTX 5070 Ti** (the user's machine; the lead developer's validation
  records reference an RTX 5090 — not this host).
- Driver: **620.73.04**, open kernel module (`nvidia_drm`, `nvidia_modeset`).
  Source: `/usr/src/nvidia-620.73.04/kernel-open/`.
- Kernel: `7.3.5-3.1-devario`.
- Reference implementation that works on this driver: the user's niri/spicy
  tree at `../niri-worktree/spicy-tree` (smithay `src/backend/drm/colorop.rs`,
  `surface/atomic.rs`, `compositor/mod.rs`). **Key fact from the user: niri
  kept planes format-matched — non-FP pipelines for non-FP buffer formats —
  and never sat FP-bound while presenting integer content.**

## What works (keep these)

1. **Hardware cursor on LINEAR-only NVIDIA planes** (patch 0050, cursor parts).
   NVIDIA cursor planes scan out ARGB8888+LINEAR only; the Vulkan device cannot
   render to LINEAR (no color-attachment features). Fix: the cursor format
   picker falls back to the display format, and the render pass renders the
   cursor (GPU color transform preserved) into an internal tiled image, then
   `vkCmdCopyImage` into the imported LINEAR dmabuf in the same submission. No
   CPU conversion. **Validated standalone with post_blend=false: 7 GPU copy
   targets, 0 software fallbacks, cursor plane actively scanning out.**
2. **FMT-on-FP16 switch** (patch 0047 + Zig). `color_pipeline_fp16_fmt` assumes
   the leading FMT matrix is effective on FP16 (620 reshaped FP pipelines; FP
   Lite is FMT-only). With it on, gain-folded matrices resolve on FP Lite and
   the composed FP16 post-blend offload engages (`linear_max 5.000` on DP-1).
   Harness-proven; pixel correctness was never visually confirmed.
3. **Composed post-blend offload engages** and renders correctly while engaged
   (FP16 offload swapchain + FP pipeline + CRTC gamma encode).

## The unresolved problem: NVIDIA modeset DMA wedge

`nvidia-modeset: ERROR: nvCtxDmaAlloc failed` — once it starts, **all FB
imports fail permanently** until the driver is reloaded (reboot). The
compositor then retries forever (clients freeze but stay alive; audio may keep
playing). Observed triggers, all involving `COLOR_PIPELINE` state transitions:

- **DPMS sleep/wake** with FP pipeline + gamma committed (11:47 session):
  kernel WARN `nv_drm_crtc_dequeue_flip` (`nvidia-drm-crtc.h:371`, flip event
  with empty flip list), then ~50 min later the permanent DMA wedge.
- **Post-blend disengage during pure composition** (15:45 session, no DPMS, no
  fullscreen — only Zed in a normal window): the offload's own FP16 swapchain
  buffer needed a fresh `addfb2`, failed, and the wedge began. **No client
  scan-out was involved** — the "Failed to import buffer for scan-out" log line
  is the generic primary-plane import message; the failing buffer was the
  composited offload FP16 buffer, not a client buffer.
- **The recovery's standalone unbind commit** (see below) immediately precedes
  wedge onset (15:52:04 capture: import fail → `unbound to recover` →
  `nvCtxDmaAlloc` starts, same second).

**Leading hypothesis:** the NVIDIA 620 open module cannot tolerate
`COLOR_PIPELINE` transitions — especially the standalone `COLOR_PIPELINE=0`
(unbind-to-legacy) commit. The recovery mechanism added in 0050 performs exactly
that commit and appears to **trigger** the wedge rather than prevent it.

### Recovery / backoff machinery in 0050 (mitigations, not a cure)

- `drm_color_pipeline_unbind_committed[_all]()` — standalone unbind commit so a
  blocked `addfb2` can be retried. **Suspected wedge trigger.**
- `fb.c` retries `addfb2` after unbind **before poisoning** the buffer (a
  poisoned buffer is never re-imported; retrying after poison is futile — this
  was a real bug, fixed).
- Scene disable branch resets internal post-blend state + cached LUTs **without
  touching the disabled output's state** (an earlier version called
  `scene_output_post_blend_state` on the disabled state, which set a color
  transform on a disabled output → every DPMS-off commit failed; fixed).
- Commit-failure **backoff**: per-connector (8 failures) and device-wide
  (16 failures) → 1 s cooldown skipping prepare/commit. Caps the retry flood
  (hundreds of errors vs ~600k) but **does not prevent the wedge or desktop
  death**.

### Recovery characteristics

- **DMA wedge** (`nvCtxDmaAlloc`/WARN in `journalctl -k -b`): needs reboot or
  driver reload. Killing the compositor sometimes cleared it (15:43) but not
  reliably.
- **Kernel-clean import deadlock** (no `nvCtxDma`/WARN): recovers by killing the
  compositor alone — no reboot.

## Recommended path forward

Align with the user's niri design rather than the post-blend/unbind-to-legacy
approach:

- **Plane-side encode on integer buffers with format-matched non-FP pipelines;
  never unbind to legacy.** Avoid the FP16-offload + standalone-unbind
  transitions that trigger the wedge. Study `spicy-tree/smithay/src/backend/drm/
  colorop.rs` (`effective_ops`, pipeline planning) and `surface/atomic.rs`
  (per-commit `COLOR_PIPELINE` programming) for the known-good pattern.
- The post-blend gamma-encode design (plan decisions D1–D8) chose CRTC gamma
  because NVIDIA plane pipelines end in linear light; reconciling that with
  format-matched plane-side encode is the core design question to revisit.
- Until then, **`post_blend=false` gives a stable desktop with the hardware
  cursor fix**.

## Change inventory (this branch)

wlroots patches (applied to wlroots 0.20.2 by the build scripts):
- `0047-drm-color-pipeline-nvidia-planner.patch` — NVIDIA pipeline names,
  interpolation, cost-DFS planner, FP16 effectiveness rule + the
  `drm_color_pipeline_set_fp16_fmt` switch.
- `0048-color-pipeline-post-blend-encode.patch` — retarget/encode-LUT helpers,
  content-stable CRTC gamma blob cache.
- `0049-scene-post-blend-cursor.patch` — scene scanout/composed post-blend
  wiring, gamma ownership/reset, cursor linear-light addon + mode-match.
- `0050-cursor-linear-gpu-copy.patch` — cursor LINEAR GPU copy; import recovery
  (standalone unbind + pre-poison retry); commit-failure backoff; scene disable
  teardown; instrumented FB-import failure logs. **Contains the suspected
  wedge-triggering recovery — revisit before re-enabling.**

Zig / config:
- `compositor/aqueous/wm/config/wm.zig` — `color_pipeline_fp16_fmt` key + parse
  + test.
- `compositor/aqueous/main.zig` — `AQUEOUS_DRM_COLOR_PIPELINE_FP16_FMT` env
  override + setenv re-export.
- `compositor/aqueous/wm/Aqueous.zig` — startup-only reload guards (both sites).
- `wm.toml`, `docs/color-pipeline.md` — document `color_pipeline_fp16_fmt`.

Build / harnesses:
- `compositor/scripts/build-wlroots-render-hook.sh` — wires patch 0050.
- `nix/core.nix` — patches 0047–0050 in the nix build.
- `compositor/scripts/test-color-pipeline.py`, `fixtures/color-pipeline.c` —
  FMT opt-in cases (FP Lite resolves FP16 matrix + folded gain; FP Full rejects
  curve-less; reversible).
- `compositor/scripts/test-drm-sync.py`, `fixtures/drm-sync.c` — mock for
  `drm_color_pipeline_unbind_committed`.
- `compositor/scripts/probe-color-pipeline-topology.c` — read-only topology
  probe (Step 0).
- `compositor/scripts/regen-color-pipeline-patches.py` — scratch tool that
  re-derives 0047/0050 from an edited wlroots tree and byte-verifies the series
  (see "Resuming" for its scratch-tree dependencies).

## Config keys

`[render]` in `wm.toml` (all startup-only; restart to apply):
- `color_pipeline = "auto"|"off"` — base DRM color pipelines.
- `color_pipeline_post_blend = bool` — NVIDIA post-blend encode (gates the
  capability on NVIDIA; **currently false**).
- `color_pipeline_fp16_fmt = bool` — FMT-on-FP16 assumption (**currently
  false**).
Env overrides: `AQUEOUS_DRM_COLOR_PIPELINE`, `AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND`,
`AQUEOUS_DRM_COLOR_PIPELINE_FP16_FMT` (each `1|0`).

## Resuming

1. Read this doc + `docs/color-pipeline-nvidia-plan.md`.
2. Build + gate: `scripts/build-compositor.sh` (runs
   `compositor/scripts/build-wlroots-render-hook.sh` → applies patches 0001–0050
   to the wlroots tarball, meson build, all harnesses; then `zig build` + stages
   `bin/aqueous`, `bin/aqueousctl`, `lib/aqueous/libwlroots-0.20.so`). Gate is
   86 PASS, zero warnings. `zig build test` for the compositor unit tests.
3. Deploy (needs sudo): `sudo install -m755 bin/aqueous /usr/bin/aqueous` (and
   `aqueousctl`, `lib/aqueous/libwlroots-0.20.so` → `/usr/lib/aqueous/`). Stock
   backup: `/usr/lib/aqueous/stock-1.0.22/`.
4. Re-enable `color_pipeline_post_blend = true` (and `fp16_fmt`) in
   `~/.config/aqueous/wm.toml`, restart the session.
5. **Test deliberately, watching `journalctl -kf | grep -E 'nvCtxDma|WARNING'`:**
   normal composition (offload swapchain rotation), fullscreen transitions
   (disengage), and DPMS sleep/wake. The wedge can occur in pure composition —
   no fullscreen/DPMS needed.
6. Session log: `/run/user/1000/aqueous-wm.log`. Useful markers: `post-blend
   encode engaged/disengaged`, `unbound to recover buffer import`, `backing
   off`, `AddFB2WithModifiers failed (format … modifier …)`, `GPU copy target
   allocated`.

### Patch regeneration (scratch tool)

`regen-color-pipeline-patches.py` re-derives 0047 (vs a 0001–0046 base) and 0050
(vs a 0001–0049 base) from an edited wlroots tree and verifies the full series
reproduces the tree byte-for-byte. It expects:
- edited tree at `.qwen/tmp/wlroots-work/` (extract wlroots 0.20.2 tarball from
  `compositor/.deps/downloads/`, apply patches 0001–0050 in build-script order —
  note the two 0020 patches apply sync-failure-handling before
  submit-dependencies),
- base trees `/tmp/aq-base47` (0001–0046) and `/tmp/aq-base50` (0001–0049).
These scratch trees are not committed; recreate them from the tarball + patches
when resuming. The committed `.patch` files are the source of truth and apply
cleanly via the build scripts without the regen tool.

## Validation record (2026-11-22)

- Cursor fix standalone (post_blend=false): hardware cursor live, 0 fallbacks,
  0 import failures, kernel clean. **Solid.**
- post_blend=true: composed offload engages, but the kernel wedges on
  transitions (DPMS wake; disengage in pure composition; standalone unbind
  commit). Backoff caps the flood; desktop still dies. **Not stable.**
- FMT color correctness: never visually confirmed (verify pixels when revisiting;
  an inert FMT silently drops the placed stage while atomic check passes).