# Layouts

Aqueous ships ten in-process layout modes:

- `tile` — master/stack tiling.
- `monocle` — one window fills the usable area.
- `grid` — balanced rows and columns.
- `rows` — horizontal rows.
- `dwindle` — alternating recursive splits.
- `reverse-dwindle` — a horizontal mirror of dwindle, splitting from the right and top.
- `scrolling` — horizontally scrolling columns.
- `float` / `stacking` — a full stacking layout with remembered geometry,
  workspace-local z-order, MRU focus, constrained movement/resizing, snapping,
  custom normalized zones, and KDE/labwc-style placement policies.
- `game-mode` — an anchor window with remaining windows arranged beside it.
- `composable` — up to four independently stateful layouts assigned to fixed
  monitor regions.

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
prefer_vertical_on_portrait = "false"
focus_follows_mouse_delay_ms = 0

[layout.options.stacking]
placement = "minimal-overlap"
move_step = 10
move_step_coarse = 50
resize_step = 10
snap_threshold = 24
resistance = 12

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

## Stacking snap layouts

Named snap layouts apply only when the workspace's effective layout is
`stacking` (the `float` and `floating` names remain compatibility aliases).
They do not promote tiled windows or affect persistent floating overlays on a
tile, grid, scrolling, composable, monocle, or game-mode workspace.

```toml
[layout]
default = "stacking"
snap_layout = "work"

[layout.snap-layout.work]
name = "Work"
padding = 8

[layout.snap-layout.work.zone.editor]
name = "Editor"
x = 0.0
y = 0.0
width = 0.6666667
height = 1.0

[layout.snap-layout.work.zone.terminal]
name = "Terminal"
x = 0.6666667
y = 0.0
width = 0.3333333
height = 1.0
```

Zone rectangles use normalized coordinates in the strut-adjusted usable area.
During a stacking move, reaching an output edge within `snap_threshold` shows
an input-inert preview of the active layout. The pointer selects a zone using
its unpadded rectangle; releasing commits the padded geometry. Moving away
from the edge hides the preview and preserves ordinary free movement.

The active named layout is tracked independently for each output at runtime.
Use custom bindings to address stable layout and zone IDs or cycle the current
output's layouts:

```toml
[keybinds]
cycle_snap_layout = "Super+Ctrl+Bracketright"
cycle_snap_layout_reverse = "Super+Ctrl+Bracketleft"
cycle_snap_zone = "Super+Ctrl+backslash"

[keybinds.custom]
"Super+Ctrl+1" = "builtin:set_snap_layout:work"
"Super+Ctrl+2" = "builtin:snap_zone:work/editor"
```

Legacy `[layout.snap-zone.a]` through `.d` tables and
`builtin:snap_zone:a` remain supported when no named layouts are configured.

## Tile resize

`Super`+right-drag resizes a tile member without making it floating.
The dominant axis of the first non-tied pointer movement locks the resize for
the rest of that drag. A horizontal drag moves the master/stack split shared by
every member; a vertical drag changes only the selected member's height within
its column, while unmodified members share the remaining space. The split
persists as a ratio of the usable area, so it survives output mode changes and
applies to tile regions inside composable layouts. `Super`+double-left-click
restores the configured `master_ratio` and the selected member's default even
column height. Other members retain their independent height overrides.

## Composable layouts

The composable layout divides the strut-adjusted usable monitor area into one
to four named regions, `a` through `d`. Each region selects a leaf layout and a
rectangle described by four normalized `[x, y]` points:

```toml
[layout]
default = "composable"

[layout.composable.a]
layout = "tile"
p1 = [0.0, 0.0] # top-left
p2 = [0.5, 0.0] # top-right
p3 = [0.5, 1.0] # bottom-right
p4 = [0.0, 1.0] # bottom-left

[layout.composable.b]
layout = "scrolling"
p1 = [0.5, 0.0]
p2 = [1.0, 0.0]
p3 = [1.0, 1.0]
p4 = [0.5, 1.0]
```

Coordinates range from `0.0` to `1.0` relative to the usable area, so the
configuration follows output resolution and scale changes. Points must be in
clockwise top-left, top-right, bottom-right, bottom-left order and describe a
non-zero axis-aligned rectangle. Regions may touch or leave gaps, but cannot
overlap. Arbitrary quadrilaterals are not accepted because Aqueous placement
and clipping operate on rectangles. If any configured region is incomplete or
invalid, composable mode safely falls back to `tile` over the whole usable
area.

A region may use `tile`, `monocle`, `grid`, `rows`, `dwindle`,
`reverse-dwindle`, `scrolling`, or `float`. Recursive `composable` children and
`game-mode` children are rejected.
Each region owns independent order, scrolling viewport, and floating geometry.
Child gaps and borders come from that child layout's existing
`[layout.options.<id>]` section.

A composable region is considered focused whenever any window assigned to it
has keyboard focus. That region becomes active, and newly managed windows join
it. Membership persists across rearrangement and focus changes. Pointer and
scrolling operations are delegated to the member's child layout; dropping a
window on a different region exchanges the two windows' region membership.
Floating child windows are constrained to their region.

Custom bindings can focus the last-focused window in a region or move the
focused tiled window into one:

```toml
[keybinds.custom]
"Super+Alt+1"       = "builtin:focus_composable:a"
"Super+Alt+Shift+1" = "builtin:move_to_composable:a"
```

The action argument accepts `a` through `d`, with `1` through `4` as aliases.
An empty region has no focus target. Moving a window into a region makes that
region active and requests an immediate rearrangement.

## Scrolling columns

The scrolling engine owns an ordered list of columns. By default, new windows
begin in their own column, preserving horizontal placement. Setting
`prefer_vertical_on_portrait = true` adds future windows to the bottom of the
active column whenever that scrolling instance's local usable rectangle is
taller than it is wide. Square and landscape instances remain horizontal.
This local check also applies independently to composable regions and game-mode
remainders; changing the option does not regroup existing windows.
Several windows arriving in one update are appended in input order. The target
is the column containing the instance's current focus, then its previously
focused member's column, then the last surviving column. `follow_new_windows`
reveals the final appended member in that column. Consume, expel, move, and
drag/drop actions remain explicit overrides and can still create or rearrange
columns after this initial placement.

By default every member's complete footprint, including its outward border,
retains the full column viewport height, so multi-window columns form vertical
stacks instead of shrinking members to fit. Inner gaps measure the clear pixels
between neighboring border outlines. A manually resized member may use a
shorter or taller explicit content height. Each column keeps an independent
vertical viewport.
Horizontal viewport movement operates on columns; left/right focus moves
between columns and up/down focus moves within a column. Focusing a clipped
member automatically reveals it.

With `center_focused = false`, horizontal navigation pans only when the target
column would otherwise be clipped. A column fraction of `0.5` therefore keeps
two columns together in the viewport, and smaller fractions can expose more.
The viewport also removes blank edge overscroll in this mode so all available
space can be used by columns.

When global `input.focus_follows_mouse` is enabled,
`focus_follows_mouse_delay_ms` delays focus caused by real pointer motion over
a scrolling member. Keyboard viewport navigation and pointer clicks still
focus immediately, and moving away cancels the pending request. The delay also
applies to scrolling remainders in game mode; zero preserves immediate focus.

The default column-management bindings are:

- `Super+Ctrl+J` consumes the first window from the column on the right into
  the bottom of the focused column.
- `Super+Ctrl+K` expels the focused member into a new column on the right.
- `Super+Shift+Z` toggles full viewport width for the focused window's column.
- `Super+Shift+Left/Right` moves the focused window into the adjacent column,
  creating a vertical stack. At an edge with no adjacent column, a stacked
  member is expelled into a new column in that direction. `Super+Shift+Up/Down`
  reorders it within a stack.
- The same window-movement semantics apply when `game-mode` uses a scrolling
  remainder or scrolling fallback; the game anchor itself remains immovable.
- `Super+Shift+H/L` moves the whole focused column without merging it.
- `Super+Up/Down` scrolls the focused column by one member without changing
  keyboard focus.

The vertical scroll wheel provides the same viewport navigation while a
scrolling-capable window is focused. Hold the configured primary modifier
(`Super` by default) and scroll up/down to move the viewport left/right by
column. Add Alt (`Super+Alt+wheel` by default) to move up/down through the
focused column. When `AQUEOUS_MOD=Alt`, Super becomes the additional modifier,
so the vertical chord remains `Alt+Super+wheel`. Wheel down moves right or down;
wheel up moves left or up, with per-device `natural_scroll` reversing those
directions automatically.

When `prefer_vertical_on_portrait` arranges the focused instance vertically,
the two chords swap axes for that instance: the primary modifier chord moves
up/down through the focused column, and the additional modifier chord pans
left/right by column.

One physical wheel notch produces one navigation step, including on
high-resolution wheels; touchpad scrolls accumulate before stepping. Captured
scrolls do not leak into the focused application, even at a viewport edge.
Tile, floating, game anchors, overview, interactive drags, Xwayland keyboard
grabs, unmatched modifier combinations, and physical horizontal-wheel events
continue through the normal input path.

With `Super` held, left-drag a tiled window over the top or bottom third of
another window to stack it before or after that window. Dropping over the
middle-left or middle-right creates an adjacent column. A full-width flag is
owned by the window that triggered it, but all members share their column's
horizontal width.

`Super`+right-drag resizes a scrolling member without making it floating.
The dominant axis of the first non-tied pointer movement locks the resize for
the rest of that drag. Horizontal motion changes the whole column's width;
vertical motion changes only the selected member's height. This works
identically in a scrolling game mode remainder or fallback, while the game
anchor remains fixed. Beginning a horizontal resize replaces the column's
full-width preset with the dragged size; a vertical resize preserves it.
`Super`+double-left-click restores the configured column width and the
selected member's default full-viewport height.
