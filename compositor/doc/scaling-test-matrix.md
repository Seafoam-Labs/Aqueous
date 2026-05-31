# Output scaling — test & regression matrix

This document tracks how the output-scaling pipeline (Phases 1–5) is verified.

## Pipeline recap

- **P1** — scale clamps to `[0.1, 10.0]` and rounds to 1/120; commits onto
  `wlr_output` (`river/scaling.zig`, `Output.State.fromHeadState`).
- **P2** — scale/transform-only deltas route through `backend.commit`, so
  wlroots' `wlr_output_schedule_done` fans `wl_output.scale`/`done` out to
  bound clients (`OutputManager.commitOutputState` `need_modeset` predicate).
- **P3** — `wlr_output.events.commit` → `Output.handleCommit` →
  `server.wm.dirtyWindowing()` re-tiles / re-anchors / reconfigures.
- **P4** — `wp_fractional_scale_v1` + `wp_viewporter` + `wl_compositor` v6
  advertised; `wlr_scene` notifies each surface of its per-output preferred
  (fractional) and `preferred_buffer_scale`.
- **P5** — the server-drawn xcursor theme reloads per active output scale
  (`Cursor.loadActiveScales` / `Cursor.reloadScales`).

## Automated coverage

### Unit (`zig build test -Dllvm=true`)

| Test | Module | Asserts |
|---|---|---|
| `clampScale bounds` | `river/scaling.zig` | clamp to `[0.1, 10.0]` |
| `roundScale snaps to 1/120` | `river/scaling.zig` | fractional-scale exactness |
| `normalizeScale clamps then rounds` | `river/scaling.zig` | P1 composition |
| `preferredBufferScale ceils` | `river/scaling.zig` | integer-ceil for v6 path |

### Headless integration (`bash scripts/test-scaling.sh`)

Launches `riverdelta` under `WLR_BACKENDS=headless` and asserts:

| Check | Proves | Requires |
|---|---|---|
| `commit affects layout (scale=true …)` after `wlr-randr --scale 2` | P3 relayout | wlr-randr |
| no `failed to load xcursor` after scale change | P5 cursor reload | wlr-randr |
| reverse `--scale 1` relayouts | symmetry | wlr-randr |
| re-applying current scale → no relayout | no-op guard (P2 predicate idles) | wlr-randr |
| client receives `wl_output.scale(2)` + `done` | P2 fan-out | foot |
| `wp_fractional_scale_manager_v1` / `wp_viewporter` / `wl_compositor` v6 | P4 globals | wayland-info |

Checks whose tools are missing degrade to `SKIP` rather than failing.

## Manual matrix

The headless backend renders no real pixels, so visual crispness and cursor
pixel-size must be checked by hand on a real session.

| Axis | Values |
|---|---|
| Toolkits | `foot`, GTK3, GTK4 (`gtk4-demo`), Qt5, Qt6, Electron, `mpv`, Firefox, an SDL2 game (v5 / non-fractional regression) |
| Scales | 1.0, 1.25, 1.5, 1.75, 2.0, 3.0 |
| Scenarios | single output; dual output mixed scales; hot-plug at non-1 scale; fullscreen across scale change; layer-shell bar (waybar) across change; live `wlr-randr` change with running clients; Aqueous Display Settings end-to-end |
| Cursor (P5) | 24px@1×, 36px@1.5×, 48px@2×; live resize without pointer move; correct size per output across a mixed-scale boundary |

Per cell: ✅ crisp + correct size / ⚠️ soft (expected only for Xwayland) /
❌ regression.

### Aqueous end-to-end loop

Quickshell `OutputControl.qml` → `OutputDaemon.Validator` (`[0.5, 3.0]`) →
`WlrRandr.Apply --scale` (`rc=0` in
`journalctl --user -u aqueous-output-daemon`) → river log
`commit affects layout` → client redraw.

## Known limitations

- Xwayland clients keep their own DPI story and stay at scale 1; soft rendering
  on a fractional output is expected, not a regression.
- The headless backend can confirm protocol events but not pixel crispness;
  that part of the matrix stays manual.
