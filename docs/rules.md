# Window rules (`rules.toml`)

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

- `Super+R` (the existing `reload_config` builtin) reloads both `wm.toml` and
  `rules.toml`. Every managed window is re-evaluated against the new rule
  list, and any window whose placement actually changed triggers one batched
  layout pass.
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
| `remainder_layout` | string | `"grid"` | Layout used to tile non-anchor windows into the surrounding band. One of `tile`, `grid`, `monocle`, `scrolling`, `float`. |
| `gaps_inner` | int | `8` | Pixel gap between tiles in the remainder. |
| `fallback_layout` | string | `"grid"` | Layout used on outputs that have no anchor window. |

### `[[window]]`

An array-of-tables, one entry per rule. First match wins; declaration order
matters.

| Key | Type | Required | Description |
| --- | --- | --- | --- |
| `app_id` | string (glob) | one of `app_id` / `class` / `title` must be set | Match `xdg_toplevel.app_id`. |
| `class` | string (glob) | " | Match X11 `WM_CLASS` (via `xwayland-satellite`). |
| `title` | string (glob) | " | Match `xdg_toplevel.title`. |
| `layout` | string | yes | Currently only `"game-mode"` is honored. |
| `anchor` | string | no (default `center`) | `center` / `top` / `bottom` / `left` / `right`. |
| `size` | string | no (default `"native"`) | `"native"` (use the client's requested buffer) / `"WxH"` (exact pixels) / `"FxF"` (fractions of the output's usable area, 0..1). |
| `scale` | double | no (default `1.0`) | Multiplied into the resolved size before clamping. |
| `tag` | int | no | Optional 1..9. On manage_start, also move the window to this tag. |
| `fullscreen` | bool | no (default `false`) | When `true`, the rule attaches but is NOT treated as an anchor - use the normal `toggle_fullscreen` path for true exclusive fullscreen instead. |

## Game-mode layout pattern

Given a 2560x1440 monitor and a 1920x1080 game with `size = "native"`,
`anchor = "center"`:

```
+--------------------------------------------------------+
|                  TOP BAND (2560 x 180)                  |  <- remainder
+--------+--------------------------------+---------------+
|        |                                |               |
|  LEFT  |       ANCHOR (game)            |    RIGHT      |
|  320   |        1920 x 1080             |    320        |
| x1080  |     centered at (320, 180)     |   x1080       |
|        |                                |               |
+--------+--------------------------------+---------------+
|                  BOTTOM BAND (2560 x 180)               |
+--------------------------------------------------------+
```

The four bands surrounding the anchor are evaluated by area. v1 returns the
**single largest** as the remainder rect, which is then tiled by
`remainder_layout` (default `grid`). Zero-area bands (e.g. a full-height anchor
on an ultrawide) are excluded from contention. Ties are broken in the order
**top -> bottom -> left -> right**.

On a 7680x2160 monitor with a 3840x2160 anchor, top and bottom bands have zero
height and drop out; the contest reduces to left vs. right, and the left band
wins on the tie-break. The right band is unused in v1 - v2 may ship multi-band
(L-shape) tiling.

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

- **Rule didn't apply.** Confirm the window's actual `app_id` via the River
  log (Aqueous writes `window 0x... app_id=<name>` on every change). Wayland
  app ids are case-sensitive; X11 clients route their `WM_CLASS` through
  `xwayland-satellite`.
- **Anchor doesn't update when I edit `rules.toml`.** Press `Super+R` (or
  bind `reload_rules`). Aqueous does not watch the file automatically.
- **Game mode disappears when I close the game.** Expected - with no
  matching window on the output, `game-mode` falls through to
  `fallback_layout`.
