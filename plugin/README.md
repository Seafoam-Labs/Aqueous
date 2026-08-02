# Aqueous Settings for Noctalia v5

A native Noctalia v5 flyout for configuring the Aqueous compositor.

The plugin adds an **Aqueous** bar widget. Clicking it opens an attached,
theme-native panel with typed controls for effects, layouts, input, display
policy, Game Mode, and built-in action commands. The Displays page includes a
visual monitor canvas: drag monitor cards relative to one another, select
their rotation or flipped orientation, and use exact X/Y fields when needed.
The canvas uses a common scale, so monitor rectangles reflect their relative
logical resolutions and expand to use the available preview area. Connected
monitors appear even before they have an `[[output]]` block. Changes remain
drafts until **Apply**, which writes overrides to the corresponding output
entries in `outputs.toml`. Inherited `wm.toml` entries remain visible until
edited. The Advanced page exposes the complete `wm.toml`, `layout.toml`,
`input.toml`, `outputs.toml`, and `rules.toml` files, so ordered output blocks,
workspace mappings, window rules, custom keybindings, gestures, and startup
commands are all editable.

The **Keybinds** page lists all built-in Aqueous shortcuts, including actions
that are currently unbound. A shortcut field accepts comma-separated chords.
Configured `[keybinds.custom]` entries expose both their chord and command, and
the action-command section controls the commands invoked by launcher, terminal,
screenshot, and lock bindings.

This is a v5 plugin: it uses `plugin.toml`, Luau entry scripts, and declarative
`ui.*` controls. It does not contain the v4 QML plugin API.

## Components

- `settings/` — the Noctalia widget, panel, manifest, and translations; v5 maps the `aqueous/settings` ID to its second path segment.
- `catalog.toml` — the v5 source index for `aqueous/settings`.
- `helper/` — `aqueous-config`, a small Zig helper used by the panel.
- `tests/` — document/protocol fixtures and Noctalia manifest checks.
- `packaging/` — system and local-development installation helpers.
- `PLAN.md` — the design and milestone record that drove the implementation.

The helper reuses Aqueous's existing settings document backend. It resolves the
same environment/XDG/sidecar paths, preserves comments and unrelated text,
validates known typed values, checks for external changes, and uses atomic file
replacement. Multi-file changes are backed up before writing. If the effective
file is under `/etc/xdg`, Apply creates a user override instead of modifying the
system file.

## Build and test

Zig 0.16 or newer, Noctalia v5, Python 3, `jq`, and `rg` are required for the
complete test suite.

```sh
cd plugin/helper
ZIG_GLOBAL_CACHE_DIR=/tmp/aqueous-plugin-zig-global \
ZIG_LOCAL_CACHE_DIR=/tmp/aqueous-plugin-zig-local \
zig build

cd ..
./tests/test-all.sh
```

The resulting helper is `helper/zig-out/bin/aqueous-config`.

## Local development

The development installer builds the helper, installs it to
`${XDG_BIN_HOME:-$HOME/.local/bin}`, registers this `plugin/` directory as a
Noctalia path source, and enables the plugin:

```sh
./packaging/dev-install.sh
```

Then add `Aqueous Settings` from Noctalia's bar widget picker. Luau edits
hot-reload; after manifest edits run:

```sh
noctalia msg plugins update aqueous-dev
```

Open the panel without a widget:

```sh
noctalia msg panel-toggle aqueous/settings:panel
```

Open the **Displays** page to arrange outputs. Drag monitors relative to one
another, choose their orientation below the canvas, then select **Apply**. The
X/Y controls allow precise coordinates. Offline configured outputs remain
visible and are labeled.

The plugin's helper path is configurable under Settings → Plugins → Aqueous
Settings → Advanced.

## System packaging

The packaging installer respects `DESTDIR` and `PREFIX`:

```sh
DESTDIR="$pkgdir" PREFIX=/usr ./packaging/install.sh
```

It installs:

```text
/usr/bin/aqueous-config
/usr/share/aqueous/noctalia-plugins/catalog.toml
/usr/share/aqueous/noctalia-plugins/settings/
```

After package installation, a user can add and enable the source:

```sh
noctalia msg plugins source add aqueous path /usr/share/aqueous/noctalia-plugins
noctalia msg plugins enable aqueous/settings
```

The standalone installer deliberately does not enable the plugin or alter the
user's bar. The root Aqueous `PKGBUILD` additionally installs a one-time
per-user Noctalia registration hook, so the plugin is enabled automatically
after the packaged `noctalia.service` starts. It does not add the widget to a
bar or re-enable the plugin after a user intentionally disables it.

## Safety model

- Edits stay in memory until **Apply**.
- **Validate** runs the same checks without writing.
- Every request includes the loaded generation; a manual edit blocks stale
  Apply and leaves the draft intact.
- Known numeric, enum, boolean, and color values are validated.
- Raw files receive structural validation and the 1 MiB Aqueous size limit.
- Existing comments, ordering, whitespace, and unknown keys survive typed
  edits.
- Monitor positions and transforms are staged together with other settings;
  dragging never writes directly to disk.
- Multiple changed files are copied to the plugin's persistent backup directory
  before the first write.
- Aqueous's normal hot reload applies the result; the plugin never restarts the
  compositor.

`outputs.toml` is the preferred physical-display policy source. Individual
settings that are absent there continue to inherit from `wm.toml`.
