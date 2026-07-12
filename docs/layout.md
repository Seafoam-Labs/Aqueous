# Layouts

Aqueous ships nine in-process layout engines:

- `tile` — master/stack tiling.
- `monocle` — one window fills the usable area.
- `grid` — balanced rows and columns.
- `rows` — horizontal rows.
- `dwindle` — alternating recursive splits.
- `scrolling` — horizontally scrolling columns.
- `float` — free placement using remembered/native geometry.
- `game-mode` — an anchor window with remaining windows arranged beside it.
- `canvas` — free placement in a pannable, zoomable per-workspace world.

The global default and shared options can be placed in `wm.toml` or the
optional `layout.toml` overlay. `layout.toml.example` documents discovery,
merge precedence, slots, per-layout options, and workspace overrides.

```toml
[layout]
default = "tile"
gaps_outer = 8
gaps_inner = 4
master_ratio = 0.55
master_count = 1

[layout.options.scrolling]
column_fraction = "0.5"
center_focused = "true"

[[workspace]]
workspace = 2
layout = "monocle"
```

Resolution order is: a runtime layout-slot action, an output/workspace
override, a workspace-only override, an output default, then the global
default. Geometry is calculated from the output's strut-adjusted usable area,
then gaps, borders, size constraints, fullscreen, floating, and rule placement
are applied by the native manage cycle.

The compositor monitors configuration on its Wayland event loop. Changes are
loaded as a new validated snapshot and trigger a manage cycle; the configured
reload binding can also request an immediate reload.

## Canvas interaction

Canvas is opt-in and does not replace any existing layout or binding:

```toml
[layout]
default = "canvas"
```

- Right-drag empty canvas space to pan. Right-clicks over application surfaces
  continue to be delivered to the application.
- Hold the primary modifier and left-drag a canvas window to move it in world
  space without converting it to a floating window.
- Hold the configured primary modifier (Super by default) and use the vertical
  mouse wheel to zoom about the pointer.
- Keyboard bindings may invoke `builtin:canvas_zoom_in`,
  `builtin:canvas_zoom_out`, or `builtin:canvas_zoom_reset`.

Camera and window-world state are retained independently for every
output/workspace pair. Wayland clients remain configured at their logical
canvas size while the compositor scales their presentation. Fullscreen,
maximized, floating, layer-shell, and XWayland surfaces retain their existing
output-coordinate behavior.
