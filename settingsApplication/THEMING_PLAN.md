# DMS and Noctalia themes for Aqueous Settings

Status: implemented; target-system release checks remain below.
Source review: 2026-09-09.

## Implementation record

The application now has a shared palette model, DMS/Noctalia readers, a separate
background watcher, persisted source selection, and live Quark color/font updates.
Existing widgets are restyled in place to retain editing state. The reproducible
Quark patch adds transactional font replacement and correct sRGB conversion for
the actual swapchain format. Templates and registration examples ship through
the common installer; setup remains an explicit user configuration step.

Automated validation covers schema rejection, preference migration, typography,
stale source completions, partial-write recovery, widget ownership and sizing,
real DMS 1.6.1/Noctalia 5.0.1 template generation, headless page rendering and live
editor interactions, embedded backend/Apply regressions, and package staging.
See [the setup guide](packaging/themes/README.md) for exact supported fields,
paths, units, and unavailable-source behavior.

Physical output scales, mixed-scale/hotplug sessions, prolonged resource checks,
full desktop restart/automatic-mode acceptance, and native Nix/Gentoo builds
remain release validation. Existing small-window scroll culling, IME, shaping,
and accessibility limitations remain documented in [README.md](README.md).
The sections below retain the implementation design and acceptance criteria.

## Outcome and scope

Let the standalone Quark application follow DMS or Noctalia application colors,
fonts, scale, and basic corner rounding, including changes while it is open.
Keep the application usable with neither shell installed. Do not restore either
retired settings plugin or require the optional DMS typography bridge to read a
theme.

Deliver colors and live switching first, followed by fonts and sizing. Exact
shell control shapes, animations, blur, shadows, transparency, icon themes,
IME, and screen-reader integration are outside this feature.

Theme changes must preserve configuration drafts, validation errors, focus,
text selection, scroll position, and pending operations. Receiving a shell
theme must never write canonical TOML, synchronize settings back to a shell,
or trigger a compositor reload.

## Starting code (before implementation)

- `src/main.zig` creates the window with a fixed 16px font and background.
- `src/app.zig` hardcodes label, button, text-field, dialog, and monitor-canvas
  colors. Other widget states inherit Quark defaults, producing a mixed palette.
- Pinned Quark has `Theme` widget structs and `Parent.setTheme()`, which marks
  layout dirty. Window background and explicit widget overrides also need updating.
- Quark accepts font bytes at window creation. Safe runtime font replacement and
  invalidation of measurements and rendered text need investigation and tests.
- `src/services/shell_adapter.zig` detects shells and performs explicit DMS font
  synchronization; it does not retrieve a complete palette.
- `src/services/preferences.zig` currently stores only page and window dimensions.
- `src/services/backend_client.zig` serializes configuration operations. Theme
  discovery must not delay Apply or overwrite its completion/status.

## Product behavior

Add an “Application theme” control to Appearance with four choices:

| Choice | Behavior |
| --- | --- |
| Follow shell | Follow the app's selected shell; reuse existing auto-detection when appropriate. |
| DMS | Read DMS appearance even if configuration synchronization targets another shell. |
| Noctalia | Read Noctalia appearance even if configuration synchronization targets another shell. |
| Built-in | Use the application's bundled palette and fonts. |

Default existing installations to Follow shell. With no selected shell or
ambiguous automatic detection, use Built-in. Store the preference immediately
in `settings-application.json`; it is not a canonical configuration draft and
does not require Apply. Preserve the selection across page/window preference saves.
Leave the existing second-launch behavior intact: activate the current instance
without replacing its appearance selection.

Follow the shell's **application** light/dark mode. In Noctalia, a shell-only
mode override intentionally does not change application templates. Describe
this in the control's help text; exact shell-only mode matching is outside the
initial contract. Do not infer effective automatic mode from the saved `auto`
string or compute a competing sunrise/sunset schedule.

Show a small source/availability message in Appearance. Keep Apply's status
separate. On a transient malformed update, retain the last valid theme from
that source; on first use with no valid source, use Built-in. Switching sources
must never reuse the previous source's palette as if it belonged to the new one.

## Architecture and data contract

Use a shell-independent model in `src/model/theme.zig`, with adapters under
`src/services/theme/`. Quark itself should consume resolved values without
knowing about DMS or Noctalia.

Define a versioned JSON palette export with `version`, `source`, `mode`, and
complete dark/light color-role objects. Include optional source metadata for
diagnostics. Initial roles:

| Application role | Material role |
| --- | --- |
| Window background / text | `background` / `on_background` |
| Control surface / text | `surface_container` / `on_surface` |
| Raised or hovered surface | `surface_container_high` |
| Secondary text | `on_surface_variant` |
| Accent / accent text | `primary` / `on_primary` |
| Selected item / text | `primary_container` / `on_primary_container` |
| Border / keyboard focus | `outline` / `primary` |
| Error background / text | `error_container` / `on_error_container` |

Allow deterministic, documented derivations for optional missing roles. Reject
unknown schema versions, invalid colors, wrong source identity, invalid modes,
and files over 64 KiB. Initially accept opaque `#RRGGBB` colors; do not silently
discard alpha. Keep a complete built-in palette and validated fallback fonts.

Use separate generated files under
`$XDG_CACHE_HOME/aqueous/settings-application/themes/{dms,noctalia}.json`, with
the standard home fallback. Separate files prevent shells from overwriting
one another. Resolve actual absolute paths when registering templates, honoring
the source's supported XDG/override rules. Export files contain data only.

Read font family, size, scale, and rounding through source-specific settings
adapters; do not assume palette templates expose those settings. Normalize point
and pixel sizes explicitly and keep application scale separate from output scale.

## Phase 1: verify source contracts

1. Record the exact DMS and Noctalia versions targeted by packaging. Target the
   Noctalia v5+ TOML configuration used by this repository; legacy v4 requires a
   separate adapter and is not implicitly supported.
2. Capture fixtures for effective light/dark mode, built-in/custom palettes,
   wallpaper-generated palettes, and typography settings from each supported shell.
3. Verify DMS user-template registration and generation for built-in, custom,
   and wallpaper themes. Verify behavior when matugen or user templates are disabled.
4. Verify Noctalia user templates, configuration/state overrides, template refresh,
   and the separation between application mode and shell-only mode.
5. Prefer supported generated exports over parsing GTK CSS, Qt theme files, or
   copying either shell's palette-generation algorithm. A theme name or one accent
   color does not establish the complete effective palette.

Exit check: fixtures and a short compatibility table document exact inputs,
paths, field units, triggers, and unavailable-source behavior. Do not invent an
IPC palette endpoint. If a supported shell cannot export a theme variant,
document that limitation before claiming that variant follows the shell.

## Phase 2: centralized application styling

1. Implement and test the theme model, JSON decoder, role mapping, and defaults.
2. Add `src/services/theme/quark.zig` to translate resolved values into `q.Theme`.
3. Replace hardcoded colors throughout `app.zig` and `main.zig`, including canvas
   drawing, focus/hover states, selection, placeholders, dropdown menus, checkboxes,
   modal overlays, borders, scrollbars, and error messages. Audit the Quark patches
   in `quark/prepare.py` for additional hardcoded state colors.
4. Preserve functional sizing constraints; a shell radius must not turn a small
   control into an unusable shape. Clamp radius relative to control dimensions.
5. Validate all eight pages with deterministic built-in light/dark test palettes
   before connecting live shell sources.

Exit check: every app-owned UI color comes from the shared theme, with readable
text and visible keyboard focus in both modes. No shell is needed for these tests.

## Phase 3: source adapters and setup

1. Add `dms.zig` and `noctalia.zig` readers for generated palette and persisted
   typography settings; normalize both into the same owned theme snapshot.
2. Ship source-specific templates and registration examples under
   `packaging/themes/`. Keep generated files outside the package payload.
3. Add the Application theme preference and source status. Missing or disabled
   exports show concise setup instructions instead of reporting a successful match.
4. Document how to enable exports using the shell's supported template settings.
   Package installation stages templates/examples; it does not replace existing
   user matugen or Noctalia configuration. Any future setup writer must preserve
   unrelated entries and be an explicit action, not a side effect of opening the app.
5. Keep font synchronization in the embedded backend and optional DMS bridge
   unchanged. Reading a shell theme must not create a synchronization feedback loop.

Exit check: real exports from both supported shells style the app on launch;
missing tools, disabled generators, custom XDG paths, and simultaneous shells
produce deterministic results without crashes or configuration writes.

## Phase 4: live updates and lifecycle

1. Add a theme service with bounded background reads and coalesced requests.
   It must not reuse the configuration worker's busy state or block the UI loop.
2. Watch parent directories so atomic file replacement, deletion/recreation,
   and initially missing files are detected. Debounce bursts around 150–250 ms
   and skip unchanged content. Use bounded periodic checks only as a fallback.
3. Give source-selection requests a generation number. Discard completions from
   a source that is no longer selected. Cancel/join background work during shutdown.
4. Publish complete validated snapshots on the UI thread. Retain the current
   valid snapshot while shell files are partially written or briefly inconsistent.
5. Use `setTheme()` plus window-background updates for color-only changes.
   If explicit widget overrides require rebuilding, preserve interaction state
   using stable field identities rather than positional component IDs. Defer
   destructive rebuilds during pointer drag or active editing until state can
   be restored safely.

Exit check: wallpaper/palette/mode changes update an open app within one second
of a completed export, without losing drafts, selection, focus, scroll position,
open dialogs, or Apply results. Repeated changes do not grow memory indefinitely.

## Phase 5: fonts, scale, and Quark support

1. Resolve requested faces through Fontconfig and load regular/bold/italic variants
   with sensible substitutions. Keep bundled fonts when a requested face is absent
   or cannot be loaded. Record unsupported weight/style details rather than guessing.
2. Apply resolved typography at window creation. Add a narrowly scoped Quark API
   for safe runtime family/size replacement if existing APIs cannot support it.
3. Build the replacement font family before releasing the old one; invalidate
   measurement and glyph/render caches and rebuild affected layout on the UI thread.
   Ensure no widget or canvas retains pointers into freed fonts.
4. Scale spacing and control heights with text metrics; remove fixed-height
   assumptions that clip larger fonts. Preserve the raw editor and useful content
   at the app's minimum supported window size.
5. Keep any Quark change reproducible with the pinned dependency. Use a small
   documented patch initially; move to a pinned fork/upstream revision if proper
   runtime font support exceeds a maintainable patch. Update license/source records.

Exit check: changing font and text scale while editing preserves text state,
renders without stale glyphs, and remains usable at representative 100%, 125%,
150%, and 200% output scales. This does not claim to solve Quark's IME or shaping gaps.

## Phase 6: tests, packaging, and release checks

- Unit tests: palette validation and mapping, missing fields, source selection,
  preference migration, typography unit conversion, and out-of-order completions.
- Adapter fixtures: both modes, custom/generated palettes, missing exports,
  malformed/oversized data, partial writes, atomic replacement, disabled generation,
  and custom XDG locations.
- UI tests: all pages in both modes; live theme/font changes while editing raw
  and structured drafts; focus/selection/scroll preservation; Apply during a
  theme change; two shells exporting concurrently; shutdown during a pending read.
- Verify theme updates alone leave canonical TOML and shell settings byte-for-byte
  unchanged and never call compositor reload or the DMS appearance bridge.
- Real-shell acceptance: DMS and Noctalia built-in/custom/wallpaper palettes,
  application-mode changes, Noctalia shell-only override behavior, shell restart,
  missing fonts, and readable controls at several output scales.
- Add template assets to `packaging/install.sh` and check all package paths,
  including direct Arch/release staging, Nix, and Gentoo. Add this plan to source
  distribution metadata when implementation packaging is updated. Preserve plugin
  retirement checks and ensure theme support does not require a plugin daemon.
- Run the existing settings/backend/Apply regression suites. Document setup,
  supported versions, fallback behavior, and any unverified target-system checks
  in `README.md`; distinguish automated fixtures from real-shell acceptance.

The first reviewable milestone is Phase 2: centralized colors with light/dark
fixtures. The second is Phases 3–4: both source adapters and live color updates.
The final milestone adds typography and completes packaging and acceptance checks.

## Sources and version caveats

Quark observations above come from the repository's pinned source revision
`c104e1c953347d677fb1b363260854842217d967`, particularly `Theme.zig`, `window.zig`,
and `Font.zig`.

DMS documents user templates and mode-aware color exports in its
[application theme guide](https://github.com/AvengeMedia/DankLinux-Docs/blob/master/versioned_docs/version-1.4/dankmaterialshell/application-themes.mdx).
That guide is versioned 1.4; validate its registration details against the actual
packaged DMS version during Phase 1. The inspected local DMS source also contains
user-template generation controls in `quickshell/Common/Theme.qml`.

Noctalia v5+ documents resolved template roles and user template configuration in
its [template reference](https://docs.noctalia.dev/noctalia/theming/templates/).
Its [theme documentation](https://docs.noctalia.dev/noctalia/theming/) explicitly
separates shell-only mode overrides from application template generation.
