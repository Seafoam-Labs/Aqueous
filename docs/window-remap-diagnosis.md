# Window remapping visibility regression

The mixed-monitor Electron reproduction fails with the previous map-invalidation
fix present. A separate wlroots syncobj defect retains the hidden window's buffer
release state. Patch `0012-syncobj-release-on-buffer-detach.patch` corrects it.

## Mixed-resolution, mixed-refresh reproduction

Run from `compositor/` with an XWayland-enabled Vulkan build:

```sh
python3 scripts/test-window-remap.py --renderer vulkan \
  --electron /path/to/electron --backend electron-wayland --discord-lifecycle \
  --timing cross-output --output-width 2560 --output-height 1440 \
  --output-refresh 144 --second-width 1920 --second-height 1080 \
  --second-refresh 60 --cycles 5 --reopen-wait 3
```

The runner verifies the applied output modes, saves them in `*-outputs.json`,
and checks both destinations after every reopen. It records passive scene state
before screenshots. Equal-output tests and checking only the final return to
monitor 1 were insufficient coverage for this report.

The Electron fixture uses one persistent BrowserWindow. `--discord-lifecycle`
adds hide/skip-taskbar on close, show/unskip-taskbar/focus on reopen, and a 940×500
minimum size. It loads local solid-color content with an isolated profile and
needs no Discord account or installation.

### Cause and evidence

The original library repeatedly failed the first reopen onto the smaller,
slower output. A fresh process on that output rendered correctly. After ten
seconds without screenshots or input, the reopened window was still
`initialized`, `configure=timed_out`, and its scene parent remained disabled.
The trace showed a configure for the new tile size, followed by stale-size buffer
allocation, but no configure acknowledgement or attached replacement buffer.

Chromium's trace showed that its submission queue stopped advancing because the
previous buffer had not been released. Its Wayland frame manager waits for the
previous frame's buffers before acknowledging the next submission; configure
acknowledgement also waits for the corresponding rendered frame. See
[Chromium's frame manager](https://chromium.googlesource.com/chromium/src/+/refs/tags/148.0.7778.0/ui/ozone/platform/wayland/host/wayland_frame_manager.cc)
and [window state synchronization](https://chromium.googlesource.com/chromium/src/+/refs/tags/148.0.7778.0/ui/ozone/platform/wayland/host/wayland_window.cc).

In wlroots 0.20.2, `surface_synced_move_state()` ignored every commit without an
acquire timeline. This conflated an ordinary commit without a buffer attachment
with an explicit NULL attachment that detaches the old buffer. The latter kept
the old syncobj release merger alive until a replacement buffer or surface
teardown. Electron reuses the wl_surface across hide/show and can wait for that
release before submitting the resized replacement: a circular wait. Fully
quitting the process tears down the retained state, explaining the successful
fresh-process control.

### Correction and validation

The patch carries the buffer-attachment committed bit through wlroots' existing
synchronized-state machinery. Applying a NULL attachment clears the old syncobj
state; ordinary bufferless commits preserve it. The existing merger still waits
for registered GPU completion fences. The patch does not signal release points
unconditionally or disable explicit synchronization.

With the same Aqueous executable and only the wlroots library changed, five
mixed-monitor round trips passed with normal Electron syncobj behavior enabled.
The unchanged library repeatedly failed on the first reopen. Controls also
passed with both refresh rates at 60 Hz (five round trips), with Electron's
`WaylandSyncobjReleaseTimeline` feature disabled (three), and with Electron X11
on mixed monitors (three). These isolate the demonstrated release-path failure;
they do not imply that every mixed-monitor issue has this cause. The complete
Discord application and the affected physical session have not been retested.

The reduced `--backend wayland-syncobj` regression checks real DRM release
points directly. It first commits without an attachment and checks that the
attached buffer's release state is retained, then attaches NULL and waits for
release before submitting any replacement. The original library times out at
that wait; the corrected library releases and remaps. This variant checks
fences and mapping, while the Electron test checks actual rendered pixels.
It uses GBM DMA-BUFs on the compositor's render device and requires `libdrm`
and `gbm` development files.

The final ReleaseSafe candidate bundle was also checked without a library-path
override: it loaded its bundled patched wlroots, passed three mixed-monitor
round trips for native syncobj, Electron Wayland and Electron X11, and verified
six detach releases alongside six retained bufferless commits. `zig build test`
passed against the patched dependency.

Both the shell dependency builder and Nix patch list include the correction.
Rebuild and distribute the patched **wlroots library** with Aqueous; rebuilding
only the Zig executable against the old library will retain the defect. The
running compositor needs a restart to load the rebuilt library. For a local
private-library comparison, `LD_LIBRARY_PATH=/path/to/patched/lib` selects the
candidate without replacing the installed library.

## Earlier native same-size map defect

The headless test reproduced a mapped window occupying a tile while its content
and borders remained invisible. The cause in this reproduction is missing render
invalidation on map, not a missing client buffer or a stuck animation.

### Evidence and cause

Before the correction, the passive scene snapshot showed all of the following:

- The window lifecycle was `mapped` and configure state was `idle`.
- Policy visibility was enabled (`hidden=false`, `overview=false`).
- Both animation flags were false and the layout clip was empty.
- A correctly sized live surface buffer existed with opacity `1.000`.
- The window's parent scene node was **disabled**, in the normal window layer.

The screenshot contained no target pixels. Waiting and taking more screenshots
did not repair the scene. Fresh-process controls passed in the same session.

`XdgToplevel.configure()` avoids tracking a resize transaction when the requested
dimensions already match the retained geometry. The compositor can therefore
finish rendering while the reopened window is still `initialized`.
`Window.renderFinish()` intentionally disables an unmapped window's scene tree.

When the client subsequently commits its buffer, `Window.map()` changes the
lifecycle to `mapped`. Previously it did not invalidate rendering. An unchanged
geometry commit may not schedule a render either, leaving the scene node disabled
until unrelated management/render work happens. Other clients' resize commits
or input-device changes can mask this ordering, explaining intermittent results.

The correction calls `server.wm.dirtyRendering()` when the window maps. This
ensures the normal render transaction evaluates visibility after mapping,
without enabling unmapped windows early or forcing unnecessary client resizes.

### Reproduction

Build with XWayland support. Use an effects build with `--renderer vulkan`, or
a `-Dvulkan-effects=false` build with `--renderer pixman`. Run from `compositor/`:

```sh
python3 scripts/test-window-remap.py --renderer vulkan --backend wayland
python3 scripts/test-window-remap.py --renderer vulkan --backend wayland --timing same-size
python3 scripts/test-window-remap.py --renderer vulkan --timing interrupt \
  --second-scale 1.5 --electron /path/to/electron
```

Use `--compositor /path/to/aqueous --ctl /path/to/aqueousctl` for comparison builds.
Every run prints an artifact directory containing its arguments, results,
client/compositor logs, scene snapshots, and output screenshots.

The default test gives both outputs identical tile sizes and checks a direct
hide/show across them. The reduced same-size case needs no animation or output
movement. The interrupt case confirms an active live-transfer animation before
closing the window. No test client withholds buffers in these cases.

Timing sequences use one persistent virtual pointer and inspect the scene before
taking screenshots. Creating and destroying a virtual pointer for every move
previously caused unrelated management cycles, sometimes concealing the bug.
Only fresh-start controls poll screenshots for initial browser content readiness.

### Validation and limits

The original build failed the native Wayland same-size, interrupted-transfer,
and direct equal-size cross-output reproductions. The render-invalidation
correction passed the native regression and direct cross-output checks with
X11 and Electron 42 on both Wayland and X11. The unit suite and existing
`test-window-lifecycle.sh` also passed.

The optional `--negative-control` intentionally acknowledges the remap configure
without committing a buffer and must fail. It distinguishes the earlier
stalled-client hypothesis from the reproduced bug, where a valid buffer exists.

This earlier test demonstrates a separate defect with a similar empty-tile
symptom. The minimal native fixture reuses its XDG toplevel; Electron destroys
and recreates that role while keeping its wl_surface. The native map correction
cannot resolve a syncobj stall which prevents mapping from happening at all.

## Optional live-session capture

From the affected Aqueous session, run this from `compositor/`, then reproduce the
close-on-monitor-1 / reopen-on-monitor-2 sequence within 30 seconds:

```sh
python3 scripts/collect-window-remap.py --ctl ./zig-out/bin/aqueousctl
```

Use `--duration 60` for more time or omit `--ctl` if `aqueousctl` is on PATH.
The recorder prints a `/tmp/aqueous-live-remap-*` directory. Keep both
`samples.jsonl` (complete scene/window/output queries) and `summary.json`
(matching window transitions and query failures). Logs include window titles.
It issues no screenshots, input, focus changes, or configuration changes. Queries
are independent rather than an atomic snapshot, so single transition samples
must be interpreted alongside adjacent samples.

Normal scene dumps show enabled nodes and surface buffers. If the compositor
session was started with `AQUEOUS_DEBUG_WINDOW_STATE=1`, labels additionally
include lifecycle, policy visibility, animation, configure and opacity details.
The recorder cannot enable that startup setting in an already running session;
a capture from the current session is still useful without it. Inspect whether
the failed window has a buffer, whether its scene ancestors are enabled, and
whether its position and clipping intersect the destination output before
choosing another fix.

Stress inspection also exposed a separate diagnostic crash: a scene node can
outlive its destroyed backend briefly. Scene labels now avoid querying its title
in that interval. This prevents the diagnostic tool from crashing the compositor;
it is separate from the missing-window correction.
