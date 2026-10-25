# GPU synchronization descriptor ownership investigation

Two resource leaks are reproduced and fixed in the private wlroots dependency:
DRM atomic preparation can lose an exported input fence on a later preparation
failure, and release-merger waiter initialization can leak its heap record.
Neither is established as the cause of the reported NVIDIA incident. No
unbounded FD growth was reproduced in successful Vulkan frames or completed
release merges with the controlled GPU mocks. Physical NVIDIA and cross-GPU
validation remain unavailable on this development host.

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
| Vulkan submission and publication | Binary-semaphore export returns a caller-owned FD, closed after timeline/DMA-BUF publication on success or failure. The `-1` already-signalled sentinel is handled separately. Cancellation destroys imported temporary payloads; publication recovery waits before disposing of submitted work. Timeout/device-loss tests retain locks/quarantine work or take the existing fatal path, rather than manufacture completion. |
| Semaphore reuse and renderer destruction | Wait semaphores are bounded by command-slot high-water usage; successful imports belong to the Vulkan implementation. Resource retirement requires completion, and renderer destruction waits for idle/device loss before destroying semaphores and quarantined passes. Driver-internal FD retention cannot be qualified by a mock that implements the ownership contract. |
| DRM atomic and libliftoff | Both commit implementations apply or roll back each connector, including TEST_ONLY and partial preparation failure. Patch 0035 fixes the exported-FD ownership gap. Tests run the real atomic orchestration/preparation/cleanup functions with mocked KMS, two outputs, rejected commits and disable/re-enable. Libliftoff-specific property transitions are covered by the existing overlay test; physical assignments are not simulated. |
| Hardware layers and fallback | Pending layer fences are closed on replacement, commit, rollback and addon destruction. Queued/current release points move with scanout buffers and are released on replacement/disable. If higher-level preparation exits before `drm_commit`, a pending fence can remain owned by a layer until replacement/destruction; that is bounded per layer, not a lost descriptor. Aqueous finishes output states and overlay candidates on composition fallback. |
| Surface replacement, detach and release merging | Patch 0012 preserves bufferless state and drops the old merger on actual replacement/detach. A live merger normally retains one merged FD, while an unavailable source point retains an eventfd waiter and references. Two-output replacement/detach tests complete callbacks and return both FD and timeline-ref counts to baseline. Unfinished dependencies legitimately keep those records alive. |
| Cross-GPU and mirrors | `drm_surface_blit` passes the source wait point into the render pass and publishes the copy timeline; connector state owns its timeline reference until finish. OutputMirror bounds in-flight copies and preserves orphaned jobs until their waiter callback. Presentation-copy tests use the real software Vulkan implementation; no physical DMA-BUF transfer between Intel and NVIDIA was exercised. |
| Aqueous recovery/output lifecycle | Output states use deferred finish; fallback rebuilds state; renderer recovery reinitializes outputs and destroys the old renderer. Copy reset and headless hotplug are integration-tested. Mock teardown occurs only after simulated completion; it does not qualify physical device reset. |

One additional synchronization concern remains outside these resource-leak fixes:
`merger_add_exportable` does not propagate export/merge errors and can replace its
previous fence with `-1`; final unref can then signal an incomplete release.
Final timeline import errors are also ignored. The new fault tests verify FD
cleanup for those branches, **not safe release semantics**. Fixing that requires
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
