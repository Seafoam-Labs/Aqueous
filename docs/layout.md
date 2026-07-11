# Layouts

Aqueous ships eight in-process layout engines:

- `tile` — master/stack tiling.
- `monocle` — one window fills the usable area.
- `grid` — balanced rows and columns.
- `rows` — horizontal rows.
- `dwindle` — alternating recursive splits.
- `scrolling` — horizontally scrolling columns.
- `float` — free placement using remembered/native geometry.
- `game-mode` — an anchor window with remaining windows arranged beside it.

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
