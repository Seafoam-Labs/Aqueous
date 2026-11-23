# Nvidia color pipeline support — implementation plan

Status: plan only, no code changes yet. Derived 2026-11-22 from the local
`../niri-worktree/spicy-tree` worktrees (`niri` @ `spicy-main` 1bfaa833,
`smithay` @ `spicy-master` dba9452b). Knowledge is derived from those commits
only; no Rust code is reused. Aqueous implementation stays in the private
wlroots 0.20.2 patches (C) plus the Zig compositor.

Goal: lift the blanket NVIDIA disable in `0025-drm-color-pipeline.patch` and
make hardware color conversion actually work on `nvidia-drm`, whose plane
color pipelines have a fundamentally different shape from amdgpu's: they
always end in linear light, so the final encode must move behind blending
onto the CRTC `GAMMA_LUT` ("post-blend encode"), with FP16-specific pipeline
selection and an inert-matrix quirk.

## 1. Provenance — commits the knowledge comes from

smithay (`spicy-tree/smithay`):

| Commit | Knowledge |
| --- | --- |
| `db1c0719` | Capability `DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE` before state snapshot; reject pipelines with unknown non-bypassable ops (blank-screen source); NEXT-chain walk |
| `fb41e9a4` | S31.32 sign-magnitude; `drm_color_ctm_3x4` blobs; COLOR_PIPELINE + colorop props in the same commit as plane state; reset to Bypass otherwise; per-plane/transform resolution caching |
| `401912a6` | Exact nvidia-drm topology (610.43.03, RTX 5070 Ti), encode-ending transforms rejected by all four pipelines, linear-ending transforms resolve on "NVIDIA Lite" |
| `650a3457` | Cost-based planner: decode synthesized into 1D LUTs, gain folding, fewest-LUTs preference, identity programming of non-bypassable ops; `PostBlendEncode` on CRTC GAMMA_LUT; shape unchanged on 615.71.09, colorop ids shift between driver versions |
| `a6a4be6d` | Post-blend offload rules: single fullscreen layer, cursor linearization, gamma-LUT ownership + draining, cursor cache keyed by transform mode, offload candidacy decided before plane assignment |
| `cee8872a` | FP16 framebuffers: nvidia-modeset `ValidateLayerLutHwState()` refuses input LUTs on FP16 → atomic check fails on "NVIDIA Full/Lite"; use "NVIDIA FP Full/FP Lite"; record pipeline enum names |
| `c5c2d494` | Leading FMT matrix is inert for FP16 surfaces (silent wrong brightness); `effective_ops(format)`; gain/gamut must land on the blend matrix (CSC11) |
| `064e3066` | Taking pending-frame sync points so callers can wait outside KMS (nvidia in-fence reliability; adjacent, not color) |

niri (`spicy-tree/niri`):

| Commit | Knowledge |
| --- | --- |
| `96c7e4a7` | Compositor wiring: linear transform = regular transform minus encode, normalized by `1/linear_max`; `linear_max = peak/80` (PQ125 scale); gamma-control ramps deferred while offload owns gamma, applied on the vblank after reset; experimental flag + banding caveat |
| `31b38918` / `fdf7d06b` | Cursor plane must stay enabled under HDR or it silently blocks primary scanout; CPU per-pixel cursor encode was 12–46 ms/change → LUT-accelerated ~290 µs; cursor cache reuse across modes |
| `598c5908` / `d4e02772` | HDR_OUTPUT_METADATA flapping is a full modeset on nvidia with non-HDMI connectors (NVKMS infoframe behavior); zero luminances mean "unknown" (CTA-861.3) and cause blob flap → seconds-long blank resync |
| `d9131c33` | 8-bit vs 10-bit scanout format list is fixed at compositor creation; HDR toggle needs output recreation; floor max bpc at 10 under HDR |
| `1bfaa833` | NVIDIA KMS can scan out unfinished frames with IN_FENCE_FD; wait on plane fences in the event loop, then queue without IN_FENCE_FD (adjacent risk) |
| `8398f816` / `e02f19e7` / `34722b2a` | Tone-mapped content must be denied scanout (parametric pipelines can't express the curve); reference-luminance rescale reaches scanout as the multiplier; EDID peak fallback/override feeds normalization |

## 2. Hardware facts (nvidia-drm, verified in spicy tests on 610.43.03 and 615.71.09)

**Hardware attribution:** the local development host (this user's, not the
lead developer's) is an **RTX 5070 Ti** with driver **620.73.04** (NVIDIA
UNIX Open Kernel Module, confirmed via `nvidia-smi` /
`/proc/driver/nvidia/version` on 2026-11-22). The RTX 5090 in Aqueous's
validation record below is the **lead developer's** hardware. The spicy
topology was reconstructed on an RTX 5070 Ti (610.43.03) — the same GPU
model as the local host — but 620.73.04 is newer than either version the
spicy commits verified. Everything in this section is unverified on
620.73.04: the driver may have changed the topology, added named curves, or
fixed the empirical quirks (FP16 input-LUT refusal, inert FMT matrix).
Step 0 must re-confirm all of it before implementation relies on it; keep
the conservative rules until re-verified. **Done 2026-11-22 — see "Step 0
results" in §5: Full/Lite unchanged, FP Full/FP Lite reshaped on 620.**

Four pipelines on **every primary and overlay plane**; **cursor planes
advertise no COLOR_PIPELINE**. Colorop ids differ per plane and shift between
driver versions (+6 on 615.71.09) — nothing may hardcode them. Aqueous's own
read-only discovery (docs/color-pipeline.md validation record, lead
developer's RTX 5090 / 615.71.09) found 32 pipelines / 208 nodes = 8 planes
× (11+5+8+2) nodes, consistent with this shape.

- **"NVIDIA Full"** (11 ops): 3x4 Matrix, 1D Curve {PQ 125 EOTF}, 1D LUT
  (1024, linear), Multiplier, 3x4 Matrix, 1D Curve {PQ 125 Inverse EOTF}
  (**non-bypassable**), 3x4 Matrix, 1D LUT (1024), 3x4 Matrix, 1D Curve
  {PQ 125 EOTF} (**non-bypassable**), 3x4 Matrix.
- **"NVIDIA Lite"** (5 ops, all bypassable): 3x4 Matrix, 1D Curve
  {PQ 125 EOTF}, 1D LUT (1024, linear), Multiplier, 3x4 Matrix.
- **"NVIDIA FP Full"** (8 ops): 3x4 Matrix, 3x4 Matrix, 1D Curve {PQ 125
  Inverse EOTF} (non-bypassable), 3x4 Matrix, 1D LUT (1024), 3x4 Matrix,
  1D Curve {PQ 125 EOTF} (non-bypassable), 3x4 Matrix.
- **"NVIDIA FP Lite"** (2 ops, bypassable): 3x4 Matrix, 3x4 Matrix.

Consequences:

1. Curve ops offer **only the PQ 125 pair** — no sRGB / Gamma 2.2 named
   curves. SDR decodes must be synthesized into the 1024-entry 1D LUT.
2. Every pipeline **ends in linear light**. Full/FP Full end in a
   non-bypassable PQ-encode→PQ-decode pair; do not try to use that pair as an
   identity (unverified precision) — smithay's planner rejects those
   pipelines for its transform shapes, and so should ours.
3. Hardware model: decode + gain + gamut on the plane, **linear-light
   blending**, wire encode **after blending on the CRTC GAMMA_LUT**
   (1024-entry; DEGAMMA_LUT and vendor NV_CRTC_REGAMMA_LUT also exist;
   GAMMA_LUT is the post-blend one — confirmed by `c5c2d494` where unscaled
   content "still reached the gamma LUT").
4. **FP16 framebuffers** (`{A,X}{RGB,BGR}16161616F`): non-FP pipelines are
   unusable (their curve/LUT/multiplier ops live in the plane input LUT,
   which nvidia-modeset refuses on FP16 at atomic-check time). On FP
   pipelines the **leading FMT matrix is inert** (it converts the surface
   format to the pipe's native FP16); stages must land on the second matrix
   (CSC11). Misplacing them passes atomic check but is silently wrong
   (too-bright scRGB) — physical pixel acceptance is mandatory.
5. PQ 125 linear scale: 1.0 = 80 cd/m², 125.0 = 10 000 cd/m². Post-blend
   normalization: plane outputs 1.0 at `linear_max = peak_nits / 80`; the
   gamma LUT maps `u ∈ [0,1]` to `PQ125InvEotf(u × linear_max)`. Use the
   sink's peak (EDID desired-content-max-luminance, or configured override),
   not 10 000 — a linear-indexed 1024-entry LUT has little precision near
   black, and smaller `linear_max` means less banding.

## 3. Current Aqueous state and gaps

Existing machinery (keep): buffer-scoped immutable recipes
(`render/color_pipeline.c`, patch 0025), ordered-op matcher with bounded
backtracking, S31.32 packing, LUT resampling with 1/65535 knot error bound,
PQ-125 normalization via 125 / (1/125) multipliers folded into matrices,
blob lifetime + reset-before-program on both atomic and libliftoff paths,
content-stable DATA blobs and verified-key test caching (0046), scene
fullscreen/overlay recipe builders and composed FP16 `XBGR16161616F`
offload (0026), 120-frame retry + full-rebuild recovery, Zig config
(`wm.toml [render] color_pipeline`, `AQUEOUS_DRM_COLOR_PIPELINE`), output
retry simulation (`simulate_color_pipeline`), color guard (0028 +
OutputWarming).

Gaps, each mapped to the spicy knowledge:

| # | Gap | Where | Evidence |
| --- | --- | --- | --- |
| G1 | Blanket nvidia/nouveau disable before capability negotiation | `0025` `drm_color_pipeline_init` | — |
| G2 | Discovery records no pipeline **names**; interpolation qualified by enum count==1 instead of current value | `0025` `read_node`/`drm_color_pipeline_discover` | cee8872a, 650a3457 |
| G3 | Matcher is greedy in-order; unused nodes must be bypassable; no LUT decode synthesis, no gain-into-LUT folding, no identity programming of non-bypassable matrix/multiplier/LUT, no cost preference | `0025` `match`/`compatible`/`emit` | 650a3457 |
| G4 | No format awareness: FP16 buffers would match non-FP pipelines (atomic-check failure) or place stages on the inert FMT matrix (silent wrong pixels) | `0025` matcher; recipe wrapper knows source format | cee8872a, c5c2d494 |
| G5 | Recipes always end in an encode → inexpressible on all four nvidia pipelines; no post-blend encode concept | `0026` `scene_buffer_color_pipeline`, `scene_output_try_color_pipeline` | 401912a6, a6a4be6d |
| G6 | No CRTC GAMMA_LUT ownership/reset/draining; scene gamma attempt (`scene_output_state_attempt_gamma`, wlr_scene.c:2470/2643) would fight the offload for the same KMS property | `0026`, vanilla `types/scene/wlr_scene.c` | a6a4be6d, 96c7e4a7 |
| G7 | Vanilla supplied-transform→GAMMA_LUT path creates a **fresh blob every commit** (`create_gamma_lut_blob`, atomic.c) — per-flip gamma reprogramming, the exact churn 0046 fixed for DATA blobs | vanilla `backend/drm/atomic.c` | 0046 lesson, 598c5908 modeset risk |
| G8 | Blanket rejection of hardware conversion whenever a hardware cursor is visible | `0025` `drm_color_pipeline_add`, `wlr_drm_output_supports_color_pipeline` | a6a4be6d, fdf7d06b |
| G9 | Cursor color transform always targets the output's wire encoding; no normalized-linear variant, no re-render on offload mode toggle | vanilla `types/output/cursor.c` `output_cursor_refresh_color_transform` (called from output.c:246 on image-description commits) | a6a4be6d, 96c7e4a7 |
| G10 | Gamma-control guard rejects acquisition on unqualified paths; no deferral-while-offload-owns-gamma behavior | `0028`, `OutputWarming.zig` guardGamma | 96c7e4a7 |

Useful existing hooks discovered:

- Vanilla wlroots 0.20.2 **already programs a supplied
  `WLR_OUTPUT_STATE_COLOR_TRANSFORM` of type `lut_3x1d` into the CRTC
  GAMMA_LUT** (`drm_atomic_connector_prepare` → `create_gamma_lut_blob`,
  with commit/rollback blob handling). The post-blend encode can ride this
  path instead of adding raw GAMMA_LUT property programming like smithay did.
  `wlr_color_transform_init_lut_3x1d(dim, …)` exists.
- wlroots already GPU-converts the hardware cursor to the output encoding
  (`output_cursor_refresh_color_transform`: sRGB→output-primaries matrix ×
  reference/max gain + inverse EOTF, rendered through the cursor swapchain).
  niri's CPU-encoder performance lesson does not transfer directly; the
  needed change is a second transform variant + refresh trigger, not a new
  encoder.
- `struct wlr_output` has `addons` — post-blend output state can attach
  without touching the public output/state ABI (Zig checks it). Scene state
  goes in the existing `WLR_PRIVATE` tail (0026/0046 pattern).
- Aqueous HDR metadata is **static per HDR level** (`output_hdr.zig`), with
  committed-state equality checks — the niri metadata-flap modeset problem
  (598c5908/d4e02772) is largely designed out already. Verify, don't rebuild.

## 4. Settled design decisions

- **D1 — Keep the recipe architecture.** Upgrade `match()` to a bounded
  cost-based DFS over stage→op assignments (smithay `plan_ops` semantics,
  re-expressed in C): stages = decode curve, gain, 3x4 matrix, encode curve;
  a 1D LUT may take the decode filled with `curve(u) × gain` (fold gain only
  when `curve_output_max × gain ≤ 1`, else normalize by `1/output_max` and
  leave the rest pending); gain folds into a matrix by scaling the three
  input columns (offset column untouched); unused bypassable ops bypass;
  unused non-bypassable matrix/multiplier/LUT program to identity; unused
  non-bypassable curve ⇒ reject that pipeline for this transform; among
  complete plans prefer fewest LUTs (named curves are exact and cheap).
  Keep the existing 4096-step budget style bound. Curve evaluation needs
  exact kernel formulas (sRGB piecewise, Gamma 2.2, PQ ST 2084 with the 125
  scale) — port the math, not the code.
- **D2 — Post-blend encode rides the supplied-transform path.** A
  post-blend frame = linear-retargeted recipe on the primary buffer
  (regular recipe minus its encode, gain divided by `linear_max`) **plus**
  `wlr_output_state_set_color_transform(state, encode_lut_3x1d)` where the
  LUT has `GAMMA_LUT_SIZE` entries mapping `u → encode(u × linear_max)`.
  Plane colorops and GAMMA_LUT then land in the same atomic commit through
  existing machinery, on both atomic and libliftoff paths. Add a
  content-stable gamma-LUT blob cache per CRTC (0046 `node_data_blob`
  pattern) so unchanged encodes keep the same blob ID (G7). Rejected
  alternative: smithay-style raw GAMMA_LUT property plumbing — duplicates
  blob commit/rollback that wlroots already has.
- **D3 — Format effectiveness is one documented vendor rule.** Record each
  pipeline's `COLOR_PIPELINE` enum entry name at discovery.
  `effective_ops(pipeline, fourcc)`: for float formats, pipelines named
  `NVIDIA …` without ` FP ` don't apply; on `NVIDIA FP …` the leading 3x4
  matrix (FMT) is ineffective. Ineffective ops may only be programmed in
  ways that place no stage. Non-nvidia pipelines: all ops effective (current
  behavior). No hardcoded ids **or matrix positions**; name-based rules are
  the only vendor-specific surface, isolated in one function with the commit
  evidence in its comment. 620.73.04 caveat (Step 0 results): FP Lite is now
  FMT-only and FP Full lost its post-FMT matrix, so with FMT marked inert no
  FP16 transform resolves — composition fallback until FMT effectiveness or
  the FP Full round-trip pair is pixel-verified.
- **D4 — Cursor.** Extend `output_cursor_refresh_color_transform` with a
  post-blend variant: sRGB→output-primaries matrix × (sdr_reference / peak)
  gain, **no encode** (extended-linear output). Post-blend output state
  (encode curve, `linear_max`, active/draining) attaches via `wlr_addon` on
  `output->addons`; refresh is triggered on mode transitions the same way
  image-description commits refresh it today (output.c:246), forcing a
  cursor re-render. Relax G8's cursor-visible rejection only when the
  cursor's encoding matches the frame's blend space: plane-only conversion
  with a wire-encoded cursor is fine (wlroots already encodes it); post-blend
  frames require the linearized cursor; software-cursor locks keep today's
  behavior (composed).
- **D5 — Gamma ownership, niri-style.** While post-blend is active *or
  draining* (disabled but no reset frame committed yet), the compositor owns
  GAMMA_LUT: every primary commit carries either the encode LUT or an
  explicit reset (`color_transform = NULL` with the state flag set);
  `scene_output_state_attempt_gamma` is skipped while owned. A gamma-control
  ramp arriving while owned disables the offload, and is applied on the
  vblank after the reset commit — extend the 0028 guard/OutputWarming path
  to defer (pending ramp) rather than fail when post-blend is the cause.
  Draining ends only when a reset frame is actually committed (a6a4be6d).
- **D6 — Eligibility, phase 1 = smithay's conservative rule.** Post-blend
  applies when a single opaque fullscreen buffer covers the output on the
  primary plane, nothing else is on any other plane except a linearized
  hardware cursor, and the regular (encode-ending) recipe is inexpressible.
  Decide candidacy before plane assignment; if the primary ends up not
  offloading, the cursor must be re-filled for the wire encoding (or
  composited). The composed FP16 offload (0026) uses the same mechanism:
  recipe = combined output transform minus encode, normalized; encode LUT on
  GAMMA_LUT. Overlay-plane linear scanout under an active post-blend encode
  is a **later extension**, not phase 1. Mode transitions force whole-output
  damage (existing `color_pipeline_composed` pattern) and clear the 0046
  verified-key cache; the key must include post-blend mode + encode LUT
  identity.
- **D7 — Policy and rollout.** `color_pipeline = auto|off` and the env
  override stay. `auto` enables the capability on `nvidia-drm` when discovery
  qualifies; **nouveau stays disabled** (no evidence it exposes these
  pipelines). Post-blend encode lands **opt-in** behind a startup-only
  override (e.g. `AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND=1`, mirrored in
  `wm.toml [render]`), matching niri's experimental-flag rollout; flip the
  default after physical acceptance. Without post-blend, nvidia still gains
  nothing for encode-ending recipes — the planner upgrade alone only helps
  linear-ending recipes, so the flag gates the whole nvidia enablement in
  practice. Phase 1 targets **HDR (PQ) outputs**; SDR outputs (sRGB/gamma22
  encode LUTs, `linear_max = 1.0` relative) are phase 2.
- **D8 — Patch hygiene.** Follow the 0046 convention: new numbered patches
  on top of the existing stack (planner/discovery; post-blend backend;
  scene/cursor/gamma integration), registered in
  `compositor/scripts/build-wlroots-render-hook.sh` **and** `nix/core.nix`.
  No public output/state ABI changes; bump `WLR_AQUEOUS_COLOR_PIPELINE_VERSION`
  in `render/color.h` + `aqueous/c.h` only if the Zig-visible surface changes.

## 5. Implementation steps and gates

**Step 0 — Read-only hardware confirmation (no commits).** On the local
**RTX 5070 Ti** host (this user's) with the **installed 620.73.04** driver,
dump the discovered topology
with the existing debug logging (names after step 1, or a throwaway
drm_info-style probe): confirm the four pipeline names/shapes per plane,
cursor planes without COLOR_PIPELINE, `GAMMA_LUT_SIZE` (expected 1024), the
`LUT1D_INTERPOLATION` property shape (current-value vs enum-count
qualification, G2), and whether the curve ops still offer only the PQ 125
pair. The two empirical quirks (FP16 input-LUT refusal, inert FMT matrix)
were observed on 610/615 and may be fixed or changed on 620 — re-test them
with read-only discovery plus, once implementation exists, targeted atomic
tests and pixel checks; do not assume either behavior. Gate: shape matches
§2; otherwise stop and re-derive the affected rules.

**Step 0 results — 2026-11-22, local RTX 5070 Ti, nvidia-drm 620.73.04 (open
kernel module), kernel 7.3.5-3.1-devario.** Probe kept at
`compositor/scripts/probe-color-pipeline-topology.c` (read-only: separate fd,
caps ATOMIC → UNIVERSAL_PLANES → PLANE_COLOR_PIPELINE *in that order* — the
color cap requires ATOMIC first; no commits, blobs or writes). Run:
`cc -D_GNU_SOURCE -std=c11 probe-color-pipeline-topology.c $(pkg-config
--cflags --libs libdrm) -o probe && ./probe /dev/dri/card1`. The
`nvidia_drm.color_pipeline=Y` module parameter exists and is enabled.

Confirmed (matches §2):
- 4 primary + 4 overlay + 4 cursor planes; pipelines on all 8 primary/overlay
  planes, **none on cursor planes**; 32 pipelines total.
- Names unchanged: NVIDIA Full / Lite / FP Full / FP Lite — D3's name-based
  keying still valid.
- **Full (11 ops) and Lite (5 ops) identical in shape to 610/615**, including
  Full's non-bypassable trailing PQ pair and the 1024-entry linear 1D LUTs.
- Curve ops still offer **only** PQ 125 EOTF (enum 2) / PQ 125 Inverse EOTF
  (enum 3) — no SDR curves added; LUT decode synthesis still required.
- `LUT1D_INTERPOLATION` advertises exactly one enum, "Linear" (value 0,
  current) — the existing enum-count qualification works here; a
  current-value check is equivalent.
- Every CRTC: `GAMMA_LUT` + `GAMMA_LUT_SIZE`=1024, `DEGAMMA_LUT` 1024, `CTM`,
  `NV_CRTC_REGAMMA_LUT` (+ size 1024). D2's GAMMA_LUT post-blend path remains
  viable. All `COLOR_PIPELINE` current values are 0 (Bypass).

**Changed on 620.73.04** (vs 610.43.03 / 615.71.09):
- **FP Full: 8 → 7 ops.** The matrix between FMT and the non-bypassable
  PQ InvEOTF curve — the old CSC11 placement target for FP16 (`c5c2d494`) —
  is gone: Matrix(FMT), Curve{PQ125 InvEOTF} NB, Matrix, LUT(1024), Matrix,
  Curve{PQ125 EOTF} NB, Matrix.
- **FP Lite: 2 → 1 op.** Only Matrix(FMT) remains; the second matrix that
  carried FP16 gain/gamut is gone.
- Node accounting: 8 planes × (11+5+7+1) = 192 nodes; the lead developer's
  615 record had 208 = 8 × 26 — the −16 delta is exactly the two removed
  matrices per plane.

Re-derived rules and consequences:
1. **No hardcoded matrix positions.** Whether FMT is still inert for FP16 on
   620 is unresolved and *not* decidable read-only (a `c5c2d494`-class
   misplacement passes atomic check). Two possibilities: FMT still inert ⇒
   FP Lite can express no FP16 transform at all, and FP Full would need its
   trailing matrix (linear domain, after the EOTF curve) with the
   non-bypassable InvEOTF→EOTF pair programmed as a round-trip — mathematically
   identity, hardware precision unmeasured; or FMT now effective ⇒ FP Lite's
   single matrix carries gain+gamut. The reshape suggests the driver touched
   exactly this area.
2. **Conservative default until pixel-verified:** keep the planner rule
   "unused non-bypassable curve ⇒ reject" and "FMT inert on FP16". On the 620
   shapes this makes every FP16 transform resolve nowhere ⇒ **FP16 buffers
   (composed offload, Windows-scRGB scanout) fall back to ordinary renderer
   composition on nvidia** — existing behavior, no regression. Integer-format
   scanout via Lite + post-blend GAMMA_LUT encode is unaffected. The FP Full
   round-trip-pair extension becomes an explicit later sub-step, gated on
   pixel comparison; matrices *between* the pair act in the PQ domain and
   must never take linear-domain stages.
3. The FP16 input-LUT refusal quirk (`cee8872a`) is likewise unverified on
   620; re-test with TEST_ONLY commits once the backend path exists.

Additional observation (not in scope yet): CRTCs expose `NV_CRTC_REGAMMA_TF`
enum {Default=0, Linear=1, PQ (Perceptual Quantizer)=2} and
`NV_CRTC_REGAMMA_DIVISOR` (range [2^32 .. INT64_MAX], current 2^32 = 1.0 in
S31.32). A named hardware PQ regamma with divisor could replace the
linear-indexed 1024-entry GAMMA_LUT encode with better near-black precision.
Vendor-specific and unverified; candidate refinement only after the GAMMA_LUT
path passes acceptance.

Gate status: **passed with deltas.** Full/Lite-derived rules stand; FP
placement rules re-derived as above; FP16 effectiveness and ILUT refusal
deferred to implementation-phase atomic/pixel tests. Step 1's fixture models
the installed 620 shapes.

**Step 1 — Discovery + planner (new patch, backend only).**
G1–G4: names, interpolation qualification, capability on nvidia-drm,
`effective_ops`, cost DFS planner with LUT decode synthesis / gain folding /
identity programming, format-keyed resolution. Extend
`compositor/scripts/fixtures/color-pipeline.c` with a parameterized mock
topology modeling the **installed 620.73.04 shapes** (Step 0 results; ids
deliberately arbitrary, enum values >31 as today), keeping the 610/615 FP
shapes as extra cases, and port the spicy test matrix as C assertions:
encode-ending rejected on all four; linear-ending resolves on Lite; SDR
decode via LUT with gain ≤1 folded and >1 left pending; PQ decode gain
normalization (1/125); FP16 → FP pipelines only; FMT inert ⇒ on the 610/615
FP shapes stages land on the second matrix, on the 620 shapes FP16 resolves
nowhere (composition fallback); non-bypassable identity programming;
Full/FP Full rejected; blob lifetimes and reset-before-program unchanged.
Gate: `build-wlroots-render-hook.sh` harness incl. `AQUEOUS_COLOR_SANITIZE=1`;
existing amdgpu-shaped tests still pass (no regression to the greedy path's
accepted cases).

**Step 1 record — implemented 2026-11-22, gates passed.**
Patch `0047-drm-color-pipeline-nvidia-planner.patch` (touches only
`backend/drm/color_pipeline.c`; no header/ABI changes; registered in the
build script and `nix/core.nix`). Landed: G1 policy (nvidia-drm gated on
`AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND=1`, nouveau unqualified, other
drivers unchanged), G2 pipeline names + current-value interpolation
qualification, G3 cost-based DFS planner (LUT decode synthesis from the
kernel curve formulas, gain folding while the decoded range fits [0,1]
else normalize-and-pend, identity programming of non-bypassable
matrix/multiplier/LUT, fewest-LUTs preference, 4096-visit budget), G4
`pipeline_effective` FP16 rules (on the 620 shapes FP16 resolves nowhere ⇒
composition fallback). The framebuffer format is now required at commit
time via the recipe buffer's dmabuf attributes. Fixture: parameterized
mock topology (legacy 3-node kept; NVIDIA_620, NVIDIA_610, CONTROL), LUT
blob capture, per-source dmabuf format; the full test matrix above is
asserted, including named-curve preference over LUT synthesis for PQ.
Verification: full clean gate (archive + 47 patches at fuzz=0, strict
`-std=c23 -Werror` build, every dependency harness) exit 0; color harness
plain and ASan/UBSan exit 0. Iteration fixes: missing `<stdio.h>` /
`<limits.h>` (masked by the fixture's own includes) and fixture
`-Wmissing-braces` / format-truncation warnings. Still unexercised: real
nvidia atomic commits (need Steps 2–3 plus the opt-in flag) and the FP16
effectiveness pixel tests.

**Step 2 — Post-blend backend path (new patch).** G5–G7: linear-retargeted
recipe support, encode LUT as supplied `lut_3x1d` transform, content-stable
gamma blob cache per CRTC, ownership/reset/draining state on the connector,
GAMMA_LUT included in the final atomic test and in libliftoff assignment
tests, reset emitted on every owned primary commit without the offload.
Gate: fixture tests for ownership transitions (enable → disable → reset
committed → drained), blob-ID stability across identical frames, failed
test/commit releasing everything (extend the 512-transaction speculation
test).

**Step 2 record — implemented 2026-11-22, gates passed.**
Patch `0048-color-pipeline-post-blend-encode.patch` (registered in the build
script and `nix/core.nix`; no public ABI changes). Render side:
`color_pipeline_retarget_linear` strips the trailing encode curve and
appends `1/linear_max` (the PQ ×125 normalization ahead of the curve is
kept, so the plane outputs linear light in the encode curve's input scale);
`color_pipeline_encode_lut` builds the matching `lut_3x1d` from the kernel
inverse curves for the existing supplied-transform → GAMMA_LUT path.
Backend side (G7): the committed gamma blob plus a contents snapshot is the
cache — prepare borrows the committed ID while contents match, apply
transfers ownership and refreshes the snapshot, rollback never destroys a
borrowed ID, teardown releases both; the liftoff-fallback baseline restore
carries the cached flag. Atomic and libliftoff share prepare/apply/rollback,
so both paths get stable IDs and GAMMA_LUT lands in the same commit as the
plane state. Ownership/draining (G6) needs no backend state: wlroots output
state is scene-built per frame, so Step 3/4 express ownership by committing
`WLR_OUTPUT_STATE_COLOR_TRANSFORM` (encode LUT or NULL reset) every owned
frame and gating `scene_output_state_attempt_gamma` — a deviation from the
plan's connector-state wording, justified by the state model.
Tests: encode-LUT knots exact against the kernel curves; retarget semantics
and refusals; retargeted SDR→PQ recipe resolves on Lite with the normalized
gain on the trailing matrix; gamma cache 512-frame ID stability, failed-test
rollback preserving the committed cache, replacement/reset/teardown
ownership. The drm-sync harness now extracts the gamma helpers and varies
LUT contents per frame, exercising cache replacement under its 6000-frame
failure injection (plain + ASan/UBSan + negative controls). Verification:
full clean gate with 48 patches exit 0; color harness plain + ASan/UBSan
exit 0. Iteration fixes: drm-sync extraction list and its five-operation
failure model (the cache removes the repeat gamma-blob creation call).
Still unexercised: real nvidia commits (Step 3 scene wiring + opt-in flag).

**Step 3 — Scene + cursor integration (new patch).** G5, G6, G8, G9:
scanout path falls back from the full recipe to the post-blend variant under
D6 eligibility; composed FP16 offload retargets likewise; post-blend state
in the `WLR_PRIVATE` tail; cursor addon + linear variant + mode-toggle
refresh; cursor-visible rejection relaxed per D4; whole-output damage on
mode flips; verified-key cache extended; retry counters reuse the existing
120-frame policy.
Gate: headless/nested regressions — `test-output-retry.py` with a simulated
post-blend commit failure (extend `simulate_color_pipeline`), full-frame
pixel checks across offload enter/exit, cursor encoding checks, capture
paths still renderer-produced (existing invariant).

**Step 3 record — implemented 2026-11-22, gates passed.**
Patch `0049-scene-post-blend-cursor.patch` (10 files; registered in the
build script and `nix/core.nix`; new functions only, no struct ABI changes).
Capability is derived from discovery, not vendor names:
`wlr_drm_output_color_pipeline_needs_post_blend` is true when no pipeline
ends in a curve advertising an inverse EOTF and the CRTC has a GAMMA_LUT.
Scanout uses the linear-retargeted recipe for fullscreen opaque buffers
(the gamma LUT covers the whole output); the composed FP16 offload
retargets the combined transform the same way. The encode LUT is cached
per scene output by (tf, peak, gamma size); peak = `max_cll` else the
curve's default max; `linear_max = peak / 80`. Gamma ownership is scene
state (`color_pipeline_gamma_owned`): the gamma attempt is skipped while
owned — ramps defer naturally via `gamma_lut_changed` and apply on the
first non-offload frame, which also commits the reset; mode flips damage
the whole output. Cursor: an output addon selects the matrix-only
linear-light transform (1.0 = peak) and mode changes re-render cursor
buffers; the backend's blanket cursor-visible rejection became a
mode-match check (post-blend recipe ⇔ linearized cursor), so plane-only
conversion now also works with a visible hardware cursor. Capture stays
renderer-produced: capture locks already disallow direct scanout, which
disengages post-blend.
Tests: the color fixture extracts the scene ownership helpers and asserts
engage/disengage/reset/damage/cursor-sync and the LUT cache's exact
parameter tracking; cursor mode-match rejection both directions; the
legacy cursor-visible assertion updated to the relaxed semantics.
Verification: full clean gate with 49 patches exit 0 (86 PASS incl. the
scene harnesses and drm-sync); color harness plain + ASan/UBSan exit 0.
Gate deviation: headless cannot engage DRM post-blend, so the planned
nested pixel checks across offload enter/exit and the retry simulation of
a post-blend commit move to physical acceptance (Step 5); the generic
`simulate_color_pipeline` commit-failure knob already covers post-blend
commits once run on DRM. No Zig changes were needed (no ABI surface
change); config plumbing remains Step 4.

**Step 4 — Gamma guard + Zig plumbing.** G10: OutputWarming deferral while
owned (pending ramp → disable offload → reset commit → apply on vblank),
fixture tests for the deferral sequence; config/env parsing for the
post-blend flag (startup-only, reload warns like the parent setting);
`c.h`/ABI checks; IPC state exposure if the retry simulation surface grows.
Gate: Zig unit tests (config, OutputWarming fixture, ABI), full `zig build
test` suite.

**Step 4 record — implemented 2026-11-22, gates passed.** Zig/config only;
no wlroots changes, so the Step 3 49-patch gate remains current.
- Config: `[render] color_pipeline_post_blend` (bool, default false) in
  `wm/config/wm.zig` with `parseBool` semantics (invalid keeps previous);
  startup-only reload warnings at both `Aqueous.zig` reload sites; `wm.toml`
  documents the setting and the stale "auto disables NVIDIA" comment was
  corrected. `main.zig` honors `AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND=1/0`
  as an override (invalid warns) and setenvs it before backend creation,
  mirroring the parent setting.
- Gamma guard (G10): **no code change needed** — verified composition.
  `guardGamma` allows acquisition on eligible outputs; the scene defers
  ramps while post-blend owns gamma (`gamma_lut_changed` stays set) and
  applies them on the disengage frame alongside the reset. `guardCommit`
  strips `color_transform` for gamma-owned outputs, so per-frame encode
  LUT commits do not revoke warming; warming transition locks disallow
  scanout, disengaging post-blend. Engaging post-blend revokes an active
  warming lease once through the existing `changesColor` transition
  semantics (one revoke, then `o.lease` is null).
- `c.h` unchanged: no new Zig→C calls and no struct ABI changes; the ABI
  checks pass inside the suite. The retry-simulation surface did not grow
  (the generic commit-failure knob covers post-blend commits on DRM).
- Verification: `zig build test --summary all` 127/127 steps succeeded
  (includes the new post-blend config test, OutputWarming fixture, ABI
  checks); `zig build` exit 0 against the Step 3 library.

**Step 5 — Docs + acceptance.** Update `docs/color-pipeline.md` (operation
coverage table: LUT-synthesized decodes, post-blend encode, FP16 rules;
NVIDIA policy section), `wm.toml.example`, README test lists. Note:
`docs/color-pipeline.md` links a missing `color-pipeline-implementation-plan.md`;
this file is separate — fix the link only if asked.

**Physical acceptance (local RTX 5070 Ti, installed 620.73.04, HDR sink;
cross-check on the lead developer's RTX 5090 desirable before defaults flip):**
1. SDR sRGB fullscreen content on a PQ output scans out via Lite + GAMMA_LUT
   (debug log shows pipeline id + gamma LUT committed); measured pixels
   match the renderer reference within tolerance. **Pre-KMS screencopy
   cannot establish this** (existing docs rule) — measure a path that
   includes plane + CRTC processing.
2. FP16 scRGB composed offload: correct brightness (the `c5c2d494` failure
   mode is silent — atomic-test success is not acceptance), stages verified
   on CSC11 via the programmed blob contents in logs/tests.
3. Cursor: correct color in both modes, no stutter on animated cursors,
   mode toggles re-encode without flicker.
4. Offload enter/exit is flip-only — no modeset/blank (watch NVKMS behavior
   on the DP connector); HDR metadata stays stable across fullscreen
   transitions (static-metadata design, verify).
5. Gamma-control client (night light): ramp deferred, offload disables,
   ramp applies after reset, offload may re-engage after ramp removal.
6. VT switch/resume, hotplug, device loss: gamma ownership and pipelines
   reset cleanly (existing recovery paths).
7. Near-black gradient inspection for banding (known precision limit, §2.5);
   record `linear_max` used.

**Step 5 record — docs done 2026-11-22; physical acceptance pending a user
session.** `docs/color-pipeline.md` updated (policy, post-blend paths, cursor
mode-match, operation table, patches 0046–0049, harness coverage, new
validation record); `wm.toml` was updated in Step 4; README needs no change
(its dev workflow already runs the harnesses). Added a post-blend
engage/disengage debug log (with `linear_max`) to the scene ownership helper
for acceptance observability; 0049 regenerated, color harness and the full
49-patch gate re-passed (exit 0, 86 PASS). Sink survey (read-only): DP-1 is
HDR-capable (ST2084 + BT2020, desired max luminance ≈ 486 cd/m², min 0.097);
HDMI-A-1 has no HDR block. The user's desktop is the installed Aqueous
session, so acceptance must be run by the user from a TTY.

### Acceptance runbook (local 5070 Ti, DP-1 HDR sink)

1. Switch to a free VT (Ctrl+Alt+F2…) and log in. The current desktop session
   pauses while the acceptance session holds DRM master.
2. Launch the dev session with the opt-in (the script rebuilds/stages the
   patched library automatically and logs at debug level):
   ```sh
   cd ~/Source/Repos/Aqueous
   AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND=1 ./launch_aqueous.sh
   ```
   Log: `/tmp/aqueous.log`. Startup markers to expect:
   `color pipeline capability enabled (experimental)` for the nvidia-drm fd,
   `4 color pipelines discovered` per primary/overlay plane with the
   `NVIDIA Full/Lite/FP Full/FP Lite` debug names.
3. Enable HDR on DP-1 through the usual output HDR control.
4. Test matrix (observe display + log):
   - Fullscreen **SDR sRGB** content (image viewer/browser, white and gray
     gradients) on the PQ output → `post-blend encode engaged (linear_max …)`
     and `color pipeline <Lite root> active`; colors match the renderer path
     (A/B against a session without the flag; camera/photometer if available —
     pre-KMS screencopy cannot establish KMS color).
   - Fullscreen **PQ HDR** content matching the output → raw scanout, no
     post-blend log (conversion not needed).
   - Multi-window/effects composition → composed offload engages; FP16
     content stays composited on 620 (expected, conservative rule).
   - Cursor over fullscreen content in both modes: consistent color, no
     flicker on enter/exit, no stutter with animated cursors.
   - Gamma-control client (night light) during offload: ramp defers; leaving
     fullscreen disengages post-blend and applies the ramp; removing the ramp
     allows re-engagement.
   - Repeated fullscreen enter/exit: flip-only, no blanking/modeset; HDR
     metadata stable (static per-level design).
   - VT switch away/back, DP hotplug, suspend/resume: clean recovery, gamma
     ownership reset (disengage log or reset on first frame).
   - Near-black gradient: note banding; record the logged `linear_max`.
5. Exit the session, return to the desktop VT, and share `/tmp/aqueous.log`
   for analysis (pipeline IDs, engage/disengage sequence, error paths).

## 6. Risks and adjacent work (not in scope unless triggered)

- **Near-black banding**: linear-indexed 1024-entry gamma LUT. Mitigate with
  sink-peak `linear_max`; document as experimental caveat (niri does).
- **Silent FMT misplacement**: atomic check passes, pixels wrong. Pixel
  acceptance is a hard gate; keep the effectiveness rule conservative.
- **Blob churn → modeset**: G7's stable gamma blob cache is mandatory before
  any physical run; NVKMS modesets on connector state changes are documented
  in 598c5908.
- **NVIDIA KMS in-fence reliability** (1bfaa833/064e3066): if unfinished
  frames appear with color offload, the proven mitigation is waiting on
  plane fences in the event loop before queueing without IN_FENCE_FD.
  Aqueous already has extensive sync work (0020/0037/0041,
  docs/gpu-sync-fd-investigation.md); treat as a follow-up, not part of this
  plan.
- **10-bit scanout under HDR** (d9131c33): verify Aqueous's HDR toggle picks
  10-bit-capable formats and floors max bpc; the composed offload already
  uses FP16. Only act if acceptance shows 8-bit PQ banding.
- **Tone mapping**: Aqueous keeps its existing shader policy; any
  tone-mapped/auto-HDR-expanded content stays composed (parametric pipelines
  can't express it — same rule as 8398f816).
- **Driver drift**: names/shapes stable across 610→615, ids shift; the
  installed 620.73.04 is beyond the verified range and may have changed
  topology or fixed the FP16/FMT quirks. Discovery stays dynamic; step 0
  re-runs on driver upgrades, and the vendor-rule function (D3) is the only
  place behavior assumptions may need revising.

## 7. Open choices (recommendations settled above, flag if disagreed)

1. Post-blend opt-in flag first, default-on after acceptance (D7).
2. HDR outputs first; SDR-output post-blend and overlay-plane linear scanout
   as phase 2 (D6/D7).
3. Gamma-control deferral rather than composing ramp∘encode into one LUT
   (D5) — deferral is the proven behavior; composition is a possible later
   refinement that would keep night light active during offload.