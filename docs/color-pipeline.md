# DRM color pipelines

Aqueous has experimental support for DRM plane `COLOR_PIPELINE` and
`drm_colorop`, carried in its private wlroots 0.20.2 dependency. It defaults to
**auto**, attempting compatible hardware pipelines with renderer fallback.
On NVIDIA, whose plane pipelines always end in linear light, hardware
conversion additionally requires the experimental **post-blend encode** opt-in
(`color_pipeline_post_blend`), which moves the final encode behind blending
onto the CRTC `GAMMA_LUT`.
The implementation has passed builds, mock DRM tests and headless
regressions; no GPU/display combination has completed physical color acceptance.

Configure it in your instance's `wm.toml` (`~/.config/aqueous/wm.toml`, or
`~/.config/aqueous-git/wm.toml` for the Git package):

```toml
[render]
color_pipeline = "off"
color_pipeline_post_blend = false
color_pipeline_fp16_fmt = false
```

`"auto"` is the default; `"off"` keeps the existing rendering path. Invalid
values are ignored. **Restart the compositor session after changing it**:
capability negotiation applies to the DRM connection. Config reloads warn and
retain the running mode until restart.

`AQUEOUS_DRM_COLOR_PIPELINE=auto|off` remains available as a startup override
and takes precedence over `wm.toml`. Remove that override to use the file setting.
Invalid environment values warn and fall back to the file setting.
`color_pipeline_post_blend` (default `false`) is likewise startup-only, with
`AQUEOUS_DRM_COLOR_PIPELINE_POST_BLEND=1|0` as its override; it has no effect
unless `color_pipeline` is `auto`.
`color_pipeline_fp16_fmt` (default `false`) is a startup-only experimental
assumption that the leading FMT matrix takes effect on FP16 surfaces, with
`AQUEOUS_DRM_COLOR_PIPELINE_FP16_FMT=1|0` as its override. NVIDIA 620 reshaped
the FP pipelines (FP Lite is FMT-only), and FMT effectiveness for FP16 is not
decidable read-only; the conservative default treats FMT as inert, so composed
FP16 offload stays composited. With the assumption enabled, gain-folded
matrices resolve on FP Lite and composed post-blend offload can engage. An
inert FMT silently drops the placed color stage while the atomic check still
passes: verify pixels before relying on it, and flip it back if colors are
wrong. It has no effect unless `color_pipeline` is `auto`.
The capability policy checks the DRM backend's driver before enabling the
client capability: `nvidia-drm` requires the post-blend opt-in, `nouveau` is
unqualified, and other GPUs use the discovered pipelines directly. Other GPUs
in the same machine retain their own policy. If driver identification fails,
hardware color pipelines remain disabled for that backend.
This setting does not change driver module settings or HDR
policy. Nested/headless, legacy DRM and multi-GPU secondary backends do not use
hardware color pipelines.

## Rendering paths

The scene computes a complete source-to-destination recipe using the same
primaries, luminance and output-transfer policy as rendering. Hardware conversion
is attempted for eligible opaque RGB fullscreen buffers and promoted overlays.
Existing effects, geometry, opacity and synchronization checks still apply.
Auto HDR expansion stays in the shader.

On outputs whose pipelines cannot express a terminal encode (nvidia), the
encode moves **behind blending**: the plane outputs normalized linear light
(1.0 at the sink peak, `linear_max = peak / 80` in the PQ-125 scale) and the
CRTC `GAMMA_LUT` applies the encode to the blended result. This applies to
fullscreen direct scanout and to the composed FP16 offload alike; the gamma
LUT covers the whole output, so partial-coverage buffers stay composed.
While a frame offloads the encode, the compositor owns the CRTC gamma LUT:
gamma-control ramps defer and apply on the first frame without the offload,
which also commits the LUT reset. Mode transitions force complete damage.
The cursor plane passes through the same gamma LUT, so post-blend frames
render the cursor in matching normalized linear light; plane-only conversions
keep the wire-encoded cursor. A mismatch between the conversion kind and the
cursor mode rejects hardware conversion for that frame.

For composed output, Vulkan can render into a separate linear FP16
`XBGR16161616F` swapchain and put only the final output conversion in KMS. The
renderer still performs scene composition and effects. Switching between this
path and ordinary composition forces complete damage. If the format, modifier
or color recipe fails a test, ordinary output rendering is used. FP16
framebuffers use only nvidia's "FP" pipelines, whose leading format matrix is
inert for FP16; on driver 620.73.04 those pipelines were reshaped so no FP16
transform currently resolves and FP16 content stays composited until the
effectiveness rules are pixel-verified.

Captures and mirrors that lock output rendering keep a renderer-produced buffer
in the advertised destination encoding. This includes output screencopy,
ext-image-copy output capture and Aqueous mirroring. Isolated scene capture has
its own renderer destination and does not consume the pre-KMS buffer.

Composed final-conversion offload excludes software-cursor locks, custom
swapchains, supplied transforms, rendered gamma LUTs and overlay candidates.
YUV scanout is rejected once
the color-pipeline capability is enabled, because that capability disables
implicit legacy plane YUV conversion; those buffers remain composed.

## Operation coverage

| Operation | Implementation |
| --- | --- |
| Extended linear | No transfer-curve operation; retains floating-point values |
| sRGB and gamma 2.2 | Named curves when advertised; otherwise synthesized into a 1D LUT from the exact kernel curve formulas |
| PQ | Named PQ-125 decode/encode with explicit `1/125` and `125` normalization |
| Gamut/luminance matrices | Ordered 3×4 S31.32 sign-magnitude blobs, with finite/range checks |
| Multiplier | S31.32 property, folded into an adjacent matrix or a synthesized decode LUT while the decoded range fits `[0,1]` |
| 1D LUT | Exact size, or linear resampling with error at source knots at most `1/65535`; sizes 2–65536 |
| Post-blend encode | Trailing encode stripped from the recipe, output normalized by `1/linear_max`, encode sampled into a `GAMMA_LUT`-sized 3×1D LUT committed with the plane state |
| Non-bypassable unused matrix/multiplier/LUT | Programmed to identity |
| Non-bypassable unused curve, unknown mandatory operations | Pipeline rejected for the recipe; renderer fallback |
| BT.1886, LCMS2/3D LUT | Renderer fallback |
| Unknown operation with advertised bypass | May be bypassed while matching the remaining recipe |

Matching is a bounded cost-based search over assignments of recipe operations
to pipeline operations; among complete plans the fewest LUTs wins, so named
curves stay preferred over synthesis. Format effectiveness follows the nvidia
display engine: FP16 framebuffers exclude the non-FP pipelines (their
input-LUT operations fail atomic check) and leave the leading format matrix
inert. These are implemented mappings, not measured hardware guarantees.
Kernel curve names and PQ normalization follow the
[KMS colorop definitions](https://dri.freedesktop.org/docs/drm/gpu/drm-kms.html#colorop-functions-reference).
Device-specific clipping, interpolation and precision still require comparison
with the renderer, especially negative scRGB values and HDR highlights. A
linear-indexed gamma LUT has limited precision near black; `linear_max` uses
the sink peak to minimize banding. Arbitrary
LCMS domains and 3D LUT interpolation are deliberately not approximated.

## State, assignment and recovery

Patch `0025-drm-color-pipeline.patch` provides discovery, recipe ownership,
compilation and both DRM commit paths. Patch `0026-scene-color-pipeline.patch`
connects fullscreen, overlays and composed output. Patch
`0046-color-pipeline-stable-blobs.patch` keeps DATA blob IDs stable across
unchanged commits. Patch `0047-drm-color-pipeline-nvidia-planner.patch` adds
pipeline names, the cost-based planner and format effectiveness; patch
`0048-color-pipeline-post-blend-encode.patch` adds the linear retarget/encode
LUT helpers and the content-stable CRTC gamma blob cache; patch
`0049-scene-post-blend-cursor.patch` wires post-blend into scanout and
composition with gamma ownership and the cursor linear-light mode. The
reference designs are
[wlroots MR !5220](https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/5220)
and the nvidia color-pipeline work in the local spicy niri/smithay tree
(knowledge only, no code reuse); the derived evidence and gates are recorded
in [the nvidia plan](color-pipeline-nvidia-plan.md).

Recipes are immutable buffer wrappers. They lock their source and retain LUT
transforms until output state and framebuffer users release them. Existing
output/output-state layouts remain unchanged; Zig checks their ABI. The scene's
extra swapchain state is allocated and destroyed in C.

Topology discovery has bounded root/node counts and cycle detection. Matching
has a bounded search and creates blobs only after a compatible chain is found.
Both commit paths reset previous assignments before programming new ones. Every
test, failure and real commit releases temporary blob references; the kernel
retains its committed references.

With libliftoff, color properties use the allocator's actual physical plane IDs.
A final atomic test includes that assignment and all color properties. An
incompatible assignment falls back to composition; this implementation does not
search every alternative plane allocation.

Rejected fullscreen recipes and composed-primary attempts have a 120-frame
retry delay. Relevant output-state changes permit retry sooner. A failed real
color or overlay commit triggers one full renderer rebuild with scanout locked,
followed by the existing bounded output retry handling if that commit also fails.

Debug logs distinguish compiled-but-disabled support, capability negotiation,
plane discovery, incompatible recipes and a successfully committed pipeline ID
with its DRM fd, CRTC and plane. Discovery alone does not demonstrate activation.

## Build and tests

Both the local build script and Nix patch list include patches 0025–0026 and
0046–0049. A
Meson compile probe checks the required libdrm UAPI declarations; builds with
older headers retain the ordinary rendering path. The tested headers were
libdrm 2.4.134, with libliftoff 0.5.0. No new library dependency is required.

`compositor/scripts/build-wlroots-render-hook.sh` runs the color-pipeline harness
alongside the existing dependency regressions. To rerun it against a retained
patched source tree and installed prefix:

```sh
python3 compositor/scripts/test-color-pipeline.py /path/to/patched/wlroots /path/to/prefix
AQUEOUS_COLOR_SANITIZE=1 python3 compositor/scripts/test-color-pipeline.py /path/to/patched/wlroots /path/to/prefix
```

The harness compiles the production recipe/compiler code and actual libliftoff
assignment helpers with mock DRM calls. It checks topology errors, large enum
values, operation ordering, PQ scale, fixed-point packing, LUT resampling, source
ownership, blob/property failures, 512 speculative transactions, pipeline reset,
retained overlays, multi-output reassignment and scene teardown. It also compiles
the no-UAPI backend. Missing UAPI headers produce an explicit skip.
Parameterized mock topologies reproduce the nvidia pipelines discovered on
driver 620.73.04 (and the earlier 610/615 FP shapes): encode-ending rejection,
LUT decode synthesis with gain folding, FP16 effectiveness, identity
programming, post-blend encode LUT values, gamma blob stability and ownership,
cursor mode-match rejection, and the scene's gamma ownership/reset/damage
helpers. `test-drm-sync.py` exercises the gamma cache replacement path under
its 6000-frame failure injection.

`test-output-retry.py` includes a simulated hardware-color commit failure that
checks the complete fallback frame and bounded recovery. Its fault controls
require a private `-Doutput-retry-testing=true` build.

## Validation record

Nvidia color-pipeline work on 2026-11-22 (local RTX 5070 Ti, `nvidia-drm`
620.73.04 open kernel module, kernel 7.3.5-3.1-devario; derived from the spicy
niri/smithay commits, see [the nvidia plan](color-pipeline-nvidia-plan.md)):

| Check | Result |
| --- | --- |
| Read-only topology probe (`compositor/scripts/probe-color-pipeline-topology.c`) | 32 pipelines on 8 planes; Full/Lite unchanged from 610/615; FP Full 8→7 ops, FP Lite 2→1 (FMT-only); cursor planes have no pipelines; GAMMA_LUT size 1024 |
| Clean wlroots archive + all 49 patches, build/install and dependency harnesses | Passed |
| Color harness incl. nvidia topologies, post-blend and scene ownership, plain + ASan/UBSan | Passed |
| drm-sync 6000-frame failure injection with gamma cache replacement, plain + ASan/UBSan + negative controls | Passed |
| Zig compositor unit tests and ABI checks (`zig build test --summary all`) | Passed, 127/127 steps |
| Compositor build against the patched library | Passed |

FP16 effectiveness on 620 (inert FMT assumption) and the FP16 input-LUT refusal
remain unverified on hardware; FP16 content stays composited until pixel
checks confirm the rules. Physical acceptance on the DP-1 HDR sink
(ST2084/BT2020, desired max luminance ≈ 486 cd/m²) is the remaining gate.

Software checks on 2026-09-16:

| Check | Result |
| --- | --- |
| Clean wlroots archive + all 26 patches, build/install and dependency harnesses | Passed |
| Color compiler/backend harness with ASan/UBSan and leak detection | Passed |
| Zig compositor unit tests and ABI checks | Passed, 515/515 tests |
| Vulkan-effects and `-Dvulkan-effects=false` builds | Passed |
| Output retries including color-failure recovery and full-frame pixels | Passed, private headless session |
| Output mirroring, isolated scene capture, overlay policy/backend and capture formats | Passed, headless/mock coverage |
| SDR/HDR luminance encoding, Proton v1/Windows HDR v3 protocol and Auto HDR settings | Passed |
| Output preview/Keep/rollback and failure recovery | Passed, private headless session with current helper/test adapter |
| Snapshot colors: normal, opacity 0.95 with blur, fullscreen opacity 0.95 | Passed, nested Vulkan sessions on a private headless host |
| Vulkan effects/render seam, validation layer, 4096 reused-buffer frames per run | Passed; cached and uncached pixels agree within the existing `0.0002` tolerance |
| Read-only production topology discovery | 32 pipelines/208 nodes on `nvidia-drm`; 6 pipelines/48 nodes on `amdgpu` |

The effects regression exposed an existing harness error: its uncached reference
required cache-hit samples. That assertion now applies only to the cached run.
Both runs still exercise the same damage sequence, and the uncached run retains
its zero-cache accounting checks and the final pixel comparison.

GPU devices were hidden inside the sandbox but accessible to private tests
outside it. Vulkan rendering used an NVIDIA GeForce RTX 5090 with NVIDIA driver
615.71.09. Read-only discovery used kernel `7.2.5-1-cachyos`, separate DRM file
descriptors and no display commits. Discovery is not a physical support matrix.

Physical atomic/libliftoff scanout, HDR color comparisons, VT/resume,
hotplug/device loss and performance measurements remain unperformed. No physical
color-accuracy guarantee follows from these results.
Acceptance must measure a path that includes plane color processing; pre-KMS
screencopy cannot establish it. The remaining gates are recorded in
[the implementation plan](color-pipeline-implementation-plan.md).
