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

## Scrolling columns

The scrolling engine owns an ordered list of columns. New windows begin in
their own column. Every member retains at least the full column viewport
height, so multi-window columns form vertical stacks instead of shrinking
members to fit. Each column keeps an independent vertical viewport.
Horizontal viewport movement operates on columns; left/right focus moves
between columns and up/down focus moves within a column. Focusing a clipped
member automatically reveals it.

The default column-management bindings are:

- `Super+Ctrl+J` consumes the first window from the column on the right into
  the bottom of the focused column.
- `Super+Ctrl+K` expels the focused member into a new column on the right.
- `Super+Shift+Z` toggles full viewport width for the focused window's column.
- `Super+Shift+Left/Right` moves the focused window into the adjacent column,
  creating a vertical stack; `Super+Shift+Up/Down` reorders it within a stack.
- The same window-movement semantics apply when `game-mode` uses a scrolling
  remainder or scrolling fallback; the game anchor itself remains immovable.
- `Super+Shift+H/L` moves the whole focused column without merging it.
- `Super+Up/Down` scrolls the focused column by one member without changing
  keyboard focus.

With `Super` held, left-drag a tiled window over the top or bottom third of
another window to stack it before or after that window. Dropping over the
middle-left or middle-right creates an adjacent column. A full-width flag is
owned by the window that triggered it, but all members share their column's
horizontal width.
