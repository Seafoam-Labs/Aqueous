# Output scaling — test & regression matrix

This document tracks how the output-scaling pipeline (Phases 1–7) is verified.

## Pipeline recap

- **P1** — scale clamps to `[0.5, 3.0]` and rounds to 1/120; commits onto
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
- **P6** — policy placements retain their owning output's scale and origin.
  Static window roots and eased animation roots snap in output-local physical
  pixels, then convert back to precise logical coordinates for scene rendering.
  XDG configure dimensions and input geometry remain integral.
- **P7** — client-buffer policy is published before initial root and popup
  configures. `native` advertises the exact fractional scale; the opt-in
  `integer-ceil` path advertises its ceiling and persists across later scene
  output notifications.

## Automated coverage

### Unit (`zig build test -Dllvm=true`)

| Test | Module | Asserts |
|---|---|---|
| `clampScale bounds` | `aqueous/scaling.zig` | clamp to `[0.5, 3.0]` |
| `roundScale snaps to 1/120` | `aqueous/scaling.zig` | fractional-scale exactness |
| `normalizeScale clamps then rounds` | `aqueous/scaling.zig` | P1 composition |
| `logicalDimension rounds non-even divisions` | `aqueous/scaling.zig` | physical→logical rounding for `Output.State.dimensions` |
| `physical grid snaps logical origins without subpixel filtering` | `aqueous/scaling.zig` | P6 physical-boundary round trip at 1.25× |
| `physical grid follows each output scale` | `aqueous/scaling.zig` | P6 mixed-scale ownership |
| `physical grid is local to the owning output origin` | `aqueous/scaling.zig` | P6 non-zero mixed-scale output origins |
| `buffer scale policy parses aliases and advertises integer ceilings` | `aqueous/scaling.zig` | P7 exact default and compatibility scales |

The patched-wlroots build also compiles and executes
`scripts/fixtures/wlroots-precise-position.c`. The probe verifies that nested
precise scene positions survive as doubles and that the legacy integer setter
cleanly returns a node to integer positioning.

### Headless integration (`bash scripts/test-scaling.sh`)

Launches `aqueous` under `WLR_BACKENDS=headless` and asserts:

| Check | Proves | Requires |
|---|---|---|
| `commit affects layout (scale=true …)` after output socket `set` | P3 relayout | native output service |
| deterministic 24px cursor captures as 12/18/24/30/36/42/48/60/72px across 0.5–3× | P5 exact cursor scale over the accepted range | grim + ImageMagick + wlrctl + Xcursor development files |
| cursor changes size across those captures without another pointer event | P5 live stationary-cursor reload | same pixel oracle |
| no `failed to load xcursor` after scale change | cursor theme load health | native output service |
| reverse `scale=1` relayouts | symmetry | native output service |
| re-applying current scale → no relayout | no-op guard (P2 predicate idles) | native output service |
| client receives `wl_output.scale(2)` + `done` | P2 fan-out | Ghostty |
| `wp_fractional_scale_manager_v1` / `wp_viewporter` / `wl_compositor` v6 | P4 globals | wayland-info |

Checks whose tools are missing degrade to `SKIP` rather than failing.

### Cursor ownership and backend targets

Cursor scaling has separate integration entry points so a failure identifies
the ownership/backend path instead of being hidden by the compositor-owned
Xcursor check above:

| Command | Target and oracle |
|---|---|
| `bash scripts/test-wayland-cursor-scaling.sh` | Native client cursor surface. A generated client consumes `preferred_scale`, renders a ceil-sized buffer through `wp_viewporter`, and verifies the exact 12–72px physical footprint over 0.5–3x. |
| `bash scripts/test-xwayland-cursor-scaling.sh` | X11 application cursor in both `legacy` and `native` XWayland scaling modes. A solid 24px Xcursor must render at 24/30/36/48/60/72px from 1–3x. Requires an Aqueous build with `-Dxwayland`. |
| `bash scripts/test-mixed-scale-cursor-crossing.sh` | One persistent cursor crosses 1.25x → 2.5x → 1.25x outputs. It verifies 30px → 60px → 30px and synchronizes against compositor-reported pointer coordinates before each capture. |
| `bash scripts/test-hardware-cursor-scaling.sh` | Real DRM cursor plane. The opt-in test queries the output service's read-only `cursor_state`, verifies hardware-plane ownership and exact buffer dimensions, and restores the original output scale. Set `AQUEOUS_HARDWARE_CURSOR_OUTPUT` to the output currently under the pointer. |

The mixed-scale test inspects the cursor-including capture directly. A prior
cursor-excluding capture can force a temporary hardware/software cursor-path
transition and would test screencopy exclusion state rather than boundary
scaling.

### Client-buffer policy integration (`bash scripts/test-client-buffer-scaling.sh`)

At output scale 1.25, a generated xdg-shell client asserts that
`preferred_scale(150)` precedes the initial root and popup configures under the
default policy. A second app ID matched only by the test fixture asserts the
same ordering for `preferred_scale(240)`. The fixture also contains optional
VSCodium and Shelly matchers for real-application smoke tests; it is never
loaded by default. Both policies are then exercised across a live 1.25 to 2.5
output-scale transition, including an already-created popup and subsurface, to
ensure later scene notifications retain and inherit the selected policy.

## Manual matrix

The headless tests validate exact compositor-owned, client-owned, XWayland,
and mixed-output cursor footprints using solid opaque fixtures and screencopy
with cursor overlay. A real DRM session remains necessary for the opt-in
hardware-plane test; theme-specific artwork and subjective visual crispness
remain manual checks.

| Axis | Values |
|---|---|
| Toolkits | `foot`, GTK3, GTK4 (`gtk4-demo`), Qt5, Qt6, Electron, `mpv`, Firefox, an SDL2 game (v5 / non-fractional regression) |
| Scales | 1.0, 1.25, 1.5, 1.75, 2.0, 3.0 |
| Scenarios | single output; dual output mixed scales; hot-plug at non-1 scale; fullscreen across scale change; layer-shell bar (waybar) across change; live output-socket change with running clients; Aqueous Display Settings end-to-end |
| Cursor (P5) | 24px@1×, 36px@1.5×, 48px@2×; live resize without pointer move; correct size per output across a mixed-scale boundary |

Per cell: ✅ crisp + correct size / ⚠️ soft (expected only for Xwayland) /
❌ regression.

### Aqueous end-to-end loop

An outputd-compatible socket client (`op: set` / `apply_profile`) →
the compositor's native validator (`[0.5, 3.0]`) → `OutputManager.zig`'s
atomic wlroots transaction → compositor log `commit affects layout` →
client redraw. (The former Noctalia v4 Quickshell `OutputControl.qml` consumer
has been retired; the daemon's socket protocol is unchanged.)

## Known limitations

- Managed Wayland windows use the P6 precise scene path. Layer-shell and
  override-redirect roots still use wlroots' integer scene placement; they are
  rendered on physical boundaries, but do not yet get fractional animation
  coordinates.
- Embedded Xwayland clients keep their own DPI story and stay at scale 1; soft
  rendering on a fractional output remains expected. Matching niri here also
  requires a native-resolution Xwayland strategy (such as its satellite
  process), which is independent of Wayland fractional scene placement.
- Headless pixel comparisons confirm cursor dimensions and resampling coverage,
  but subjective crispness for real theme artwork remains manual.
