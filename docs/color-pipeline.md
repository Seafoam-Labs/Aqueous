# DRM color pipelines

Aqueous has experimental support for DRM plane `COLOR_PIPELINE` and
`drm_colorop`, carried in its private wlroots 0.20.2 dependency. It is **off by
default**. The implementation has passed builds, mock DRM tests and headless
regressions; no GPU/display combination has completed physical color acceptance.

To opt in for a new DRM session, set:

```sh
AQUEOUS_DRM_COLOR_PIPELINE=auto aqueous
```

Use `AQUEOUS_DRM_COLOR_PIPELINE=off` or leave the variable unset to keep the
existing rendering path. This is a startup setting: capability negotiation
applies to the DRM connection. It does not change driver module settings or HDR
policy. Nested/headless, legacy DRM and multi-GPU secondary backends do not use
hardware color pipelines.

## Rendering paths

The scene computes a complete source-to-destination recipe using the same
primaries, luminance and output-transfer policy as rendering. Hardware conversion
is attempted for eligible opaque RGB fullscreen buffers and promoted overlays.
Existing effects, geometry, opacity and synchronization checks still apply.
Auto HDR expansion stays in the shader.

For composed output, Vulkan can render into a separate linear FP16
`XBGR16161616F` swapchain and put only the final output conversion in KMS. The
renderer still performs scene composition and effects. Switching between this
path and ordinary composition forces complete damage. If the format, modifier
or color recipe fails a test, ordinary output rendering is used.

Captures and mirrors that lock output rendering keep a renderer-produced buffer
in the advertised destination encoding. This includes output screencopy,
ext-image-copy output capture and Aqueous mirroring. Isolated scene capture has
its own renderer destination and does not consume the pre-KMS buffer.

Hardware color conversion is currently rejected with a visible hardware cursor.
Composed final-conversion offload also excludes software-cursor locks, custom
swapchains, supplied transforms, rendered gamma LUTs and overlay candidates.
Existing CRTC gamma remains after plane conversion. YUV scanout is rejected once
the color-pipeline capability is enabled, because that capability disables
implicit legacy plane YUV conversion; those buffers remain composed.

## Operation coverage

| Operation | Implementation |
| --- | --- |
| Extended linear | No transfer-curve operation; retains floating-point values |
| sRGB and gamma 2.2 | Named decode and encode curves, only when advertised |
| PQ | Named PQ-125 decode/encode with explicit `1/125` and `125` normalization |
| Gamut/luminance matrices | Ordered 3×4 S31.32 sign-magnitude blobs, with finite/range checks |
| Multiplier | S31.32 property, or combined with an adjacent matrix |
| 1D LUT | Exact size, or linear resampling with error at source knots at most `1/65535`; sizes 2–65536 |
| BT.1886, LCMS2/3D LUT, unknown mandatory operations | Renderer fallback |
| Unknown operation with advertised bypass | May be bypassed while matching the remaining recipe |

These are implemented mappings, not measured hardware guarantees. Kernel curve
names and PQ normalization follow the
[KMS colorop definitions](https://dri.freedesktop.org/docs/drm/gpu/drm-kms.html#colorop-functions-reference).
Device-specific clipping, interpolation and precision still require comparison
with the renderer, especially negative scRGB values and HDR highlights. Arbitrary
LCMS domains and 3D LUT interpolation are deliberately not approximated.

## State, assignment and recovery

Patch `0025-drm-color-pipeline.patch` provides discovery, recipe ownership,
compilation and both DRM commit paths. Patch `0026-scene-color-pipeline.patch`
connects fullscreen, overlays and composed output. The reference design is
[wlroots MR !5220](https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/5220),
adapted to the pinned dependency rather than applied unchanged.

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

Both the local build script and Nix patch list include patches 0025–0026. A
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

`test-output-retry.py` includes a simulated hardware-color commit failure that
checks the complete fallback frame and bounded recovery. Its fault controls
require a private `-Doutput-retry-testing=true` build.

## Validation record

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
support matrix or default-enablement claim follows from these results.
Acceptance must measure a path that includes plane color processing; pre-KMS
screencopy cannot establish it. The remaining gates are recorded in
[the implementation plan](color-pipeline-implementation-plan.md).
