# Window remapping visibility regression

The headless test reproduced a mapped window occupying a tile while its content
and borders remained invisible. The cause in this reproduction is missing render
invalidation on map, not a missing client buffer or a stuck animation.

## Evidence and cause

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

## Reproduction

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

## Validation and limits

The original build failed the native Wayland same-size, interrupted-transfer,
and direct equal-size cross-output reproductions. The render-invalidation
correction passed the native regression and direct cross-output checks with
X11 and Electron 42 on both Wayland and X11. The unit suite and existing
`test-window-lifecycle.sh` also passed.

The optional `--negative-control` intentionally acknowledges the remap configure
without committing a buffer and must fail. It distinguishes the earlier
stalled-client hypothesis from the reproduced bug, where a valid buffer exists.

These results establish an Aqueous defect that produces the reported empty-tile
symptom. They do not establish the affected Discord instance's backend or build.
The Electron fixtures tested so far did not reproduce the same native defect on
the original build. In the recorded Electron Wayland trace, hide destroys the XDG
toplevel and show creates another, while the minimal native fixture reuses its
XDG toplevel. Matching the affected Discord lifecycle remains necessary before
claiming this is conclusively the cause of that recording.

Stress inspection also exposed a separate diagnostic crash: a scene node can
outlive its destroyed backend briefly. Scene labels now avoid querying its title
in that interval. This prevents the diagnostic tool from crashing the compositor;
it is separate from the missing-window correction.
