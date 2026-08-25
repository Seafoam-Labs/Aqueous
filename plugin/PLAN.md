# Aqueous Settings Flyout — Noctalia v5 Plan

Status: implemented as `0.2.0`, including desktop typography synchronization and a visual output layout editor
Target: Noctalia v5 native Luau plugin system  
Provisional plugin id: `aqueous/settings`  
Provisional entries: `aqueous/settings:widget` and
`aqueous/settings:panel`

## 1. Goal

Build a polished, theme-native Noctalia flyout that lets an Aqueous user inspect
and edit compositor settings without opening the standalone Quark application
or hand-editing TOML.

The normal activation path is:

1. The user adds the Aqueous Settings widget to a Noctalia bar.
2. Clicking the widget toggles an attached settings panel near the widget.
3. The panel loads the effective Aqueous configuration into typed controls.
4. Changes remain as drafts until the user selects **Apply**.
5. Apply validates the complete candidate configuration, preserves unrelated
   TOML text and comments, writes atomically, and lets Aqueous hot-reload it.

The same flyout must also open through:

```sh
noctalia msg panel-toggle aqueous/settings:panel
```

## 2. Scope

### In scope

- A Noctalia v5 bar widget and declarative panel written in Luau.
- Typed controls for every recognized Aqueous configuration family.
- Desktop font family and point-size controls backed by an Aqueous-owned
  appearance sidecar and synchronized to Noctalia, GTK, GSettings, qt5ct, and
  qt6ct.
- A visual output canvas for dragging connected/configured monitors into place,
  choosing rotations and flips, and entering exact coordinates.
- Draft, validation, apply, reload, and conflict handling.
- Comment- and formatting-preserving updates.
- A bundled native helper that shares Aqueous-compatible path discovery and
  validation behavior.
- Local development, package installation, and automated tests.
- A raw/advanced view for unknown or newly introduced keys that the typed schema
  does not yet expose.

### Out of scope

- Noctalia v4 QML support.
- Replacing Aqueous TOML with a Noctalia-owned configuration format.
- Applying values continuously while a slider is dragged.
- Restarting or killing the compositor.
- KDE/Plasma-specific font configuration (`kdeglobals`, `kwriteconfig`, and
  Plasma reload services).
- Shipping remote telemetry or network access.

## 3. Architectural decision

Do not parse and rewrite Aqueous TOML directly in the panel script.

Noctalia v5 gives trusted Luau plugins filesystem and subprocess access, but its
generic `writeFile` replaces a whole file. Aqueous already has a
comment-preserving document editor, atomic replacement, and non-trivial path
discovery in `plugin/helper/src/config_document.zig`. Reimplementing those rules in the UI
would create two sources of truth and make external-edit conflicts difficult to
handle.

Instead, bundle a small executable named `aqueous-config` with the plugin. It
will expose a narrow JSON command interface and own:

- environment/XDG/config-sidecar path resolution;
- parsing and normalized values;
- the settings schema and validation constraints;
- comment-preserving patching;
- optimistic concurrency checks;
- atomic writes and structured errors.

The Luau panel owns only presentation and draft state.

```text
Bar click / IPC
       |
       v
Noctalia widget ---- togglePanel ----> Noctalia panel
                                          |
                                   runAsync + JSON
                                          |
                                          v
                                  aqueous-config
                              /          |            \
                    Aqueous TOML   appearance.toml   toolkit adapters
                     wm/layout…      source of truth  Noctalia/GTK/Qt
                         |
                  Aqueous hot reload
```

This keeps all new implementation under `plugin/`. Packaging changes elsewhere
in the repository should be limited to installing and seeding the completed
bundle.

Desktop typography is a synchronization layer rather than a compositor
rendering option. `appearance.toml` is owned by Aqueous, while the helper
applies its font to the formats consumed by each toolkit. Noctalia receives the
family directly and maps the point size relative to a 12 pt baseline through
its UI and default-bar scales. GTK receives `Family Size` through GSettings and
GTK 3/4 configuration. qt5ct and qt6ct receive their serialized general
`QFont`; fixed-width fonts remain untouched.

## 4. Target directory layout

```text
plugin/
├── README.md
├── PLAN.md
├── catalog.toml
├── settings/
│   ├── plugin.toml
│   ├── widget.luau
│   ├── panel.luau
│   └── translations/
│       └── en.json
├── helper/
│   ├── build.zig
│   ├── build.zig.zon
│   └── src/
│       ├── main.zig
│       └── schema.zig
├── tests/
│   ├── fixtures/
│   ├── test-all.sh
│   ├── test-helper.sh
│   ├── test-plugin.sh
│   └── test-noctalia.sh
└── packaging/
    ├── install.sh
    └── aqueous-settings.install
```

`lib/` is optional if the initial panel remains readable as one script. Split it
only after Noctalia's loader behavior for plugin-relative Luau modules is
verified.

## 5. Noctalia v5 integration

Use the native v5 format:

- `plugin.toml`, not `manifest.json`;
- `.luau` entry scripts, not QML entry points;
- a `[[widget]]` entry for activation;
- a `[[panel]]` entry for the flyout;
- `barWidget.*`, `panel.*`, `ui.*`, and `noctalia.*` runtime APIs.

Target `plugin_api = 9`. API 9 is the oldest level needed for Luau closures in
declarative control callbacks, which will make schema-generated rows practical.
Do not raise this to API 14 merely to declare widget gesture defaults; a normal
`onClick()` can call:

```luau
noctalia.togglePanel("aqueous/settings:panel")
```

Proposed panel defaults:

```toml
[[panel]]
id = "panel"
entry = "panel.luau"
width = 860
height = 720
placement = "attached"
position = "auto"
open_near_click = true
```

Noctalia injects placement, floating-position, and open-near-click preferences
into the plugin settings UI. The panel should use the default on-demand keyboard
focus and outside-click dismissal. The user can switch it to a centered floating
panel through Noctalia without an Aqueous-specific setting.

The widget should use the `adjustments-horizontal` glyph, an “Aqueous Settings”
tooltip, no polling interval, and no mutable state. A right click may open the
standalone `aqueous-settings` application later, but it is not required for the
first release.

Manifest dependencies should include `aqueous-config`. The panel must render a
clear installation error if the helper is absent rather than failing silently.

## 6. Flyout experience

### Layout

Use a compact two-column settings layout:

- Left rail: Overview, Appearance, Layouts, Input, Displays, Rules, Keybinds,
  Advanced.
- Main area: section title, concise help, grouped setting cards, and a vertical
  scroll region.
- Sticky footer: current status, **Discard**, and **Apply**.

At narrow/clamped widths, replace the left rail with a horizontal category row.
Use Noctalia palette roles and inherited typography; avoid hard-coded theme
colors.

### States

The entire surface must have explicit states:

- **Loading** — spinner/progress and “Reading Aqueous configuration”.
- **Ready** — controls reflect the last disk snapshot.
- **Dirty** — changed-field count and Apply enabled.
- **Validating/Applying** — controls disabled; one in-flight request.
- **Success** — short “Applied; Aqueous will hot-reload” confirmation.
- **Validation error** — inline field errors and a summary at the footer.
- **External change** — offer **Reload from disk** or **Review conflict**;
  never overwrite automatically.
- **Helper missing/incompatible** — show required helper version and an
  actionable package hint.

Closing the panel with drafts must not apply them. On the next open, either
restore the in-memory draft while Noctalia is running or ask whether to discard
it. Draft persistence across a Noctalia restart is not required for v1.

### Control mapping

| Schema type | Noctalia control |
| --- | --- |
| Boolean | `ui.toggle` |
| Bounded integer/double | `ui.slider` plus numeric `ui.input` |
| Enum | `ui.select` |
| Short string/path/command | `ui.input` |
| Color | hex input plus a color preview |
| Repeated table | keyed cards with Add, Duplicate, Reorder, Delete |
| Raw TOML | multiline `ui.input` with explicit validation |

Slider callbacks update drafts only. Apply happens from the footer so a drag
does not cause repeated disk writes or compositor re-layouts.

## 7. Settings coverage

The typed schema should be delivered in slices, while the Advanced editor keeps
all existing values reachable throughout development.

### Slice A — high-value core

- Effects: `[blur]`, `[opacity]`, `[workspace_transition]`.
- Geometry: `[struts]`, `[state]`, `[layout]`.
- Layout slots: `[layout.slots]`.
- Per-layout options for tile, monocle, grid, rows, dwindle, reverse-dwindle, scrolling, float,
  and game-mode; composable region tables remain available in the Advanced
  editor until a point/region control is added.
- Keyboard basics: XKB layout/variant/options and repeat rate/delay.
- Pointer basics: focus-follows-mouse and acceleration.
- Touchpad/mouse device options.

### Slice B — mappings and display policy

- `[[workspace]]` layout mappings.
- `[[output]]` identity, layout, enabled, mode, scale, transform, position,
  adaptive sync, HDR, and primary selection.
- `[display]` startup/reload/fallback policy.
- `[[display.profile]]` and `[[display.profile.output]]`.
- `outputs.toml` preferred declarative and persisted output state, with unset
  values inherited from legacy `wm.toml` output policy. The UI labels inherited
  values and writes display edits to `outputs.toml`.

### Slice C — behavior and automation

- `[actions]`.
- `[keybinds]` built-ins, chord lists, and unbound state.
- `[keybinds.custom]`.
- `[gestures]`.
- `[[exec]]` startup/reload processes.

### Slice D — rules

- `[game_mode]`.
- Ordered `[[window]]` rules with app_id/class/title matchers.
- Layout/workspace/floating/fullscreen/strut fields.
- Floating geometry.
- Game-mode anchor/size/scale.
- Blur and opacity overrides.
- Ready-to-paste rule import from `aqueousctl inspect --rule` as a later
  convenience.

### Slice E — advanced parity

- File chooser across `wm.toml`, `layout.toml`, `input.toml`, `outputs.toml`,
  and `rules.toml`.
- Unknown table/key editor.
- Raw TOML editor with parse/validation result before Apply.
- Resolved file path and source-precedence explanation.

## 8. Helper protocol

The helper should be deterministic and script-friendly.

### Commands

```text
aqueous-config version --json
aqueous-config snapshot --json
aqueous-config validate --request <absolute-json-file>
aqueous-config apply --request <absolute-json-file>
aqueous-config raw --file <logical-name> --json
```

No user-entered value is interpolated into the shell command. The panel writes a
request JSON file beneath `noctalia.pluginDataDir()`, shell-quotes only that
plugin-owned path, and reads captured stdout from `noctalia.runAsync`.

### Snapshot response

The snapshot should include:

```json
{
  "protocol": 1,
  "generation": "sha256-of-resolved-paths-and-file-bytes",
  "files": {
    "wm": {"path": "/home/user/.config/aqueous/wm.toml", "writable": true}
  },
  "groups": [],
  "values": {},
  "collections": {},
  "warnings": []
}
```

Schema field records need a stable id, file, table/key selector, label and help
translation keys, type, default/effective/configured values, constraints,
advanced flag, and dependency visibility rules.

### Apply request

```json
{
  "protocol": 1,
  "expected_generation": "...",
  "changes": [
    {"id": "blur.enabled", "value": true},
    {"id": "layout.options.scrolling.column_fraction", "value": 0.55}
  ]
}
```

The helper validates every change and the combined candidate snapshots before
writing. A successful response returns the new generation and normalized
values. Errors use stable codes such as `invalid_value`, `unknown_field`,
`external_change`, `permission_denied`, and `partial_write`.

For repeated tables, use stable operation records (`add`, `update`, `move`,
`delete`) keyed by a snapshot-local record id. Never let the UI address a
repeated table only by its visible array index after an external reload.

## 9. Data integrity and safety requirements

- Preserve comments, ordering, whitespace, unknown sections, and unknown keys
  when changing a typed field.
- Resolve the same environment variables and sidecar paths as the compositor.
- Refuse an apply when the disk generation differs from the one loaded by the
  panel.
- Validate bounds and enums before creating any replacement file.
- Create all replacement files first, sync them, then rename them.
- Keep a timestamped last-known-good backup only when more than one file is
  changed in a batch; retain a small bounded count in the plugin data directory.
- Never write `/etc/xdg` files. If the effective source is system-owned, create
  an explicit user override after user confirmation.
- Return permission and validation failures without clearing the user's draft.
- Do not invoke a shell with raw commands, paths, rule matchers, or keybind
  values supplied by the user.
- Cap file and JSON sizes consistently with the existing 1 MiB config limit.
- Treat Aqueous hot reload as the apply mechanism; do not signal or restart it.

## 10. Implementation milestones

### Milestone 0 — contract and fixtures

- Freeze protocol version 1 and schema ids.
- Add fixtures covering comments, quoted `#`/`=`, repeated tables, absent files,
  XDG overrides, sidecar paths, and external-edit conflicts.
- Decide the final plugin id and author string before a manifest is published.

Exit: protocol examples round-trip in tests and every existing config file has a
fixture.

### Milestone 1 — read-only vertical slice

- Scaffold the v5 manifest, widget, panel, translation file, and helper.
- Widget toggles the panel.
- Panel loads the helper snapshot and renders Overview plus resolved paths.
- Implement loading, empty, missing-helper, and parse-error states.

Exit: local Noctalia v5 discovers the plugin; widget click opens an attached
flyout showing the current Aqueous values without modifying disk.

### Milestone 2 — safe core editing

- Implement document patching, validation, generation checks, and atomic apply.
- Render Slice A typed controls.
- Add draft count, Discard, Apply, inline errors, and success state.

Exit: effects, layout, and input values can be edited without changing comments
or unrelated TOML, and an external edit blocks Apply.

### Milestone 3 — collections

- Add repeated-table protocol operations and keyed card components.
- Deliver displays, profiles, workspace mappings, actions, keybinds, gestures,
  and exec blocks.
- Add reorder confirmation where order changes behavior.

Exit: Slice B and C configuration round-trips with stable ordering and complete
validation.

### Milestone 4 — rule editor and advanced parity

- Deliver the rule builder, rule ordering, raw/unknown setting editor, and
  full-file validation.
- Add optional rule import from `aqueousctl inspect --rule`.

Exit: every setting reachable in the current standalone editor is reachable
from the flyout, with recognized settings presented as typed controls.

### Milestone 5 — package and release

- Install `aqueous-config` on `PATH`.
- Install the plugin into a Noctalia local/source-compatible location without
  enabling it behind the user's back.
- Add the plugin to Aqueous package manifests and documentation.
- Capture screenshots and write user-facing installation/configuration docs.

Exit: a clean Aqueous package install can enable the plugin from Noctalia
Settings, add its widget to a bar, and use the full flyout.

## 11. Test plan

### Helper unit tests

- Parse, enumerate, add, update, move, and delete ordinary/repeated tables.
- Preserve comments, formatting, quoted delimiters, and unrelated settings.
- Validate every numeric range and enum in the typed schema.
- Resolve HOME, XDG variables, AQUEOUS variables, and configured sidecars.
- Detect stale generations.
- Verify atomic replacement and failure cleanup.
- Verify system-owned sources are never overwritten.

### Protocol tests

- Golden JSON snapshots and apply responses.
- Unknown protocol, field, operation, and malformed JSON failures.
- Unicode and shell-metacharacter values remain data, never command text.
- Multi-file request behavior and backup restoration.

### Plugin tests

- Widget click and external IPC both open the same panel.
- Every category renders at 1× and fractional UI scale.
- Keyboard navigation, focus, Enter submission, Escape dismissal, and scroll.
- Drafts survive category changes and are cleared only by Discard/successful
  Apply.
- Slow helper, missing helper, invalid JSON, permission failure, and external
  conflict states.
- Attached and floating panel placement on horizontal/vertical bars and multiple
  outputs.

### End-to-end tests

- Run a nested Aqueous session with temporary XDG/HOME roots.
- Enable the path-source plugin in Noctalia v5.
- Change one setting from each file and observe Aqueous's hot reload.
- Confirm invalid candidates do not replace the active validated snapshot.
- Confirm a concurrent manual TOML edit is preserved and reported as a conflict.

## 12. Acceptance criteria

The first stable release is complete when:

- it uses Noctalia v5 `plugin.toml` + Luau entries and contains no v4 QML API;
- the widget and IPC activation open a native Noctalia panel;
- all current Aqueous configuration families are represented by typed or
  advanced controls;
- edits are drafts until Apply;
- comments, formatting, unknown values, and external edits are protected;
- no compositor restart is needed;
- errors are actionable and never discard the draft;
- the plugin works on multiple outputs and with attached/floating placement;
- helper, protocol, preservation, and end-to-end tests pass.

## 13. Known risks

- Noctalia v5's plugin system is still beta. Pin the tested beta release/API
  range in release notes and run compatibility smoke tests before each release.
- Legacy `wm.toml` display policy and preferred `outputs.toml` policy can both
  be present. The UI must expose inherited values without writing migrations
  until the user actually changes a display setting.
- A schema maintained separately from compositor parsers can drift. Add a
  coverage test that compares known schema keys with the parser sources, and
  make unknown keys visible in Advanced.
- Multi-file atomicity is not guaranteed by filesystem rename alone. Prefer
  small single-file applies; for true batches, stage every candidate and keep a
  recoverable transaction record.

## 14. Noctalia references used

- [Plugin development overview](https://docs.noctalia.dev/v5/plugins/development/)
- [Manifest and settings](https://docs.noctalia.dev/v5/plugins/development/manifest/)
- [Entry scripts](https://docs.noctalia.dev/v5/plugins/development/entries/)
- [Declarative UI and panels](https://docs.noctalia.dev/v5/plugins/development/declarative-ui/)
- [Runtime, subprocess, and filesystem APIs](https://docs.noctalia.dev/v5/plugins/development/runtime-api/)
- [Plugin API versions](https://docs.noctalia.dev/v5/plugins/development/plugin-api/)
- [Local development and publishing](https://docs.noctalia.dev/v5/plugins/development/workflow/)
