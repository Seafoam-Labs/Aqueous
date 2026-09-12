# Capture integrity experiments

Implements the automated core of [the investigation plan](../../../docs/screencast-investigation-plan.md): portal scheduling, Vulkan/DMA-BUF synchronization, damage, and plane transitions. Production code and installed services are untouched. Each experiment starts private D-Bus, PipeWire, portal, and Aqueous processes, and terminates only those processes.

The default headless backend **uses the actual GPU** for Vulkan rendering and capture. It cannot qualify physical DRM planes, monitor tearing, or Firefox/Cinny's capture, encoder, or receiver. Tests use the portal backend directly; they do not test the desktop portal frontend's permissions, picker, or application routing.

## Build

From the repository root, with the normal Aqueous build dependencies plus a C compiler, Python 3.12+, meson, ninja, patch, wayland-scanner, gdbus, PipeWire development headers, EGL/GLES, GBM, and libdrm:

```sh
python3 compositor/scripts/capture/build.py --output /tmp/aqueous-capture
/tmp/aqueous-capture/check-pattern --self-test
python3 compositor/scripts/capture/test_analysis.py
```

Aqueous and aqueousctl must already exist under `compositor/zig-out/bin/`, or pass `--compositor` and `--ctl`. The builder verifies SHA-256 hashes of portal 0.8.4 and wlroots 0.20.2 archives, applies the repository's production patch series, then adds diagnostics to **private extracted sources**. Saved patches and build manifests make those changes reviewable. Nothing is installed globally.

`--portal-archive PATH` avoids downloading the portal. `--wlroots-archive PATH` overrides the default archive in `compositor/.deps/downloads/`. Use a new build directory for another portal/wlroots build; extraction fails rather than overwriting an existing source tree. `--stage probes` can rebuild just the fixtures in an existing directory.

## Run

The invoking process needs access to the NVIDIA render node. Use the appropriate `--render-node`; the compositor log identifies the actual Vulkan GPU. A sandbox without `/dev/dri` reports exit 77 and **not exercised**. Do not change device permissions globally.

```sh
# Fast end-to-end check.
python3 compositor/scripts/capture/run.py --build /tmp/aqueous-capture \
  --seconds 5 --repetitions 1 --width 640 --height 360 --sparse

# Verify deliberate mixed rows, stale tiles, missing content, and bad metadata.
python3 compositor/scripts/capture/run.py --build /tmp/aqueous-capture \
  --variant controls --seconds 5 --repetitions 1 --width 640 --height 360 --sparse

# Full A/B/A matrix: three 60-second repetitions, 1440p, second output at 1080p60.
python3 compositor/scripts/capture/run.py --build /tmp/aqueous-capture \
  --variant matrix --dual --sparse --artifacts /tmp/capture-matrix
```

The selected virtual output is configured at 180 Hz; capture is capped at 60 FPS (or 30 for the rate comparison). `--output NAME` selects a source. Default fixture rendering uses release-managed Wayland SHM buffers; capture still uses GPU DMA-BUF. `--gpu-fixture` instead submits an EGL Wayland surface, useful for hardware plane eligibility. Its behavior must be qualified separately: an EGL producer stall is an inconclusive workload, not a passing capture test.

Every nonbaseline variant runs as baseline → variant → baseline. The matrix covers buffer counts 2/4/8, hold times 1/2/4 frame periods, 30 FPS, source/copy waits, SHM, full copy damage, full metadata, full redraw, overlay/scanout switches, and two combinations. Hold tests establish two seconds of baseline, then alternate one-second pressure and recovery intervals. Check `buffers_added` to verify allocation; requesting a count does not prove negotiation honored it.

`--variant implicit-only` deliberately omits the consumer's explicit wait on producer DMA-BUF fences. It tests reliance on EGL's implicit synchronization. Corruption confined to this case cannot establish an Aqueous copy defect. The normal consumer exports/polls producer fences (or polls the DMA-BUF if export is unsupported), then imports the image and completes GL readback before returning the buffer. Unsupported imports fail visibly. DMA-BUF and SHM frame counts record the actual transport.

`--no-trace` and `--production-wlroots /path/to/lib` support timing comparisons with ordinary builds. Missing trace coverage remains inconclusive; raw pixel results are still retained. Keep configuration, resolution, fixture, and driver identical when comparing overhead.

## Portal rename comparison

Build upstream 0.8.4 without the repository's naming patch:

```sh
python3 compositor/scripts/capture/build.py --output /tmp/aqueous-capture-upstream --unrenamed
python3 compositor/scripts/capture/run.py --build /tmp/aqueous-capture-upstream \
  --unrenamed --variant baseline --sparse
```

Compare its manifests and frames with the renamed build. The explicit portal configuration is identical; the runner calls the corresponding D-Bus name directly. This isolates executable/configuration/D-Bus renaming from capture code. A desktop-routing comparison still requires the actual frontend/client session. Version 0.8.4 was the latest release listed by [upstream](https://github.com/emersion/xdg-desktop-portal-wlr/releases) when this harness was implemented; testing a later revision requires a separately pinned, reviewed source and compatible instrumentation anchors.

## DRM qualification

Run from a separate TTY on a seat available to the test compositor, after ending the ordinary graphical session. The runner refuses `--backend drm` when launched from an existing Wayland/X11 environment. Headless success never becomes a DRM pass.

```sh
python3 compositor/scripts/capture/run.py --build /tmp/aqueous-capture \
  --backend drm --output DP-1 --gpu-fixture --overlay --cycles 20 \
  --seconds 3 --repetitions 1 --variant baseline --sparse
```

Repeat with `--variant no-overlay`, `no-scanout`, and `no-planes`. Inspect actual promotion/scanout evidence and `planes-before/during/after.json`; eligibility alone is insufficient. Direct scanout uses the existing `WLR_SCENE_DISABLE_DIRECT_SCANOUT=1`; overlay disabling uses the existing compositor switch. Capture start/stop traces identify the lock interval. Promotion rejected by the driver remains **not exercised**.

`--transitions` also toggles fullscreen while recording. Geometry changes invalidate the fixed full-output pixel oracle, so these runs remain inconclusive and preserve frames for inspection. Overlapping windows, cursor changes, effects, workspace animations, legacy capture, and physical-monitor observation still require separate workloads from the plan. Reuse `test-overlay-hardware.sh` for a live hardware soak and `test-overlay-backend.py` for mocked DRM property/fence invariants.

## Evidence and interpretation

Each run saves `invocation.json`, a successful-run `manifest.json` with binary hashes and resolved libraries, private process logs, portal replies, per-cycle plane snapshots, and up to three failing raw PPM frames. `matrix.json` accumulates results even if one experiment fails. Reported statuses are **not reproduced under tested conditions**, **not exercised**, or **inconclusive**. Confirmation and attribution require inspection of the A/B/A evidence; the runner never infers a root cause solely from an override improving output.

The fixture repeats a 24-bit frame identifier in every row and uses a predictable eight-tile body. The checker tolerates color conversion by comparing luminance classes, detects mixed row IDs and stale/missing pixels, and separately reconstructs frames using SPA damage metadata. Legitimate sampling gaps and duplicate frames are counted separately from regressions. A continuously animated fixture that stops delivering frames for over 500 ms cannot pass.

Trace files use a bounded mmap allocation: 32,768 × 384-byte slots per process/translation unit. Records are JSON lines padded with spaces; unused tails contain NUL bytes. `run.traces()` parses them after teardown. Overflow, malformed records, missing required events, repeated consumer acquisition without release, and unrecovered starvation prevent clean classifications. Long multi-cycle runs can exceed the bound: split runs or deliberately revise the bound and record that change. Do not use plain `json.load()` on a padded trace.

The consumer's GPU readback, fence polling, pixel analysis, and tracing alter timing. These are diagnostic experiments, not a throughput benchmark. Results on a different GPU or compositor revision do not close the RTX 3070/Firefox/Cinny report.

Trace fields use monotonic nanoseconds (`ns`) and a per-file sequence (`seq`). Pointer identities are meaningful only within that process/file; do not join raw pointer or FD numbers across processes. The event chain and protocol ordering correlate the producer, portal, and consumer.

| Event | `a`, `b` | `c`, `d` |
|---|---|---|
| `client_commit` / `client_release` | fixture buffer identity, unused (EGL commits use zero) | fixture frame number, sparse flag / unused |
| `dequeue` / `queue` | portal cast, portal PipeWire buffer | FD, unused / corrupt flag |
| `capture_request` / `capture_ready` | portal cast, portal PipeWire buffer | unused |
| `copy_begin` / `copy_submitted` | source buffer, destination buffer | dimensions / SHM flag |
| `source_fence` / `copy_fence` | compositor buffer, unused | FD, signaled: 0 pending, 1 complete, −1 unsupported |
| `frame_ready` | protocol frame, destination buffer | unused |
| `acquire` / `read_complete` / `release` | consumer PipeWire buffer, unused | FD / decoded frame / frame if known; read-complete `d` counts bad pixels/rows |
| `producer_wait` | unused | wait succeeded, wait duration in ns |
| `capture_start` / `capture_stop` | compositor output, unused | active capture count, unused |
| `scanout_result` | output, candidate buffer | 0 ineligible, 1 candidate, 2 scene success; unused |
| `committed_layer` | output, layer buffer | accepted flag, commit sequence |

`read_ns` measures import, producer-fence wait, and readback; it excludes subsequent pixel/metadata checking. `max_gap_ns` measures arrival gaps and `tail_gap_ns` detects the animated fixture stalling near the end. Neither is a network/Cinny metric.

### Synchronization failure regressions

The production correction and validation notes are in
[`docs/frame-sync-fix-results.md`](../../../docs/frame-sync-fix-results.md).
`../test-vulkan-sync.py PATCHED_WLROOTS_SOURCE INSTALLED_PREFIX` exercises the
complete production synchronization functions with deterministic API failures,
FD/lock accounting, sanitizer checks and negative controls. The pinned dependency
build runs this regression automatically.

To inject a one-shot failure into an actual private NVIDIA capture copy, build the
separate test library against the same wlroots installation:

```sh
cc -DWLR_USE_UNSTABLE -std=c11 -Wall -Wextra -Werror -shared -fPIC \
  compositor/scripts/fixtures/vulkan-sync-inject.c \
  $(pkg-config --cflags wlroots-0.20) -ldl -o /tmp/aqueous-sync-inject.so
python3 compositor/scripts/capture/run.py --build /tmp/aqueous-capture-build \
  --sync-fault acquire-import --sync-fault-library /tmp/aqueous-sync-inject.so \
  --sync-fault-after 30 --cycles 2 --seconds 5 --repetitions 1 --sparse
```

Repeat with `--sync-fault completion-export`. The runner injects only into its
private compositor, verifies the injection fired, expects the first portal
session to close on capture failure, and checks a new session in the same
compositor. The second session must pass the ordinary pixel/transport checks.
No fault environment variables or preload library are installed into the user's
session. Run GPU timing comparisons serially.

`--sync-fault capture-reject` is a synthetic attribution control: it rejects an
otherwise successful copy without failing a synchronization API. Keep its results
separate from the real acquire/export fault tests. Current headless fault/restart
baselines expose a separate scanout-transition qualification gap. Adding
`--variant no-scanout` runs an A/B/A control; the disabled-scanout case checks
recovery with continuous composition, while baseline failures remain recorded.
See the results document for the ordinary-versus-control observations.
