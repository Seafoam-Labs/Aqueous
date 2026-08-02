# Window and layer rules (`rules.toml`)

Aqueous reads per-application placement rules from a sibling file to `wm.toml`:
`~/.config/aqueous/rules.toml`. The file is optional - if it's missing, rules
are simply disabled and Aqueous behaves identically to a release without the
feature.

See `rules.toml.example` at the repo root for a copy-pasteable template.

## Discovery order

The first hit wins:

1. `$AQUEOUS_RULES` environment variable (absolute path)
2. `[rules].path = "..."` in `wm.toml`
3. `$XDG_CONFIG_HOME/aqueous/rules.toml`
4. `~/.config/aqueous/rules.toml`

Categories 1 and 2 are returned verbatim even when the file doesn't exist (so
typos surface as a warning rather than silently disappearing). Categories 3
and 4 are only returned when the file is present on disk.

## Reload semantics

- Aqueous monitors `rules.toml` on the Wayland event loop. A changed file is
  parsed into a replacement snapshot. Every managed window and existing layer
  surface is re-evaluated without restarting the compositor.
- `Super+R` (the existing `reload_config` builtin) requests the same reload
  immediately for `wm.toml`, `layout.toml`, `input.toml`, and `rules.toml`.
- `reload_rules` is a standalone builtin verb that reloads **only** rules.toml.
  Default: unbound. Bind via:

  ```toml
  [keybinds]
  reload_rules = "Super+Shift+R"
  ```

- A parse error or missing file does not crash Aqueous. The previous rule list
  is kept and a single warn line is logged.

## Schema

### `[game_mode]`

Options for the `game-mode` layout engine. Only consulted when at least one
`[[window]]` rule below targets `layout = "game-mode"`.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `remainder_layout` | string | `"grid"` | Layout used to tile non-anchor windows. Invoked once per non-empty side column with its own state. One of `tile`, `monocle`, `grid`, `rows`, `dwindle`, `reverse-dwindle`, `scrolling`, or `float`. |
| `gaps_inner` | int | `8` | Pixel gap between tiles inside each side column. |
| `fallback_layout` | string | `"grid"` | Layout used on outputs that have no anchor window. Accepts the same non-game-mode layouts as `remainder_layout`. |

### `[[window]]`

An array-of-tables, one entry per rule. First match wins; declaration order
matters.

| Key | Type | Required | Description |
| --- | --- | --- | --- |
| `app_id` | string (glob) | one of `app_id` / `class` / `title` must be set | Match `xdg_toplevel.app_id`. |
| `class` | string (glob) | " | Match X11 `WM_CLASS` through Aqueous's native XWayland integration. |
| `title` | string (glob) | " | Match `xdg_toplevel.title`. |
| `layout` | string | no | Select a built-in layout, including `composable`; `"float"` also marks the window floating. |
| `floating` | bool | no | Force floating placement. |
| `workspace` | integer | no | Move the window to the numbered workspace. Workspace numbers are 1-based. |
| `width`, `height` | integer | no | Floating placement dimensions. |
| `x`, `y` | integer | no | Floating placement coordinates. |
| `anchor` | string | no (default `center`) | `center` / `top` / `bottom` / `left` / `right`. |
| `size` | string | no (default `"native"`) | `"native"` (use the client's requested buffer) / `"WxH"` (exact pixels) / `"FxF"` (fractions of the output's usable area, 0..1). |
| `scale` | double | no (default `1.0`) | Multiplied into the resolved size before clamping. |
| `fullscreen` | bool | no (default `false`) | When `true`, the rule attaches but is NOT treated as an anchor - use the normal `toggle_fullscreen` path for true exclusive fullscreen instead. |

### `[[layer]]`

An array-of-tables for layer-shell surfaces. First match wins and declaration
order matters.

| Key | Type | Required | Description |
| --- | --- | --- | --- |
| `namespace` | string (glob) | yes | Match the layer-shell namespace. |
| `blur` | bool | no (default `false`) | Blur the rectangular bounds of the main layer surface. |
| `blur_popups` | bool | no (default `false`) | When `blur` is also true, blur the rectangular bounds of every XDG popup and nested popup owned by the layer surface. |

Global backdrop blur must also be enabled under `[blur]` in `wm.toml`.
Main surfaces and popups currently use rectangular bounds; their pixel alpha
is not used as a blur mask.

```toml
[[layer]]
namespace = "waybar"
blur = true
blur_popups = true
```

Run `aqueousctl scene` while the surface is mapped to discover its namespace;
layer roots are labeled `layer surface: NAMESPACE`. Layer-owned popup roots and
blur checkpoints are labeled `layer XDG popup` and
`layer popup backdrop blur marker`.

## Game-mode layout pattern

Given a 2560x1440 monitor and a 1920x1080 game with `size = "native"`,
`anchor = "center"`:

```
+--------+--------------------------------+---------------+
|        |                                |               |
|  LEFT  |       ANCHOR (game)            |    RIGHT      |
| COLUMN |        1920 x 1080             |    COLUMN     |
|  320   |     centered at (320, 180)     |    320        |
| x1440  |                                |    x1440      |
|        |                                |               |
+--------+--------------------------------+---------------+
```

The space around the anchor is exposed as **two full-height side columns**:
the left column (from `usableArea.X` up to `anchorRect.X`) and the right
column (from `anchorRect.Right` up to `usableArea.Right`). Non-anchor windows
are partitioned across the two columns via stable round-robin over the
visible-window order (even index -> left, odd -> right), and `remainder_layout`
is invoked once per non-empty column with its own fresh instance. Top/bottom
strips above and below the anchor are intentionally unused. Column count is
fixed at 2 and is not configurable.

If the anchor is flush against an edge (e.g. `anchor = "left"`), the
corresponding side column collapses to zero width and all non-anchor windows
fall into the surviving column.

On a 7680x2160 monitor with a 3840x2160 centered anchor, top and bottom strips
have zero height (the anchor is full-height) and are unused; non-anchor windows
split round-robin between the left column `(0, 0, 1920, 2160)` and the right
column `(5760, 0, 1920, 2160)`.

## Deprecation: `[layout.options.game-mode]` in `wm.toml`

The early game-mode design put these options under `[layout.options.game-mode]`
in `wm.toml`. They have moved to `[game_mode]` in `rules.toml` so they can be
hot-reloaded independently of keybinds. The legacy location is detected at
parse time and produces a single warn log:

```
[layout.options.game-mode] in wm.toml is deprecated - game-mode options live
in rules.toml under [game_mode]. Values here are ignored. See docs/rules.md.
```

Two-release deprecation window - after which the warning becomes an error.

## Troubleshooting

- **Rule didn't apply.** Run `aqueousctl inspect --rule` for ready-to-paste
  matchers, or `aqueousctl windows --json` for the complete window snapshot.
  Wayland app IDs and XWayland classes are case-sensitive.
- **Layer rule didn't apply.** Run `aqueousctl scene` and use the namespace
  shown in the `layer surface: ...` label. Namespace globs are case-sensitive.
- **Anchor doesn't update when I edit `rules.toml`.** Check the compositor log
  for a parse warning, or press `Super+R` to request an immediate reload.
- **Game mode disappears when I close the game.** Expected - with no
  matching window on the output, `game-mode` falls through to
  `fallback_layout`.
