# GPU synchronization descriptor ownership investigation

Current status (2026-10-29): patch 0038 treats Vulkan device loss as resource
completion and schedules renderer replacement. Recovery waits retry timeouts
for ten one-second slices. Unresolved GPU work still cannot return failure to
scene submission and release client buffers early. Presentation copies share
the bounded wait and reject undefined pixels after device loss. Qualification
and the retained safety contract are recorded in the final section.

Previous status (2026-10-27): consolidated patch 0037 defers composed-buffer release registration
until render submission, fixing the pre-submission recovery ordering identified
in the [ndri crash report](https://termbin.com/ndri). It adds resource/error
diagnostics and preserves release dependencies from other frames and outputs.
Local build, fault-injection, sanitizer and software-rendering checks pass;
the affected Intel/NVIDIA 580 configuration still requires hardware validation.
This is not a confirmed fix for an underlying driver leak. Details follow in
the final section.

Previous status (2026-10-26): the affected user reports that 1.0.10 works after
raising Aqueous's soft FD limit to its inherited hard limit, matching labwc.
Both parts of patch 0020 are restored at the user's request; the higher
FD limit remains. This is a successful user report for 1.0.10, not a measurement
of bounded FD usage or hardware qualification of the restored patches. The
sections below retain the investigation and rollback history.

Two resource leaks are reproduced and fixed in the private wlroots dependency:
DRM atomic preparation can lose an exported input fence on a later preparation
failure, and release-merger waiter initialization can leak its heap record.
Neither is established as the cause of the reported NVIDIA incident. No
unbounded FD growth was reproduced in successful Vulkan frames or completed
release merges with the controlled GPU mocks. The initial sandbox did not expose
the GPU; subsequent private NVIDIA headless validation is recorded below.
Physical KMS, cross-GPU, and the reported GTX 1080 Ti/580 configuration remain
unqualified.

The investigation started at Aqueous commit
`b9befec0e4bb2e7a8542878875f31f29bd2ba54c`, with a clean working tree. The local
host uses Shelly; `shelly --help` was checked, and no packages were installed.
The archive `compositor/.deps/downloads/wlroots-0.20.2.tar.gz` was verified against
SHA-256 `972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343`.
All 34 original patches were applied in the exact order in
`compositor/scripts/build-wlroots-render-hook.sh` to `/tmp/aqueous-sync-audit`.
The final dependency build reconstructed the archive again and applied the
original series plus patches 0035 and 0036. The new patches are also listed in
`nix/core.nix`; no system wlroots installation was changed.

The supplied incident evidence establishes FD exhaustion: 4,083 descriptors,
3,947 of them `anon_inode:sync_file`, against Aqueous's explicit soft limit of
4,096 in `compositor/aqueous/process.zig`. The supplied logs include failed
Vulkan imports, syncobj exports, fence merges, eventfd and SHM allocation,
completion-fence publication, and repeated failures on both outputs. The
reported configuration was Aqueous 1.0.6 on Devario, NVIDIA 580.178.04 on a GTX
1080 Ti driving DVI-D-1 and HDMI-A-1, alongside an Intel UHD 770. The later
Intel-rendering crash has no confirming renderer log or demonstrated identical
cause. The journal, compositor log and FD-list URLs supplied with the report
were inaccessible during this investigation, so their complete event ordering
could not be independently inspected. In particular, `ERROR_INVALID_EXTERNAL_HANDLE`
is not assumed to have been caused by exhaustion, and EGL-specific NVIDIA
reports are not evidence of this Vulkan defect.

The exact FD defect is in `backend/drm/atomic.c:drm_atomic_connector_prepare`.
Before patch 0035, it exported a fence into local `in_fence_fd`, then validated
VRR and created HDR metadata, and only afterward assigned the descriptor to
`state->primary_in_fence_fd`. If HDR metadata allocation failed, rollback saw
`-1` and could not close the exported descriptor. This happens before KMS
submission, so the FD is lost ownership rather than pending GPU work. The VRR
rejection branch has the same local defect, but ordinary public DRM preparation
rejects unsupported VRR earlier. The regression therefore uses the reachable
HDR allocation failure. Intermediate mode, gamma and damage blobs had the same
late ownership-publication problem.

Patch 0035 records each allocation directly in connector state as it succeeds.
Existing apply/rollback paths then dispose of it, including failure partway
through preparation of a second output. Both atomic and libliftoff callers use
these paths. It changes neither Vulkan's consuming-import contract nor buffer
completion timing. The original production functions fail the new test's
`fd_count() == baseline` assertion on the first injected HDR allocation failure.
An automated negative control restores the lost-local-FD behavior and must fail
that same assertion. The incident evidence does not establish HDR allocation
failures, so this result cannot explain all 3,947 retained fences by itself.

Patch 0036 fixes a separate heap leak in
`render/drm_syncobj_merger.c:wlr_drm_syncobj_merger_add`: the allocated
`export_waiter` was not freed when waiter initialization failed. Before the
fix, LeakSanitizer reported 48,000 bytes in 1,000 allocations on this 64-bit host.
Afterward it passes; a negative control removes the free and detects the leak.
This record is allocated before acquiring the merger/timeline references; freeing
it on initialization failure releases no pending GPU dependency. This is a
locally established heap leak, not proof of heap leakage in the remote incident.

| Audited path | Ownership and result |
| --- | --- |
| Vulkan implicit/explicit acquisition | DMA-BUF/timeline exports are caller-owned until successful `vkImportSemaphoreFdKHR`, which consumes ownership. The patched pass clears transferred array entries; partial export/import failures close only unconsumed FDs. Tests exercise each plane, repeated slot reuse and recovery. |
| Vulkan submission and publication | Binary-semaphore export returns a caller-owned FD, closed after timeline/DMA-BUF publication on success or failure. The `-1` already-signalled sentinel is handled separately. Cancellation destroys imported temporary payloads; publication recovery waits before disposing of submitted work. Patch 0038 recognizes device loss as resource completion and schedules replacement; exhausted waits and unknown submitted work retain the fatal safety policy. |
| Semaphore reuse and renderer destruction | Wait semaphores are bounded by command-slot high-water usage; successful imports belong to the Vulkan implementation. Resource retirement requires completion, and renderer destruction waits for idle/device loss before destroying semaphores and quarantined passes. Driver-internal FD retention cannot be qualified by a mock that implements the ownership contract. |
| DRM atomic and libliftoff | Both commit implementations apply or roll back each connector, including TEST_ONLY and partial preparation failure. Patch 0035 fixes the exported-FD ownership gap. Tests run the real atomic orchestration/preparation/cleanup functions with mocked KMS, two outputs, rejected commits and disable/re-enable. Libliftoff-specific property transitions are covered by the existing overlay test; physical assignments are not simulated. |
| Hardware layers and fallback | Pending layer fences are closed on replacement, commit, rollback and addon destruction. Queued/current release points move with scanout buffers and are released on replacement/disable. If higher-level preparation exits before `drm_commit`, a pending fence can remain owned by a layer until replacement/destruction; that is bounded per layer, not a lost descriptor. Aqueous finishes output states and overlay candidates on composition fallback. |
| Surface replacement, detach and release merging | Patch 0012 preserves bufferless state and drops the old merger on actual replacement/detach. A live merger normally retains one merged FD, while an unavailable source point retains an eventfd waiter and references. Two-output replacement/detach tests complete callbacks and return both FD and timeline-ref counts to baseline. Unfinished dependencies legitimately keep those records alive. |
| Cross-GPU and mirrors | `drm_surface_blit` passes the source wait point into the render pass and publishes the copy timeline; connector state owns its timeline reference until finish. OutputMirror bounds in-flight copies and preserves orphaned jobs until their waiter callback. Presentation-copy tests use the real software Vulkan implementation; no physical DMA-BUF transfer between Intel and NVIDIA was exercised. |
| Aqueous recovery/output lifecycle | Output states use deferred finish; fallback rebuilds state; renderer recovery reinitializes outputs and destroys the old renderer. Copy reset and headless hotplug are integration-tested. Mock teardown occurs only after simulated completion; it does not qualify physical device reset. |

One additional synchronization concern was left outside those resource-leak fixes
and is addressed in the error-handling implementation below:
`merger_add_exportable` did not propagate export/merge errors and could replace its
previous fence with `-1`; final unref could then signal an incomplete release.
Final timeline import errors were also ignored. The initial fault tests verified FD
cleanup for those branches, **not safe release semantics**. Fixing that required
a failure policy for deferred dependencies and their callers; simply signalling,
closing every fence, or dropping live buffer references would be unsafe. No
successful-path unbounded FD leak was established there.

The new `compositor/scripts/test-drm-sync.py` follows the existing Vulkan test's
method: extract complete production functions from the reconstructed source,
compile against its actual structures, and control only GPU/KMS operations.
The mocks allocate real OS descriptors (`/dev/null` for synthetic fences and
`eventfd` for pending waiters); they do not create real kernel sync_file fences.
Each run uses `RLIMIT_NOFILE=64`, and this host's baseline is three open FDs.

| Validation | Result |
| --- | --- |
| `python3 compositor/scripts/test-drm-sync.py /tmp/aqueous-sync-before /tmp/aqueous-sync-prefix --no-negative-controls` | Expected failure on the original production source: `fd_count() == baseline` after HDR allocation fails. The before tree is the audited tree with patches 0035 and 0036 reversed. |
| `python3 compositor/scripts/test-vulkan-sync.py /tmp/aqueous-sync-audit /tmp/aqueous-sync-prefix` | Plain and ASan/UBSan passed: 6,000 frames, two output buffers/command slots, repeated import/export/publication faults and recovery, baseline after every frame and teardown. Five existing synchronization negative controls rejected. |
| `python3 compositor/scripts/test-drm-sync.py /tmp/aqueous-sync-audit /tmp/aqueous-sync-prefix` | Plain and ASan/UBSan/LeakSanitizer passed: 6,000 two-output atomic transactions, 2,000 disable/re-enable transactions, 9,000 successful fence exports, 6,000 release-merger replacement/detach cycles and 1,000 waiter-init failures. Baseline FD counts, zero remaining blobs after teardown, balanced timeline references. Both leak negative controls rejected. |
| `bash compositor/scripts/build-wlroots-render-hook.sh /tmp/aqueous-sync-prefix` | Full clean reconstruction, Meson compile/install and all scripted dependency checks passed, including overlay, color pipeline, synchronization and Vulkan selection. |
| `PKG_CONFIG_PATH=/tmp/aqueous-sync-prefix/lib/pkgconfig LD_LIBRARY_PATH=/tmp/aqueous-sync-prefix/lib ZIG_GLOBAL_CACHE_DIR=/tmp/aqueous-sync-zig-cache zig build -Doptimize=Debug -Dxwayland -Dllvm --prefix /tmp/aqueous-sync-compositor` from `compositor/` | Aqueous and aqueousctl built successfully against the new private dependency. |
| Same environment, `zig build test -Dxwayland -Dllvm --summary all` | 122/122 build steps and 586/586 tests passed. |
| `bash compositor/scripts/test-vulkan-presentation.sh /tmp/aqueous-sync-prefix` | Real software/headless Vulkan passed allocation fallback, renderer recreation, output isolation/hotplug, pixels, reuse, resize, capture import, commit and reset. No `/dev/dri` exists on this host. |
| Instrumented private wlroots build and same presentation test | Passed with tracing enabled. Tracing's accounting was separately checked for consuming Vulkan imports and FD-number reuse. |
| `git diff --check` | Passed. |

Initial sandboxed runs blocked LeakSanitizer's process inspection and a local
Wayland test socket. Those tests were rerun successfully outside the sandbox;
the failures were not treated as product regressions. No remote-user tests,
commands or logs were requested.

`compositor/scripts/trace-sync-fds.py` provides local diagnostics for the unresolved
incident. `--instrument PRIVATE_PATCHED_SOURCE` inserts optional logging only into
a private reconstructed source tree and saves the exact diagnostic patch there.
Build that tree with the same Meson options as the dependency builder; run its
library with `AQUEOUS_TRACE_SYNC_FDS=1`. The logger preserves errno, never closes
anything on its own, and records consuming Vulkan imports as ownership transfers.
`--report LOG` lists still-unmatched exports by allocation site and identifies FD
numbers reused without an observed release. `--snapshot LOCAL_PID` reports
sync_file/other descriptor counts separately from RSS/data-memory measurements.
An unmatched export at an intermediate snapshot can be legitimate pending work;
compare after completion/teardown. Successful Vulkan transfers no longer belong
to wlroots even if the driver retains the underlying FD. The tracer cannot see
allocations/duplicates internal to the proprietary driver or infer GPU completion,
and its logging can perturb timing. It is not enabled in shipped builds.

## Follow-up: Pearl exits after opening Ghostty on 1.0.7

The subsequent [Pearl journal](https://termbin.com/u1086) and
[compositor log](https://termbin.com/5ox0t) were retrieved successfully.
The compositor identifies itself as Aqueous 1.0.7 and selects the GTX 1080 Ti
with NVIDIA 580.178.04. Both connected outputs belong to the NVIDIA device;
an Intel UHD 770 is also present. Ghostty reports Mesa EGL, but this does not
identify its actual rendering device or establish a cross-GPU failure.

The first rendering failure in the compositor log, at line 178, is
`drmSyncobjExportSyncFile failed: Too many open files`. Fence merging,
eventfd allocation, Vulkan semaphore imports and SHM allocation subsequently
fail. The invalid-external-handle errors occur **after** descriptor exhaustion
in this log. There is no preceding device-lost or GPU-reset report in the
supplied compositor log. This confirms exhaustion in the compositor despite
the earlier fixes; it does not identify the allocation retaining descriptors.
The previously supplied count of 3,947 sync_file descriptors is from the older
incident, not a new snapshot from this session.

Pearl reports a lost Vulkan surface and an invalid-argument Wayland dispatch
or flush failure, then exits. Subsequent Pearl instances also fail while the
same compositor remains alive. This is consistent with the compositor being
unable to serve its clients after exhausting descriptors. Changing Pearl to
the GL renderer was already tried without fixing the user's failure.

Additional isolated tests used current Pearl and Aqueous with two headless
outputs and real NVIDIA rendering, outside the device-restricted sandbox.
The development GPU is an RTX 5090 with driver 615.78.08, not the affected
1080 Ti/580 combination. Ten Ghostty launch/close cycles passed with each of
Pearl's Cairo and Vulkan renderers. Ten further Vulkan cycles disabling and
re-enabling the headless outputs also passed. During 90 seconds of animated
Ghostty output, Aqueous held 105–106 descriptors after startup, including
2–3 sync_file descriptors, without progressive growth. These tests do not
exercise physical KMS scanout or Intel/NVIDIA transfers. They neither reproduce
the reported failure nor validate a fix for it.

The next useful capture is descriptor creation, duplication and close activity
in the affected compositor **before** it exhausts its limit. A short `strace`
with descriptor decoding and call stacks can complement the private-library
tracer above by exposing driver syscalls. Capture all compositor threads and
include ioctl, close/close_range, dup/dup2/dup3, fcntl and recvmsg. Start from a
fresh session, open or interact with Ghostty during the capture, and keep the
original trace: filtering only error lines discards the ownership evidence.
Tracing can slow rendering and cannot itself establish whether a retained
descriptor is still legitimately in use. No further leak fix is claimed from
these results.

The user subsequently reported that failure can occur almost immediately,
before an interactive trace can be attached. For this UWSM-managed session,
capture from startup instead: log into a text console, stop the old graphical
session with `uwsm stop`, then launch the usual session wrapper under strace:

```sh
uwsm start -D Aqueous -e -- /usr/bin/strace -f -yy -k \
  -e trace=ioctl,close,close_range,dup,dup2,dup3,fcntl,recvmsg \
  -o "$HOME/aqueous-fds.trace" /usr/bin/aqueous-wm
```

Run as the normal user. This traces the compositor from process creation;
the session wrapper still performs its usual environment setup and UWSM
finalization. After failure, return to the text console and use `uwsm stop`
to end the capture. The trace lives in the home directory and survives session
shutdown. UWSM's local help and dry-run argument parsing accept this command;
an actual physical session launch was not tested on the development desktop.

The next [trace upload](https://termbin.com/v6pws) contains exactly 1,048,575
bytes and ends partway through a stack frame. It begins during Wayland request
processing rather than at process startup. The available excerpt contains no
EMFILE failure; the sync_file descriptors named in it range from 123 to 157.
After reconstructing interrupted/resumed syscalls, all 75 successful sync_file
`dup3` destinations in this excerpt have subsequent successful closes. This
checks only those duplications, not all fence allocations or the omitted part
of the trace. NVIDIA driver stacks also appear under Vulkan submission; the
`libnvidia-eglcore` library name alone does not establish an EGL rendering path.
The complete original trace, compressed for transfer, is needed before drawing
an ownership conclusion. No additional reproduction is required just to recover
the portion omitted by this upload.

## Local archive: retained Vulkan-import duplicates

The subsequently supplied `aqueous-fds.trace.gz` passes gzip integrity checking:
230,915 compressed bytes, 6,466,441 uncompressed bytes and 102,953 lines.
Its SHA-256 is
`542367187d51257d9aa8940cc7c5607638b08de9d072e251df8f8796eb7d24ce`.
It starts with the same request as the truncated paste and continues farther.
It still ends during rendering, with unfinished syscalls, rather than recording
EMFILE, a compositor exit, or resource teardown. The archive is valid; that does
not mean the capture includes the eventual failure.

Unlike the first MiB, this longer interval shows persistent duplicate fence
descriptors in Aqueous PID 1388. In particular, FD 181 is created by `dup3` at
uncompressed line 38,390, and FD 232 at line 40,631. Neither has a subsequent
close or reuse in the remaining captured calls. Sixteen such destinations
accumulate before the final incomplete render submission:
181, 232, 258, 137, 142, 158, 234, 190, 271, 384, 134, 151, 143, 406, 185, 416.
Their allocation stacks all share:

```text
libc dup3
libnvidia-eglcore.so.580.178.04 +0xa31c90, +0xa31f92, +0xd83419, +0xd80de5
libwlroots-0.20.so render_pass_wait_sync_file.isra.0 +0x8c
libwlroots-0.20.so render_pass_submit +0x1e1
libwlroots-0.20.so wlr_scene_output_build_state
aqueous Output.buildSceneStateInternal
```

For FD 181, the driver closes the original imported FD 158 immediately after
duplicating it. The evidence therefore identifies driver-created duplicates in
the Vulkan semaphore-import path, rather than an unclosed original descriptor
that wlroots is free to close. Successful imports transfer FD ownership to the
Vulkan implementation per the
[Vulkan API contract](https://docs.vulkan.org/refpages/latest/refpages/source/vkImportSemaphoreFdKHR.html).
Adding a close after a successful import would violate that contract.

This is a specific retention lead, not yet proof of an unbounded driver leak.
The syscall trace does not expose semaphore identities or GPU completion;
the renderer pools wait semaphores across up to 64 command-buffer slots.
Pending work or pooled payloads must be distinguished from unreachable driver
resources. The final incomplete submission also has descriptors without a
recorded close and is excluded from the sixteen earlier candidates. High FD
numbers alone are not a count of live fence descriptors. No production behavior
was changed based on this trace.

## Comparison with stock wlroots 0.20.2

Comparing complete functions against the pinned upstream archive establishes
that `render_pass_wait_sync_file` is unchanged. Its temporary sync_file import
and command-buffer-owned wait-semaphore pool are upstream behavior. The pool's
64-slot limit is also upstream. The trace therefore does not identify semaphore
reuse as an Aqueous-introduced change.

Two relevant differences are established in the source. First, the packaged
dependency is compiled with `-Drenderers=vulkan`, and
`render/RendererSelection.zig` forces Vulkan for effects builds. Stock wlroots
autocreation tries GLES2 first when that renderer is available. A working stock
compositor is only a Vulkan comparison if its active renderer is verified.

Second, patch 0020 (introduced in commit `970aacb`) changes successful-frame
synchronization as well as error recovery. It moves producer/render-buffer
semaphore waits from the later render submission to the earlier staging
submission that performs ownership/layout transitions. It also explicitly sets
ALL_COMMANDS signal stage masks and collects imports earlier in pass submission.
The import helper and normal semaphore reuse remain unchanged. This is a
specific candidate for controlled comparison when upstream Vulkan works on the
same GPU, not a demonstrated introducing commit. Reverting its synchronization
safeguards in production is not justified by the trace.

Other differences include custom effects draw hooks and GPU selection policy
(patches 0001 and 0031). The failure log selects NVIDIA on a dual-GPU machine;
a baseline comparison must use that same device. The copy fallback in patch
0030 is first activated after exhaustion in the supplied compositor log, so
that observed fallback is not the initial failure there.

## Re-evaluation of removing patch 0020

A clean private reconstruction from the checksum-verified 0.20.2 archive,
applying the builder's patch order but omitting 0020, fails at patch 0030:
two `render/vulkan/pass.c` hunks are rejected. This verifies the dependency
problem rather than merely predicting it. Patch 0030's copy code also accesses
`completion_proven` and calls recovery helpers introduced by 0020. No installed
library or repository patch was changed for this experiment.

The upstream code really does continue after some required fence-acquisition
failures, and logs a completion-publication failure before returning success.
These establish error-handling gaps. They do not establish that the entire
0020 recovery policy is the only correct solution, or that those branches
caused the reported exhaustion.

Normal-frame changes should be considered separately. Upstream's semaphore
signal structures leave `stageMask` at zero, while 0020 sets ALL_COMMANDS.
Under the [vkQueueSubmit2 scope rules](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueueSubmit2.html),
zero does not provide a rendering-completion scope. A semaphore used as a
completion marker needs an appropriate signal scope. Likewise, a wait in the
later render batch does not reach backwards to protect earlier ownership/layout
operations. That gives the patch's ordering changes a specification-based
correctness rationale independent of its tests. It does not prove this exact
batching arrangement is required, or exclude a regression in its implementation.

The original mock tests enforced the selected submission arrangement and closed imported
FDs immediately. They could not independently prove that the arrangement is needed
on hardware or that NVIDIA does not retain internal duplicate descriptors.
GPU hangs/resets, corruption and lost desktop sessions are plausible consequences
of broken synchronization, not outcomes reproduced by removing this patch here.
A coherent diagnostic rollback remains reasonable; shipping a blanket removal
or calling 0020 the confirmed cause is not supported by the available evidence.

## Error-handling implementation (2026-10-25)

The initial implementation split the failure/resource lifetime policy into
`0020-vulkan-sync-failure-handling.patch` and the normal-path acquire-wait
placement and ALL_COMMANDS signal scopes into
`0020-vulkan-submit-dependencies.patch`. Both were initially applied, preserving
the combined submission arrangement. The latter has since been removed; see
the submission rollback below. Patch 0030 uses the explicit
submission/completion state and still depends on the retained error handling.

| Outcome | Error handling |
| --- | --- |
| Before pass submission | Preserve independent uploads, wait only for actual earlier submissions, then cancel and dispose of unconsumed imports. Required acquisition failure never submits a partially synchronized pass. |
| Rejected submission | Only host/device OOM is classified as rejection with untouched resources, as required by the [Vulkan submit contract](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueueSubmit2.html). Once stage recording includes ownership barriers, retain resources and request renderer replacement; never wait for its unsubmitted timeline point. Independent upload rejection also prevents renderer reuse. |
| Submission with unknown acceptance | Device loss and unexpected submit errors stop the process before protocol dispatch, buffer reuse, or completion callbacks. This extends the existing terminal policy to queue errors that cannot prove cancellation. |
| Submitted, publication failed | Wait up to one second for this pass's submitted timeline point, or use completion already established by the presentation copy. Repair release publication only after completion. The frame still returns failure. |
| Completion cannot be established | Preserve the terminal policy. Returning capture failure can let a client immediately reuse an unfenced buffer; merely retaining a wlroots buffer lock does not prevent that reuse. |

Patch `0037-syncobj-merger-error-handling.patch` separately fixes release merging.
Export failure cannot replace the old fence with `-1`; merge failure closes only
the new temporary export and preserves the old aggregate. A failed dependency
operation gets one bounded wait for **completion**, not availability. Only a
completed dependency may be omitted. Failure poisons the merger, propagates
through the public state helper to scene sampling, and stops unsafe protocol
dispatch. Deferred failures have the same terminal outcome even if the owning
surface still retains the merger.

Final destination import failure polls the retained aggregate for up to one
second before attempting a direct signal. Poll timeout/error or failed signal
terminates explicitly. EINTR retries share the original deadline. Healthy merges
remain asynchronous; no new healthy-frame CPU wait or semaphore-pool change is
introduced. These policies deliberately favor a terminal session error over an
early buffer release or a silently unresolved release promise.

The regression fixtures track driver-owned duplicates of imported FDs until
the GPU consumes their waits, while checking application ownership independently
of reused FD numbers. The initial fixtures checked recorded ownership barriers
against preceding waits; the rollback replaces that assertion with upstream
submission compatibility checks. Faults cover every acquisition
plane, semaphore creation, independent uploads, OOM versus unknown submission,
partial publication, exact submitted-point recovery, copy completion, deferred
merger failures, waiter allocation/setup, publication, and bounded timeout/EINTR.
Assertions prohibit early callbacks, release signals, unsafe semaphore reuse,
and a successful result for a failed frame. Negative controls deliberately
restore these defects and must be rejected.

Validation of the initial split, before the rollback below, used private builds
under `/tmp/aqueous-sync-fix`; no installed desktop or system wlroots library was
replaced:

- All 38 patches reconstruct the tested source; all 94 files touched by the
  series match the independently reconstructed tree. Both 0020 intermediate
  sources compile. The split patches, 0030, and 0037 apply without context fuzz.
- The complete dependency builder, its checks, and both synchronization suites
  pass, including ASan/UBSan/LeakSanitizer and deliberate regression controls.
  Each stress run uses a 64-FD limit: 6,000 Vulkan frames, 6,000 two-output release
  merges, 6,000 atomic transactions, and 2,000 disable/re-enable transactions.
- Aqueous builds against the private library; `zig build test -Dxwayland -Dllvm`
  passes **592/592 tests, 124/124 steps**.
- Real software Vulkan presentation tests pass allocation fallback, renderer
  recreation, output isolation/hotplug, pixels, reuse, resize, capture and reset.
- Real NVIDIA synthetic capture tests pass native/SDR pixels, DMA-BUF scene
  destinations, repeated capture, failure events and metadata lifetimes. Optional
  output format `0x30335258` is unsupported and skipped by the fixture.
- On the local RTX 5090, Pearl using Vulkan stays alive across ten Ghostty
  open/close cycles and exits cleanly. Ten further cycles also disable/re-enable
  both headless outputs on each iteration; Pearl stays alive and exits cleanly.
  This is headless GPU coverage; it does not qualify physical scanout or the
  remote GTX 1080 Ti and 580.178.04 driver.
- During 90 seconds of continuous Ghostty redraws, Aqueous stabilizes at 106 FDs
  after warmup, including three sync_file FDs. Pearl and Ghostty remain alive;
  the session exits cleanly. Driver-internal retention on the remote driver is
  still unqualified by this local observation.

These changes fix demonstrated error-handling defects. They do not establish
the cause of the remote driver's retained sync_file duplicates or constitute a
confirmed fix for the reported exhaustion.

## Submission rollback (2026-10-25)

The affected user's unpatched wlroots 0.20.2 works with Vulkan forced. On that
evidence, remove the suspected normal-submission changes from the build:

- Delete `0020-vulkan-submit-dependencies.patch` and its shell/Nix entries.
- Restore upstream acquire waits on the render batch, the separate prior-upload
  timeline wait on staging, and the original zero-valued signal stage masks.
- Keep `0020-vulkan-sync-failure-handling.patch`, patch 0030's completion-state
  integration, and the independent DRM release-merger fixes.

This is a focused rollback, not a fully stock Vulkan renderer. The retained
0020 still changes resource locking, acquisition timing and retirement as part
of its error handling. It does not change the semaphore pool or consuming-import
ownership contract.

The tests retain failure injection, driver-owned FD payloads and resource
lifetime checks. Negative controls now omit render acquisition waits or the
prior-upload wait. The old assertions requiring the removed submission layout
and nonzero signal scopes are gone. The replacement checks preserve the
upstream layout; they do not prove GPU execution-order correctness.

Release `1.0.8` carries the submission rollback and the retained error-handling
fixes directly in the source. Source package recipes target `1.0.8-1`; stable
recipes check out `v1.0.8`, and Git recipes use the current development source.
All Devario packaging backport files, source/checksum entries, and prepare-hook
workarounds have been removed. Publish the release commit as `v1.0.8` before
building the stable packages.

The current private wlroots builder and its checks pass, including
ASan/UBSan/LeakSanitizer, 6,000 Vulkan
frames under a 64-FD limit, and all seven Vulkan regression controls.
Aqueous builds against the rollback and all 592 tests pass. On the local RTX
5090, Pearl using Vulkan survives ten Ghostty open/close cycles and exits
cleanly. During a further 90 seconds of continuous Ghostty redraws, Aqueous
stays at 106 FDs after warmup, including three sync_file FDs; Pearl stays at
161 FDs, including two sync_file FDs. The session exits cleanly. Software Vulkan
presentation fallback, capture, reuse, resize and hotplug tests pass.
These runtime checks used the implementation now included in 1.0.8. Builds and
logs are under `/tmp/aqueous-submit-rollback`.

Release preparation checks are under `/tmp/aqueous-release-1.0.8`. The rebuilt
compositor and configuration helper both report `1.0.8`; the helper's 67 unit
tests and complete backend regression suite pass. All ten source recipes match
Shelly-generated metadata, and the stable Pearl packaging checks pass.

Confirmation of the reported fix still requires reproducing the Ghostty
workflow on the GTX 1080 Ti with driver 580.178.04, checking descriptor growth,
and comparing with the submission override restored.


## Complete 0020 removal (2026-10-26)

The affected machine still exits the session during ordinary application use,
including Firefox. Remove the remaining `0020-vulkan-sync-failure-handling.patch`
from the shell and Nix builds. Vulkan effects and explicit synchronization remain
enabled; this change does not modify their configuration or advertisement.

This restores upstream 0.20.2 acquisition timing, texture-buffer lifetime,
transition bookkeeping, command-buffer reset/retirement and submission error
handling previously changed by 0020. It also removes 0020's renderer-wide failed
state, quarantined passes, bounded recovery and general synchronization aborts.
Upstream's handling of acquisition/publication failures is restored too; the
previous error-recovery guarantees must not be claimed for this build.

Patch 0030 is rebased without the removed submission enum or recovery helpers.
Normal DMA-BUF submission uses upstream release/error behavior. Its separate
CPU-copy path still waits for GPU completion before accessing mapped pixels;
a failed completion wait terminates inside the copy helper, as it did via 0020's
helper before this rollback. A completed copy with failed CPU access returns
failure but still processes its release semaphore. This copy-only check is not
renderer-wide 0020 recovery. Patch 0037 and the other independent patches remain.

The Vulkan synchronization fixture now checks successful explicit/implicit-sync
submissions, upstream wait layout, FD ownership and copy completion. Tests tied
to the removed recovery implementation are retired. Retained negative controls
omit acquisition waits, omit prior-stage waits, or bypass copy completion.

Validation outputs for this change are under `/tmp/aqueous-remove-0020`.
This rollback still requires the same Ghostty/Firefox workload on the affected
GTX 1080/580 machine; local checks cannot confirm that crash is fixed.

Validation completed: the full private wlroots builder and its regression suite
pass, including ASan/UBSan and 6,000 explicit/implicit-sync Vulkan frames with
three rejected negative controls. The real Vulkan presentation test passes
allocation fallback, output isolation, hotplug, pixel checks, reuse, resize,
capture import, commit and reset. Aqueous builds in ReleaseSafe with
`-Dvulkan-effects=true -Dxwayland`; all 592 tests pass. The installed compositor's
private wlroots library is byte-identical to the newly built dependency.

## Restoration after the 1.0.10 FD-limit change (2026-10-26)

The user confirms that 1.0.10 works on the affected setup and requests restoring
the removed patches. Restore `0020-vulkan-sync-failure-handling.patch` from the
1.0.8 source and `0020-vulkan-submit-dependencies.patch` from the saved pre-rollback
patch. Register both, in that order, in the shell and Nix dependency builds.

The first patch restores acquisition-failure cleanup, submission-state tracking,
buffer retention, bounded completion/publication recovery and safe terminal
handling when completion cannot be established. The second restores acquire
waits before staging ownership/layout transitions and ALL_COMMANDS completion
signal scopes. Patch 0030 again uses the submission/completion state and recovery
helpers. Restore the matching failure-injection and submission-dependency tests,
including driver-owned import payloads retained until simulated completion.

The soft FD limit remains equal to the inherited hard limit. Vulkan effects,
explicit synchronization, patch 0037, release versions and checksum policy are
unchanged by this restoration. Private validation artifacts are under
`/tmp/aqueous-restore-0020`; no installed compositor or system library is replaced.

Validation completed:

- Both restored 0020 patches and their 0030 integration apply without context
  fuzz. The Vulkan header, pass, renderer and copy source match the previously
  tested pre-rollback source exactly.
- Shell and Nix now list the same 38 patches in the same order. This also adds
  the existing 0032 empty-damage patch to Nix, where it was missing.
- The complete private wlroots build and regression suite pass, including
  6,000 Vulkan frames under a 64-FD limit, sanitizer checks and all seven
  synchronization negative controls.
- Real software Vulkan presentation passes allocation fallback, output
  isolation, hotplug, pixels, reuse, resize, capture import, commit and reset.
- Aqueous builds in ReleaseSafe with Vulkan effects and Xwayland enabled;
  all 592 tests pass across 124 build steps. The private executable reports
  1.0.10, and the higher FD limit is unchanged.

The sandbox blocked the initial Wayland test client connection; the complete
dependency suite passed when rerun outside the sandbox. These checks do not
replace a run of the restored patches on the affected GTX 1080 Ti/580 setup.

## Scene release registration after submission (2026-10-27)

The `ndri` core summary shows SIGABRT in
`handle_scene_buffer_output_sample`, reached through `scene_entry_render` and
`Output.buildSceneStateInternal`. This matches the original patch 0037's explicit abort when
release-dependency registration fails. The paste lacks the preceding compositor
errors and therefore does not identify the original failing operation or prove
FD exhaustion in this particular crash. NVIDIA 580.178.04 and Intel Vulkan
threads are present; their presence does not establish the active rendering GPU
or attribute the failure to either driver.

Source inspection establishes a recovery ordering problem: composition emits
the sample event before submitting the render pass. If availability checking,
waiter allocation or waiter initialization fails there, the original 0037 waits for the
current frame's completion while the same thread has not submitted it yet.
The bounded wait cannot complete that frame.

`0037-syncobj-merger-error-handling.patch`, used by both shell and Nix builds,
combines release-merger safety handling with the following composition changes:

- Each existing render-list entry reserves storage for a release-merger
  reference. Immediately before recording a texture draw, the entry retains
  the exact surface buffer generation's merger. This needs no new descriptor
  or allocation. The reference survives surface replacement/detach during
  submission callbacks.
- Sample events retain their presentation feedback and timeline information;
  `release_deferred` tells the scene surface listener that composition owns
  release registration. Direct scanout and hardware-layer events continue to
  use their existing path.
- After submission, the scene registers the submitted pass's timeline point
  with every retained merger. Here "after submission" does not imply GPU
  completion: normal release fences remain asynchronous. An export, merge or
  waiter failure can use 0037's bounded completion recovery now that work has
  been submitted. Earlier aggregate fences remain intact.
- Every output that samples a surface contributes its dependency, including
  outputs other than the surface's frame-pacing output. Presentation feedback
  still follows the original frame-pacing policy.
- On a failed Vulkan submission, only the new reservation is dropped. This
  relies explicitly on the pinned 0020/0030 implementation: returning failure
  means this pass was not submitted or its completion was established.
  Unknown acceptance and unresolved submitted work terminate inside the
  renderer. Quarantined, unsubmitted passes retain their renderer resources
  for teardown. No wait is issued for a rejected frame's unsubmitted point,
  and dependencies from previous frames or other outputs are not discarded.
  Other renderers retain registration on failure because that Vulkan-specific
  guarantee cannot be assumed for them.

If completion still cannot be established, the terminal safety policy remains.
Deleting the abort without retaining or resolving dependencies would permit
early client buffer reuse. This patch does not disable explicit sync, alter
driver selection, or further increase the FD limit.

Failure diagnostics record the operation, original error number, source DRM
device path/FD/handle/point, destination FD/point, and FD count/limits. Counts
use `fcntl`, so they still work at EMFILE without opening `/proc/self/fd`.
The scan is capped at 65,536 descriptors; a `+` marks a lower bound when the
soft limit exceeds that cap or could not be read, and `fd_scan_limit` records
the scanned range. Scene recovery also logs output, renderer type, submission
result and recovery outcome. Export/import, availability, signal and waiter
helpers preserve the original error across logging and cleanup. These are
failure-only diagnostics, not continuous FD-growth measurements.

Validation artifacts are under `/tmp/aqueous-scene-release`:

- Full private wlroots reconstruction/build and the dependency regression
  suite passed with the combined behavior. Shell and Nix patch lists agree.
- `test-drm-sync.py` passes normally and with ASan/UBSan/LeakSanitizer. Its
  production scene helpers are tested with mocked submission/DRM operations
  and real descriptors: allocation/waiter failure enabled before submission,
  post-submission export/merge/waiter failures, surface detach during
  submission, rejected and completed-but-failed frames, two outputs retaining
  one buffer, and fatal unresolved completion. The existing 6,000 release
  cycles and atomic resource tests also pass.
- Negative controls detect restored pre-submission registration, a missing
  generation reference, waiting on a rejected frame, dropping a submitted
  dependency, and loss of the original error, alongside the existing ownership
  and premature-release controls. Diagnostics are checked with all 64 allowed
  descriptors occupied.
- The production Vulkan submission fixture passes its 6,000-frame and failure
  tests, including cancellation, completed publication failure and terminal
  unknown/pending submissions. Real software Vulkan presentation passes
  allocation fallback, output isolation/hotplug, pixels, reuse, resize, capture,
  commit and reset.
- Aqueous builds in ReleaseSafe with Vulkan effects and Xwayland against the
  private dependency; all 656 tests across 124 build steps pass.

The sandbox blocked the first local Wayland test client and LeakSanitizer
process inspection; those checks passed outside the sandbox. No system
compositor or library was replaced. There is no `/dev/dri` in this environment.
The scene ordering regressions exercise extracted production functions, not a
physical explicit-sync client/GPU/KMS pipeline. Verification on the affected
Intel/NVIDIA 580 setup must still check normal application use, two outputs,
and FD growth over time. A successful recovery here does not establish or fix
the cause of any continuing driver-owned FD retention.

The composition changes and diagnostics were initially a separate patch 0038,
then folded into 0037. Reconstructing the pinned archive and applying the
consolidated patch produces byte-identical source files to the previously
tested two-patch series. The consolidated patch applies without context fuzz;
the separate 0038 file and its shell/Nix entries are removed.

## Vulkan device-loss recovery (2026-10-29)

The new `0038-vulkan-device-loss-recovery.patch` follows consolidated 0037;
it is unrelated to the earlier, folded scene patch with that number. Its baseline
is the checksum-pinned `wlroots-0.20.2.tar.gz` plus the 38 patches in the shell
builder and Nix derivation, not `/home/zoey/Projects/wlroots`. Reconstructing that
baseline matches `/tmp/aq-wlr/src.base` apart from patch backup files. The
preserved `/tmp/aq-wlr/src` was copied for integration and remains unchanged.
The new patch applies without fuzz, and both build lists now contain the same
39 patches in the same order.

The [Vulkan lost-device specification](https://docs.vulkan.org/spec/latest/chapters/devsandqueues.html#devsandqueues-lost-device)
treats `VK_ERROR_DEVICE_LOST` as success when determining command-buffer pending
state and device resource use. Failed render submissions with this result become
`WLR_VK_PASS_COMPLETE`, retain the pass for teardown, and emit the renderer's
loss event. Upload submission loss also marks the renderer for replacement.
Recovery waits accept device loss as resource completion and emit loss once.
Timeouts retry for at most ten one-second slices; unknown submission outcomes
and exhausted waits on pending work still terminate before returning to callers.
Healthy direct rendering adds no wait.

Presentation copies now use the same bounded completion helper. A successful
wait permits readback, whereas device loss rejects the frame before mapped
memory is read or copied. Completion on a lost device does not establish valid
pixel contents. This also closes the preserved prototype's single-wait abort
path in presentation copying.

There is no output-target exception. Patch 0037 drops the failed frame's deferred
client surface release-merger reservation when Vulkan submission returns false.
Even rendering to an output swapchain reads client buffers, so an unresolved
live timeout cannot safely return false. Device loss satisfies the resource-use
contract; it does not establish that an external producer dependency completed.

Validation for this change:

- The complete private-wlroots build and checks pass, including the scene release
  ordering tests, Vulkan/DRM sanitizers, 6,000-frame descriptor checks, and all
  11 Vulkan negative controls. New cases cover immediate loss, one or nine
  timeouts followed by success/loss, ten exhausted slices, unknown errors,
  cancellation, upload submission, wait-point selection, loss notification,
  retained locks/callbacks during waits, and rejection of lost-device pixels.
- Aqueous builds with `-Dllvm=true -Doptimize=ReleaseSafe -Dxwayland=true`:
  58/58 build steps succeed. The full test target passes 658/659 tests. The
  remaining `aqueousctl` test, `outputs render advertised refresh rates and mode
  flags`, expects JSON without the existing `xwayland_scaling` object. Its source
  is unchanged, and the failing binary links only libc, not wlroots or Vulkan.
- Real Lavapipe presentation passes with `VK_LAYER_KHRONOS_validation`, covering
  allocation fallback, output isolation/hotplug, pixels, reuse, resize, capture
  import, commit and renderer recreation. This is not a real device-loss test.
- Shell/Nix patch-list parity and shell/Python syntax checks pass. Nix itself is
  unavailable, so no Nix build was run. Shelly commands were checked before
  building; no dependency installation was needed.

Logs are `/tmp/aqueous-wlroots-recovery-build.log`,
`/tmp/aqueous-vk-recovery-compositor-build.log`,
`/tmp/aqueous-vk-recovery-compositor-tests.log`, and
`/tmp/aqueous-vk-recovery-presentation.log`. LeakSanitizer process inspection
requires running outside this environment's ptrace-restricted sandbox.
The GTX 1080 configuration, physical scanout, and recovery from actual device
loss or hardware stalls remain unqualified. No hardware reset was induced.
