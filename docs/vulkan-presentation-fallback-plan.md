**Vulkan presentation fallback implementation plan**

Status: automatic Vulkan candidate selection and synchronous SDR fallback implemented.
The broader platform qualification plan remains open.
Aqueous must have usable Vulkan to start and
continue rendering. Separate composition from presentation so an output can use
display-compatible buffers even when it cannot display the Vulkan render target
directly. Keep effects in the Vulkan composition pass.

**Implemented (2026-10-07)**

- Private wlroots patch `0030-vulkan-presentation-copy.patch` separates the Vulkan
  image from the output allocation. It uses an optimal BGRA8 image, dedicated
  staging memory, a completed Vulkan transfer, and a stride-aware CPU copy into
  DRM dumb or SHM buffers. Allocation/import/scene-build failures can select copy
  per output; a failed normal frame commit can rebuild and retry once.
- Copied outputs hold composition and software-cursor locks and reject overlay
  promotion. Resize replaces incompatible swapchains, output destruction releases
  owned allocations, and renderer replacement resets the selection. Diagnostics
  distinguish `cpu-copy-pending` from a copied frame accepted by an output commit.
- Lavapipe can render without a DRM render node or external DMA-BUF extensions.
  Patch `0031-vulkan-device-selection.patch` enumerates Vulkan physical devices:
  preferred hardware first, remaining hardware (including alternate ICDs) next,
  CPU Vulkan last. Virtual GPUs count as hardware. Explicit device and software
  restrictions remain binding. Required effects capabilities and allocator
  creation are checked for every candidate. DMA-BUF globals require a usable FD.
- Initial output allocation, scene rendering and real commits run before client
  sockets, Xwayland and desktop commands start. Direct failures try synchronous
  SDR copy on the same GPU. A rejected candidate is torn down before the next
  candidate is attempted. Exhaustion exits nonzero; GLES2/Pixman are not fallbacks.
  With no connected outputs, initial presentation is deferred until hotplug.
  Live GPU resets recreate the exact selected physical device; failure terminates
  the session rather than migrating existing clients to a different GPU.
- Arch/Devario's shared private-wlroots builder and Nix include patches 0030–0031.
  Normal builds enable automatic selection. Test-only fault injection remains
  excluded from production packages; old experimental build artifacts remain
  rejected. CI runs selector fault tests, software Vulkan pixel/capture tests,
  and compositor startup rejection/cleanup tests.
- A separate Mesa 26.2.4 patch and source manifest live under
  `packaging/mesa/26.2.4/`. They preserve public device identity and move NVIDIA's
  forced buffer-blit policy into WSI, retaining the older-driver software-WSI
  restriction. Devario's `devario-custom-packagbuilds` repository integrates this
  patch in `devario-core/vulkan-virtio` release `1:26.2.4-3`, replacing the previous
  engine-name exception. Its prepare/build/check/package functions pass on the
  development host. An isolated signed build and VM qualification remain pending.

Normal builds default to automatic presentation. Build and run locally:

```sh
cd compositor
scripts/build-wlroots-render-hook.sh
PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" \
  zig build -Dllvm=true -Doptimize=ReleaseSafe
AQUEOUS_VULKAN_PRESENTATION=auto zig-out/bin/aqueous
```

`direct` disables copy/software fallback while still trying hardware candidates;
`copy` forces copying, and `auto` prefers direct presentation. Software-only systems need an installed, working Lavapipe ICD. An explicit
`WLR_RENDERER_FORCE_SOFTWARE=1` selects software Vulkan through wlroots; it does
not select a different rendering API. Only run session launch commands in the
intended test session.

Local verification covers the complete private-wlroots build/check suite,
production and fault-injection compositor builds, startup failures, packaging gates,
real Vulkan pixel comparisons, injected allocation failure, per-output isolation,
headless hotplug, resize/reuse/reset, and toplevel capture with lock/unmap denial.
Lavapipe and native NVIDIA tests passed with Vulkan validation enabled; native
AMD direct capture also passed. These are headless tests, **not physical scanout
or VM qualification**. Mesa's two changed C files compile against 26.2.4, and
`packaging/mesa/test-venus-wsi.py` exercises its production policy functions.

The copy waits synchronously for up to one second and copies whole frames in
8-bit SDR. These are accepted limits for this failure path, not release gates.
Working direct presentation retains HDR and its existing rendering path; other
GPUs are initialized only when the earlier candidate fails. Candidate enumeration
adds startup work, not a copy or synchronization cost to direct frames.

Selector tests cover device ordering, inaccessible nodes, alternate ICDs,
restrictions, resource ownership and exhaustion under ASan/UBSan, with mutation
controls. Real headless NVIDIA + AMD + Lavapipe tests reject each candidate at
renderer, effects, allocator and initial commit stages; they verify hardware is
exhausted before software and rejected candidates never start desktop commands.
A direct-only failure commits copied frames on the same GPU. These tests do not
qualify physical scanout, Intel or VM configurations.

Remaining work includes the vendor/hypervisor matrix, capture/mirror/reset
qualification on real outputs, performance measurements, and the recorded Zink
modifier, allocation and synchronization errors. Signed Mesa release packages
and installed-VM configuration still need their own qualification. Async copies,
GPU-to-GPU copies and copied HDR are optional future improvements. No launcher
or live-ISO policy was changed.

The existing mirroring path still requires renderer DRM timeline support;
Lavapipe mirroring is therefore rejected. The Vulkan preview tests pass earlier
transaction checks but stop at that known restriction. The complete preview
suite uses the explicit no-effects Pixman diagnostic build, which is not a
production session fallback.

The stages below describe the broader qualification and development plan;
implemented startup selection does not mark the entire plan complete.

| Available capabilities, in preference order | Rendering and presentation | Effects |
| --- | --- | --- |
| Usable hardware Vulkan and compatible display buffers | Render into buffers accepted by the output | Enabled |
| Usable hardware Vulkan, incompatible direct buffers, working copy | Render on the GPU, then copy into accepted display buffers | Enabled |
| Usable software Vulkan and working copy | Render with Lavapipe, then copy into accepted display buffers | Enabled if the required effects capabilities pass; slower |
| No usable Vulkan, including failure of required Vulkan capabilities | Exit with a clear error and nonzero status | No session |

Lavapipe is still Vulkan and remains in scope. There is no automatic GLES2 or
Pixman compatibility session. If Vulkan rendering works but every presentation
path fails, report a presentation failure separately and fail startup. Loader
presence, an enumerated device, or `vulkaninfo` success alone does not establish
a usable Aqueous renderer.

**Current integration points**

- [fx.zig](../compositor/aqueous/fx.zig) forces Vulkan in effects builds and
  rejects another renderer. Preserve that production contract. The existing
  `-Dvulkan-effects=false` diagnostic build remains a test tool, never a session
  fallback selected by packaging or startup code.
- [Server.zig](../compositor/aqueous/Server.zig) creates one renderer and
  allocator, derives client GPU selection from the renderer's DRM device, and
  recreates rendering after GPU loss. Allocation and device selection need to
  accommodate a renderer whose targets cannot be displayed directly.
- [VulkanContext.zig](../compositor/aqueous/render/VulkanContext.zig) borrows
  wlroots' device and queue and enables its offscreen effects path. The existing
  FP16 effects intermediate is not proof of a display-buffer copy fallback.
- [Output.zig](../compositor/aqueous/Output.zig) builds and commits normal
  frames; [OutputManager.zig](../compositor/aqueous/OutputManager.zig) prepares
  swapchains and commits output configuration transactions. Both must use the
  same presentation policy, including retries and preview rollback.
- [OutputMirror.zig](../compositor/aqueous/OutputMirror.zig), overlay policy,
  capture, output warming, and the private wlroots color/synchronization patches
  also consume buffers or depend on commit completion.

Keep buffer ownership, image transitions, submission, and output synchronization
inside private wlroots, consistent with the
[existing render-hook decision](architecture-decisions/0001-vulkan-render-seam.md).
Aqueous owns selection policy and diagnostics. Do not append an independent
Aqueous queue submission after wlroots has already signaled frame completion.

**1. Reproduce and isolate the working prototype**

Import the exact NVIDIA prototype diffs and reproduction logs before porting
the copy mechanism. Record Aqueous, wlroots, guest Mesa, virglrenderer,
hypervisor, host driver, and kernel revisions. Treat the supplied prototype as
evidence for its tested configuration only; it does not implement the Lavapipe
path. Keep its Zink engine-name workaround separate from the compositor patch.

Add a test-only way to force direct presentation, force copy, and inject failures
at allocation, import, submission, synchronization, output test, and commit.
Capture direct and copied frames of the same effects scene. Establish buffer
ownership and fence lifetimes before optimizing copies or enabling selection
automatically.

Acceptance: a repeatable private test demonstrates the prototype's copy path,
preserves effects, and reproduces the recorded Mesa/client errors separately.

**2. Define renderer eligibility and per-output presentation state**

Introduce a small presentation policy module, proposed as
`compositor/aqueous/render/Presentation.zig`, with per-output state stored through
`Output.zig`. Keep renderer choice at session scope initially: one Vulkan device
can serve a direct output and a copied output simultaneously. Lavapipe selection
replaces the session renderer; it is not an independent renderer automatically
created for each output.

At startup, evaluate hardware candidates before software Vulkan, respecting
explicit device restrictions. For each candidate, prove the required Vulkan
effects capabilities and a path for the requested initial outputs. Prefer direct
presentation for each output and try copy where direct fails. Exhaust usable
hardware candidates before considering Lavapipe. An explicit device restriction
that leaves no usable candidate produces an error rather than being ignored.

Track `probing`, `direct`, `copy`, `recovering`, and `unavailable`, with separate
prepared and committed state. Key capability results by renderer generation,
output lifetime, backend, mode, format/modifier, color encoding, and sync method.
Invalidate affected results on relevant configuration or device changes. Do not
retry a known unsupported direct combination on every frame.

Probe real resources: allocate buffers, import or bind them, render a known
pattern, complete synchronization, and test the intended output state. Confirm
the choice with the first real output commit and presentation feedback where
available; a test-only commit is insufficient. Release every failed candidate.

Classify failures before choosing the next action. Buffer incompatibility can
select copy; a paused session waits for resume; transient commit failures use
bounded retries; device loss enters renderer recovery. Invalid modes and output
disconnection must not be misreported as Vulkan absence.

Expose renderer/device identity, hardware or software rendering, per-output
presentation path, probe stage, and fallback reason in logs and output status.
Use stable error categories for no usable Vulkan, required effects unavailable,
and no usable presentation path. Neither `WLR_RENDERER=gles2` nor `pixman` may
bypass the production Vulkan requirement.

Acceptance: policy tests prove ordering, mixed direct/copy outputs, failure
classification, invalidation, and terminal startup errors.

**3. Implement the copy boundary in private wlroots**

Extend the versioned private API and patch series under
`compositor/patches/wlroots/`. Separate render-target allocation from display
buffer allocation. Review Vulkan renderer, allocator, scene-output, output
swapchain-manager, and DRM/nested backend assumptions against the pinned source.
Keep one implementation shared by normal frames and modeset transactions.

The rendering stage produces a fully composed frame with effects and the
required color conversion. The presentation stage either submits that buffer
directly or transfers its pixels into a separately allocated buffer accepted by
the output. Define the final encoding explicitly so the copy does not apply
tone mapping, output warming, or transfer functions twice.

As a future optimization, try a GPU transfer when the display allocation supports
Vulkan import and transfer usage even if it cannot be a color attachment. The
implemented fallback uses completed Vulkan readback into bounded staging storage followed
by a stride-aware CPU copy into a writable display buffer. Probe backend support
for that destination, such as a DRM dumb buffer or a nested SHM buffer; neither
is universally available. CPU pixel copying does not introduce another scene
renderer. Return an unsupported-path error when no destination works.

Specify acquire, render-complete, copy-complete, display release, and buffer reuse
ownership explicitly. Signal output readiness only after the last write. Keep
source and destination references until their respective consumers finish;
never forward the original render fence as proof that a later copy completed.
Handle row pitch, modifiers, image layout, cache visibility, and non-coherent
memory correctly. The accepted failure path waits synchronously for the submitted
work with a bounded timeout. Event-loop-driven asynchronous completion is a future
optimization, not a prerequisite for automatic selection.

Start with full-frame copies and full damage after allocation/path changes.
Reuse wlroots damage tracking and add partial copies only after validating
buffer-age and destination-content history. Record copy latency, bytes moved,
queue depth, and dropped frames so software or readback costs are visible.

Acceptance: forced allocation/import/commit failures select or reject copy
correctly; reuse stress and Vulkan validation find no early release, stale
pixels, unsignaled waits, or resource leaks.

**4. Integrate output lifecycle and recovery**

Route frame commits, output-manager swapchain preparation, grouped commits,
preview/revert, and retry handling through the new policy. A direct-path failure
gets a bounded retry using a newly built copied frame. Apply new presentation
state only after commit success; preserve the previous usable configuration on
failure. Handle backend transactions that partially apply before reporting an
error using the existing reconciliation path.

While copy is required, hold the composition lock and prevent direct scanout,
overlay promotion, and incompatible hardware color offload on that output.
Start with software cursors on copied outputs. Add hardware cursor support only
after proving its independent allocation/import/sync path, including capture.
Release these restrictions only when a replacement path has committed.

On resize, scale/transform changes, hotplug, power changes, or session resume,
revalidate the affected path and rebuild buffers as needed. Retire old resources
after all users release them. A failed hotplug output must not force working
outputs onto a different renderer; keep it unavailable with a reason. Startup
with connected requested outputs but no working presentation path fails. Preserve
intentional headless operation and ordinary temporary disconnection semantics.

Audit legacy screencopy, ext image capture, portal capture, toplevel capture, and
mirroring for the new buffer split. Advertise formats clients can actually use;
preserve pixel encoding, damage, cursor inclusion, and presentation timestamps.
Do not report a rendered-but-uncommitted frame as displayed. Preserve lock-screen
blanking and output-warming commit guards across path changes.

Extend `Server.gpuResetRecover` to invalidate all presentation generations and
recreate rendering, copy resources, effects, mirror/capture state, and relevant
DMA-BUF/sync feedback. Audit stale globals and imported client resources when
device capabilities change. Recovery must finish successfully or terminate the
session after bounded attempts; the current log-and-wait-for-another-reset behavior
is insufficient. Never recover by switching to GLES2 or Pixman.

Acceptance: mixed-output resize/hotplug, failed modesets, capture, cursor motion,
lock/unlock, device loss, and teardown pass without hanging another output or
reusing resources from the previous renderer.

**5. Add and qualify software Vulkan**

Implement explicit Lavapipe device discovery and selection in private wlroots.
Remove assumptions that every Vulkan renderer has a render node, can export
displayable DMA-BUFs, or shares its allocator with the display backend. Require
only the external-memory and synchronization capabilities actually used by the
selected path; keep the Vulkan capabilities needed for effects mandatory.

Provide Vulkan render targets and host-readable transfer storage for the software
device, then reuse the copy presentation boundary. Audit `Server.zig` client GPU
pinning, Linux DMA-BUF feedback, syncobj advertisement, SHM import, and capture
allocation when there is no renderer DRM FD. Unsupported buffer types must not
be advertised or accidentally pinned to an unrelated GPU.

Run the full effects scene on Lavapipe and measure latency, CPU use, and memory
at representative resolutions. The synchronous SDR implementation is enabled
automatically when hardware candidates are exhausted; VM qualification and
performance characterization remain separate work. A missing required effects
feature makes that Vulkan candidate unusable rather than silently
starting an effects-free compatibility session.

Acceptance: an unaccelerated guest with usable Lavapipe renders and presents
correctly; missing or inadequate Vulkan exits nonzero and releases startup
resources. A software session is identified explicitly in diagnostics.

**6. Resolve guest Mesa device selection and interoperability**

Maintain guest Mesa fixes as a separate patch series against a pinned Mesa
revision. Replace the prototype's Zink engine-name exception with correct device
identification and narrowly scoped capability/workaround handling that retains
the Venus presentation workarounds still required by the tested stack.

Reduce the recorded modifier, memory-allocation, and synchronization errors to
independent reproducers. Verify image usage and modifier negotiation, external
memory allocation/import/export, memory types and coherency, and acquire/release
fences with native Vulkan, Zink/EGL, Wayland, and Xwayland clients. Require the
fixes to pass without identity spoofing or suppressed validation errors.

Detect working Venus through device creation and representative rendering and
buffer interoperability checks. Finding `virtio_gpu` is not sufficient to force
Zink or claim hardware acceleration. Keep compositor Vulkan selection distinct
from the GL driver selected for clients.

The host must expose a working accelerated device. Mesa documents host-driver
requirements, guest virtio features, and implementation-dependent memory behavior
that limit portability even when advertised requirements are met. Record the
exact supported host/guest combinations against the
[Mesa Venus requirements](https://docs.mesa3d.org/drivers/venus.html#requirements).
Investigate host EGL startup failures in the host hypervisor/display stack; guest
copy presentation cannot fix failure to initialize that stack.

Acceptance: the original client reproducers and full desktop/installer flow pass
on matched components, with host and guest failures reported separately.

**7. Package matched components and preserve deployment policy**

Update the pinned build script, private API version checks, distribution staging,
and all maintained package consumers, including Arch stable/Git, Devario, and
`nix/core.nix`. Keep Aqueous paired with its private wlroots ABI. Package Mesa
changes through the guest distribution's versioned recipes with tested dependency
constraints, patch hashes, and a recorded host/guest compatibility matrix.

Do not replace system libraries from an ISO-specific launcher. Include the Vulkan
loader and the appropriate ICD packages in supported configurations; install
Lavapipe where software Vulkan support is promised. Test upgrades and rollback
using the same package artifacts shipped to users.

Keep the earlier live policy intact: automatic VM environment workarounds apply
only when both live-ISO and VM detection succeed. Installed VMs use the matched
packages and their separately documented supported configuration. The compositor's
capability-based presentation selection is general; ISO-specific environment
mutation is not. Test live VM, live bare metal, installed VM, and installed bare
metal independently. Greeter/session launchers must propagate failure without
starting another renderer or entering an endless restart loop.

Acceptance: clean package installs reproduce the tested behavior, resolve the
intended private wlroots/Mesa components, and preserve deployment boundaries.

**8. Validation and automatic rollout**

| Coverage | Required result |
| --- | --- |
| AMD, Intel, NVIDIA on supported native configurations | Direct rendering remains correct; forced copy preserves effects and capture |
| Each host GPU vendor with crosvm and QEMU | Record accelerated Venus results with exact host/guest versions; classify unsupported combinations explicitly |
| Acceleration disabled or unusable, Lavapipe available | Software Vulkan copy works after qualification and is reported as software |
| Vulkan absent, device creation fails, required effects unavailable | Clear nonzero startup failure; no GLES2/Pixman session |
| Vulkan renders but no display allocation/copy/commit works | Distinct presentation failure; cleanup and bounded recovery |
| Direct and copied outputs together | Independent path decisions through resize, rotation, scale, mirror, hotplug, and power changes |
| Injected allocation, import, fence, commit, and device-loss failures | Bounded fallback, correct rollback, no stale buffer use or deadlock |
| Greeter to desktop to installer, capture, lock, logout, relogin | Complete lifecycle works with shipped packages and retains the live/installed policy |

Extend the existing Vulkan context/effects/render-seam and sync fixtures, output
retry/preview, mirroring, and capture tests. Add selection and copy fixtures to
`compositor/scripts/` and wire them into the build and CI workflow. Require the
actual Vulkan production build for renderer/copy acceptance; diagnostic Pixman
tests prove policy behavior only. Headless tests cannot qualify physical scanout
or host EGL. Record skips separately from passes and retain pixel comparisons,
Vulkan validation output, device identities, package versions, and performance
measurements with each qualification run.

Automatic hardware/copy/software selection is now enabled in normal builds with
the accepted synchronous SDR limits. Continue qualification of Mesa clients and
the vendor/hypervisor matrix before claiming those configurations are supported.
Matched Mesa packages and installed-VM configuration remain separate delivery
work. Every path still requires usable Vulkan and the required effects features.
