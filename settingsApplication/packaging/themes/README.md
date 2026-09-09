# Theme exports for Aqueous Settings

Select **Appearance → Application theme → Follow shell, DMS, Noctalia, or
Built-in**. Follow shell uses the shell selected in the window header. Selecting
DMS or Noctalia explicitly affects only the app's appearance, not which shell
receives configuration synchronization. Neither retired settings plugin nor the
optional DMS appearance bridge is needed to read themes.

Enable the corresponding export once. The application watches it and the shell's
font settings; normal palette changes then update an open settings window.
The application never edits shell settings merely to adopt their appearance.

## DMS

Merge the entry in `dms.toml.example` into `$XDG_CONFIG_HOME/matugen/config.toml`
(default `~/.config/matugen/config.toml`). Keep existing entries. Replace
`/home/USERNAME/.cache` with your absolute cache path (`$XDG_CACHE_HOME`, or
`~/.cache` when unset). Keep the template's source path absolute too.

Change/reapply a DMS theme to produce the export. DMS user templates and matugen
must be enabled. Disabling generation leaves the last exported appearance in
place; the app cannot infer an unexported palette from its theme name.

Typography reads `$XDG_CONFIG_HOME/DankMaterialShell/settings.json`, using
`fontFamily`, `fontWeight`, `fontScale` (14 logical pixels at scale 1), and
`cornerRadius`. Fontconfig provides available regular/bold/italic faces. Missing
families use a reported fallback. Font weights map to Fontconfig weight bands.

## Noctalia v5+

Merge `noctalia.toml.example` into your Noctalia `config.toml` and enable its
user template. Use an absolute output path if your shell does not expand
`$XDG_CACHE_HOME`; it must point to your actual cache directory. Run
`noctalia msg templates-apply` to generate the initial export, or change a palette.
For a custom installation prefix (including Nix), use the actual installed
`share/aqueous/settings-application/themes/noctalia.json.in` path.

Typography reads `$XDG_CONFIG_HOME/noctalia/config.toml`, followed by
`$XDG_STATE_HOME/noctalia/settings.toml` (usual home fallbacks apply).
`NOCTALIA_STATE_HOME` overrides the state root. The settings app also accepts
`NOCTALIA_CONFIG` as an explicit input-file override for alternate profiles.
Recognized fields are `[shell].font_family`, `[accessibility].ui_scale` (16
logical pixels at scale 1), and `[shell].corner_radius_scale` (applied to Quark's
5px base radius). Bar-only font settings do not resize the application.

Templates follow Noctalia's application light/dark mode. A shell-only mode
change does not regenerate application colors. Noctalia v4's QML settings and
palette files are not supported by this adapter.

## Behavior and limits

Generated files are separate:

- `$XDG_CACHE_HOME/aqueous/settings-application/themes/dms.json`
- `$XDG_CACHE_HOME/aqueous/settings-application/themes/noctalia.json`

Unset `XDG_CACHE_HOME` means `~/.cache`. The format is version 1, identifies its
source and resolved `dark`/`light` mode, and includes both complete color-role
maps. Colors are opaque `#RRGGBB`; files are limited to 64 KiB. See the templates
for the exact roles. Do not feed the app a shell settings file as a palette.

Parent-directory watches debounce updates by 200ms; a 500ms background poll
covers missing directories and atomic replacement. Invalid/transient updates
keep the last valid appearance for that source. Switching source resets to the
built-in theme until the new source loads. Missing exports are explained in
Appearance. A change arriving during a pointer drag is applied after release.

Fonts are limited to 10–32 logical pixels; rounding is limited to 0–18px.
Font loading happens off the UI thread and font-family replacement happens on
the UI thread after the complete family is available. Exact shell widget shapes,
animation, blur/transparency, and advanced font shaping/IME are separate features.
Theme changes do not save canonical settings or request compositor reload.

The templates were exercised with DMS 1.6.1 and Noctalia 5.0.1 generators in
isolated profiles. Newer versions should be checked with
`python3 settingsApplication/tests/test-theme-templates.py` from a source checkout.
