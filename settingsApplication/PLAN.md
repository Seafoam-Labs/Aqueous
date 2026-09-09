# Aqueous Settings — Quark application migration plan

Status: historical first-stage plan. The follow-up embedded migration has removed the old settings plugins; remaining platform checks are documented in the current README.  
Source review: 2026-09-09.  
Application directory: `settingsApplication/`.  
Executable: `aqueous-settings`.  
Window title: **Aqueous Settings**.  
Desktop/application ID: `org.aqueous.Settings`.

Follow-up: [Embedded backend and settings plugin removal](BACKEND_MIGRATION_PLAN.md)
replaces this plan's helper-retention and plugin-launcher end state. The original
feature and acceptance checklists below remain relevant.

## Implementation record (2026-09-09)

- Implemented the eight-page Quark application, asynchronous bounded helper
  transport, shared generation-aware drafts, collection/raw editors, explicit
  live display refresh, shell selection, close confirmation, and single instance.
- Extended helper 0.7.2 with `shell_none` and `monitor_scale`, preserving its
  legacy default and existing plugin behavior.
- Added the optional DMS SettingsData typography bridge with durable-save
  verification. Updated widget right-click launchers while retaining old panels.
- Integrated source Arch variants, release/binary staging, and Nix recipes.
  Added build/install documentation, source attribution, and isolated tests.
- Verified ReleaseSafe compilation, all eight pages, actual raw editing through
  Apply, draft retention across navigation/relaunch, dirty-close interception,
  helper/model tests, Noctalia compatibility, staging, and isolated DMS bridge.
- Still open: full physical-monitor and shell-session acceptance, accessibility
  and IME support, small/mixed-scale window behavior, Nix build validation, and
  removal of duplicate plugin editors after those release gates pass. See the
  README for current limitations. Milestone 6 is intentionally not marked done.

The original design and acceptance criteria below remain the rollout checklist.
The implementation keeps page rendering in `app.zig` and consolidates snapshot,
draft, and request logic in `model/draft.zig` instead of creating empty modules.

## Goal and scope

Convert the settings interfaces in `dms-plugin/` and `plugin/settings/` into
one standalone Zig application using Quark UI. The application must work in
Aqueous sessions running DMS, Noctalia, or neither shell. Preserve the union of
the plugins' settings features and their configuration safety behavior.

Use the existing `aqueous-config` executable as the shared configuration
backend. Keep it in `plugin/helper/` during this migration; moving it is a
separate cleanup after callers and packaging have migrated. Do not copy its
implementation into the application or introduce another TOML writer.

Build alongside the existing plugins until parity is verified. Then make the
application the default settings interface and reduce shell integration to
optional launchers and any required appearance adapter. Preserve existing
configuration, backups, and user plugin enablement choices during upgrades.

This migration covers compositor settings, desktop cursor and typography,
and settings launch integration. Shell-specific wallpaper, panel configuration,
Welcome's application installer, and portal chooser integration retain their
own lifecycles. Display Keep/Revert preview is a possible later feature; it
is not part of the current plugins' persistent settings contract.

## Repository baseline

| Existing source | Role in the migration |
| --- | --- |
| `plugin/settings/panel.luau` and `plugin/README.md` | Noctalia behavior, labels, page coverage, and compatibility reference |
| `dms-plugin/pages/` and `components/` | Modular reference for the eight pages, schema controls, and monitor canvas |
| `dms-plugin/services/Draft.js` and `DraftModel.qml` | Draft representation, request construction, collection edits, and conflict rules to port to Zig |
| `dms-plugin/services/DisplayModes.js` and `RuleFields.js` | Display-mode handling and rule editor field reference |
| `dms-plugin/services/ConfigClient.qml` | Asynchronous helper transport, process failure, and timeout behavior |
| `dms-plugin/services/DmsAppearanceAdapter.qml` | DMS typography behavior that currently depends on in-process `SettingsData` |
| `plugin/helper/src/` | Schema, protocol, document preservation, cursor sync, and toolkit sync |
| `docs/dms-configuration-contract.md` | Generation checks, capabilities, ownership, partial success, and uncertain Apply behavior |
| `welcome/build.zig`, `build.zig.zon`, and `src/main.zig` | Existing Zig 0.16 / Quark build, window setup, and worker-to-UI pattern |
| `welcome/src/vulkan_present_shim.c` | Existing workaround to evaluate during rendering validation |
| `plugin/tests/` and `dms-plugin/tests/` | Backend, modes, draft, transport, and packaging regression references |

At planning time the helper was version 0.7.1, protocol 1, with capability discovery.
It exposes `version`, `snapshot`, `raw`, `validate`, and `apply`; requests can
use JSON stdin. Its original shell modes were `noctalia` and `dms`, and
omitting `--shell` selects Noctalia. A standalone neutral mode therefore
requires an explicit, backward-compatible helper addition.

The Welcome app pins Quark commit
`c104e1c953347d677fb1b363260854842217d967`, with package hash
`quark-0.2.0-Uqg3xpBHCQDmN0ctA7UhteVoZ88LIxJTVMloQ6S4mkfu`.
Start evaluation with that pin. The repository demonstrates window, layout,
button, checkbox, dropdown, and text use; it does not establish that every
settings control or accessibility feature needed here is available. Audit
the pinned dependency before choosing implementations for those controls.

## Application design

```text
Desktop launcher / terminal / optional shell launcher
                         |
                Quark application
            pages + shared draft state
                 /               \
     asynchronous helper client   runtime/shell adapters
                 |               (explicit live actions)
           aqueous-config
                 |
     existing Aqueous TOML + toolkit sync
                 |
        compositor configuration reload
```

Use a resizable window with a page sidebar, page-local search, scrollable
content, and a persistent action area for draft count, Validate, Apply,
Reload/Discard, and status. Keep a single draft across navigation. Closing a
dirty window prompts to Apply, Discard, or Cancel; a failed Apply keeps it open.
Clean windows exit normally. Automatic application startup is unnecessary.

Provide `--page <page>`, `--shell auto|dms|noctalia|none`, and
`--helper <executable>` options. Prefer one application instance per graphical
session: subsequent launches request activation/page selection without
discarding drafts. Verify the activation and close-interception mechanisms
in the Quark spike. Any local activation endpoint must live in the user's
runtime directory, be scoped to the session, and accept only bounded launch
messages. Activation is not permission to Apply or discard edits.

Use an Aqueous-owned theme so launching does not depend on a shell theme
service. Support readable contrast, keyboard navigation, visible focus,
mixed display scaling, and usable small-window layouts. Centralize labels
and port the existing English strings so later translations remain possible.

### Proposed directory structure

```text
settingsApplication/
  PLAN.md
  README.md
  build.zig
  build.zig.zon
  src/
    main.zig
    app.zig                  # navigation, window lifecycle, operation state
    model/
      snapshot.zig           # protocol decoding and capability checks
      draft.zig              # staged values and collection operations
      request.zig            # helper request encoding and overlap checks
      display_modes.zig
    services/
      config_client.zig      # bounded asynchronous subprocess transport
      runtime_client.zig     # aqueousctl observation and explicit actions
      shell_adapter.zig      # shell selection and adapter status
      instance.zig           # activation routing
      preferences.zig        # UI-only preferences
    ui/
      shell.zig
      fields.zig
      apply_bar.zig
      monitor_canvas.zig
      raw_editor.zig
      theme.zig
    pages/
      overview.zig
      appearance.zig
      layouts.zig
      input.zig
      displays.zig
      rules.zig
      keybinds.zig
      advanced.zig
    tests.zig
  assets/
    org.aqueous.Settings.svg
  packaging/
    org.aqueous.Settings.desktop
    install.sh
    dev-install.sh
  tests/
    fixtures/
    fake-helper.py
    test-integration.py
    test-packaging.sh
```

These are proposed module boundaries, not a requirement to create empty
scaffolding. Keep model tests independent of a Wayland display and Quark
rendering. Store UI preferences separately from canonical settings, for
example in `$XDG_CONFIG_HOME/aqueous/settings-application.json`, and new
backups under `$XDG_STATE_HOME/aqueous/settings-application/backups`, with
standard home-directory fallbacks. Do not move or delete old plugin backups.

## Configuration and process contracts

1. Discover helper version/capabilities, then load a snapshot. Require protocol
   1 and the capabilities used by each feature. Give an actionable message for
   a missing or incompatible helper; disable unsupported operations explicitly.
2. Generate ordinary controls from snapshot schema metadata, including types,
   constraints, defaults, categories, and aliases. Keep collection editors
   explicit. Preserve unknown data and expose raw configuration access.
3. Retain the loaded generation with all drafts. Port `changes`, `raw_files`,
   `monitor_changes`, `snap_zone_changes`, `custom_keybind_changes`,
   `window_rule_changes`, `snap_layouts`, `default_snap_layout`,
   `normalize_stacking`, `sync_cursor`, and `sync_typography` semantics.
4. Send complete requests over stdin using argv arrays, without shell command
   interpolation. Include `expected_generation`, a backup directory, and
   `create_user_override: true`. Resolve raw/typed overlap per affected file
   before Validate or Apply. Respect the existing 4 MiB request and 1 MiB
   per-TOML-file limits; raw-filled snapshots can exceed a single file's size.
5. Run helper and runtime operations off the UI thread. Serialize mutating
   operations, bound stdout/stderr, drain both streams, reap children, and
   reject malformed/truncated responses. Select a snapshot response bound
   that accommodates all six raw files plus schema and discovery metadata.
6. Validate is read-only and retains drafts. Apply uses the helper's validation
   and generation checks, then accepts the returned saved snapshot. Freeze
   editing while applying, or retain later edits separately; never clear edits
   that were not included in the completed request.
7. On external changes, retain drafts and show the conflict. Reload/Discard
   must not silently destroy them. On timeout or lost Apply response, obtain
   fresh state and reconcile the attempted request before allowing a retry;
   do not automatically repeat a potentially completed write.
8. Report canonical save, toolkit synchronization, and observed compositor
   state separately. Multi-file saves have backups and per-file atomic
   replacement, not an all-files transaction. Preserve helper diagnostics and
   inspect saved state after write errors before retrying.
9. Retain explicit cursor/typography retry flags for partial synchronization
   failures. Opening the app or polling state must not trigger synchronization.

## Feature parity checklist

| Page | Required behavior before replacing plugin editors |
| --- | --- |
| Overview | Effective file paths, inherited/user-override state, warnings, helper status; selected-output workspace layout switching clearly labeled as an immediate action |
| Appearance | Effects and alpha colors; opt-in cursor theme/size; installed Fontconfig families/faces and portable style metadata; point size; per-target availability, synchronization, partial support, and retry |
| Layouts | All schema-backed layout options, Game Mode, canonical Stacking aliases and normalization, named snap layouts, stable editable layout/zone IDs, presets, padding, legacy A–D migration, add/remove operations, and shortcut creation |
| Input | All schema-backed input controls with defaults and numeric/enum validation; broader raw input access remains available in Advanced |
| Displays | Merge configured/offline outputs with helper live outputs; scaled monitor canvas, drag placement, exact X/Y, scale, rotations/flips, resolution and fractional refresh selection, custom offline modes, inherited values, and hotplug refresh |
| Rules | Ordered window rule creation, editing, deletion, and movement; preserve helper restriction that a staged move cannot mix with other rule edits; raw access for other rule tables |
| Keybinds | Built-in actions including unbound shortcuts, comma-separated chords, action commands, custom add/edit/remove, and snap-layout/zone command presets |
| Advanced | Edit complete `wm.toml`, `layout.toml`, `input.toml`, `outputs.toml`, `rules.toml`, and `appearance.toml`; structural validation and raw/typed overlap feedback |

Monitor dragging, mode selection, rotation, and scale changes all remain
staged. Automatic refresh serializes `WIDTHxHEIGHT`; an explicit refresh uses
`WIDTHxHEIGHT@Hz` without losing fractional precision. Reconcile live hotplug
observations without replacing the base generation or erasing monitor drafts.
When the compositor is unavailable, keep persistent/offline editing usable
and disable runtime-only actions with an explanation.

## Shell compatibility and typography

- Add `--shell none` to the helper and advertise a corresponding capability.
  It performs canonical and applicable toolkit work while skipping shell
  writes/reloads. Preserve existing explicit DMS/Noctalia behavior and the
  helper's legacy default for old clients. The new app always passes its
  resolved shell mode explicitly.
- Resolve `auto` through verified current-session evidence. A shell binary's
  presence on PATH is insufficient. Use `none` when no shell is active; if
  detection is ambiguous, use neutral mode and expose the shell selector.
  A mode change with drafts requires explicit handling so an in-flight request
  or existing draft cannot silently change synchronization targets.
- Keep Noctalia typography synchronization in the existing helper adapter.
  Preserve its family-only status when an exact font face was requested.
- DMS currently synchronizes through QML `SettingsData`, which the Zig process
  cannot call directly. During the initial spike, verify whether the target
  DMS version has a supported external settings API for read/write and durable
  save results. If it does, implement an adapter against that verified API.
  Otherwise retain a minimal optional DMS bridge exposing only typography
  inspection/apply with structured results. Do not assume an IPC method exists
  or edit DMS's settings file behind its service.
- Preserve DMS's family/weight/normal-text-size mapping and partial support
  reporting for face, slant, width, and independently scaled bars. An absent
  bridge/API means DMS synchronization is unavailable, while canonical and
  other toolkit settings remain editable. DMS appearance parity is a release
  gate for retiring the old DMS editor.
- Assign synchronization to explicit Apply/retry only, with one active owner.
  A launcher bridge must not keep the old editor's background synchronizer
  running. Keep portal plugins and shell session startup independent.

## Implementation milestones

### 1. Verify Quark and shell integration feasibility

- Build a minimal Quark window in `settingsApplication/` using the Welcome
  dependency pin, with an independent package name/fingerprint and cache.
- Exercise editable text, multiline text, selection/copy/paste, numeric input,
  dropdowns, scrollable forms, focus traversal, modal confirmation, pointer
  dragging/custom drawing, close interception, activation, and scale changes.
- Record which controls are native, need application widgets, or require a
  pinned Quark patch. Verify text input/IME and accessibility capabilities;
  record gaps with an implementation path before claiming parity.
- Test resize and output changes against the Vulkan workaround in Welcome;
  carry it only if needed and documented, or pin a verified upstream fix.
- Resolve the DMS API-versus-bridge decision against installed/target source
  and document the exact supported interface and failure behavior.

Exit: buildable standalone window, control feasibility evidence, and a concrete
implementation path for raw editing, monitor canvas, window lifecycle, and
DMS synchronization. Do not start broad page conversion with these unresolved.

### 2. Implement backend client and shared draft model

- Add the neutral helper mode and compatibility tests without breaking old
  clients. Build the app's snapshot decoder, capability checks, request encoder,
  worker transport, operation state, and independent UI preferences.
- Port draft semantics from both plugins, using current behavior/tests as the
  reference. Build fake-helper failure cases and temporary-XDG integration
  fixtures. Implement generation conflict and uncertain Apply recovery first.

Exit: a real fixture edit survives Validate, applies once through the helper,
preserves unrelated TOML, and cannot overwrite an externally changed file.

### 3. Deliver the application frame and schema pages

- Implement navigation, page-local search, global draft actions, errors,
  reset-to-default, close confirmation, and launch options.
- Complete Overview, Input, basic Appearance, schema Layouts, and built-in
  Keybinds. Finish shell selection and cursor/typography status/retry handling.

Exit: schema coverage matches the helper, navigation retains drafts, and
ordinary settings work under DMS, Noctalia, and neutral mode.

### 4. Complete collection and advanced editors

- Port snap layouts/zones, custom keybindings, ordered window rules, font-face
  details, monitor mode handling/canvas, and all six raw editors.
- Add single-instance activation and verify reopening/page selection preserves
  drafts. Complete keyboard and mixed-scale interaction checks.

Exit: every feature-parity row passes, including raw/typed conflicts, legacy
stacking data, offline monitors, and the rule-move restriction.

### 5. Package alongside existing plugins

- Provide `zig build`, `zig build run`, and display-independent `zig build test`.
  Add a `DESTDIR`/`PREFIX`-aware installer, desktop entry, application icon, and
  local development installer. Build/install one shared `aqueous-config`.
- Add Quark/Wayland/Vulkan/font/input and shader build dependencies using the
  verified build; the executable must not require Noctalia, DMS, Quickshell,
  Shelly, or `pkexec` merely to run its settings interface.
- Update all source package variants: root `PKGBUILD`, `PKGBUILD-DMS`,
  `PKGBUILD-git`, `PKGBUILD-intel`, `GitPKGBUILD/PKGBUILD`,
  `IntelPKGBUILD/PKGBUILD`, and `gitNoctalia/PKGBUILD`. Check meta-package
  dependency ownership without adding duplicate helper providers.
- Update `.github/workflows/release.yml` and `PKGBUILD-bin` together so published
  artifacts, required-file checks, dependencies, and installs agree.
- Extend `nix/default.nix` and `nix/zig-deps.nix` for the app and its pinned
  transitive dependencies; keep Nix builds offline and update Nix documentation.
- Test package staging without changing the developer's desktop configuration.

Exit: each supported package path includes a launchable application, desktop
entry, assets, and compatible helper; existing plugins still work during rollout.

### 6. Switch entry points and retire duplicate interfaces

- Change package-owned default launch entry points to `aqueous-settings`.
  Optional DMS/Noctalia widgets launch the app with explicit shell selection;
  they no longer implement pages or maintain separate drafts.
- Inventory existing DMS `open`/`toggle`/`close` and Noctalia panel-toggle usage.
  Preserve launch compatibility where possible and document changed window
  lifecycle semantics. No compatibility action may silently discard drafts.
- Update plugin registration/install hooks, Noctalia defaults, DMS discovery
  assets, tests, and READMEs together. Preserve customized bars and deliberate
  disablement. Explain removal/replacement of old plugin entry points.
- Remove duplicate page code only after parity and upgrade checks pass. Retain
  the shared helper, its regression tests, and any required thin adapter.

Exit: one maintained settings UI, working shell launch paths, and an upgrade
that preserves users' settings, backups, and custom shell configuration.

## Validation and release gates

Run model/protocol tests without a graphical session and integration tests
against isolated XDG directories. Reuse `plugin/tests/test-helper.sh`,
`plugin/tests/test-modes.py`, and `dms-plugin/tests/test-helper.py`; run existing
full plugin suites while compatibility code or helper behavior changes.

Required automated cases include malformed/oversized helper output, launch
failure, child timeout, uncertain Apply, generation conflicts, preserved
comments/unknown keys, user overrides, multi-file errors, raw/typed overlap,
partial toolkit success/retry, neutral-shell isolation, fractional display
modes, snap IDs/legacy migration, and ordered rule operations.

Interactive release checks cover DMS, Noctalia, and no-shell Aqueous sessions;
missing compositor/helper/optional adapter; small and mixed-scale displays;
dragging/rotation/hotplug; keyboard/text/clipboard interaction; and close,
reopen, repeated launch, and resize behavior. Verify on physical monitors that
saved modes take effect; a helper success alone is not display acceptance.

Stage packages into a temporary destination and verify executable, helper,
desktop-entry/app-ID consistency, assets, dependencies, and upgrade hooks.
Do not retire either plugin editor until its feature checklist and shell
appearance integration pass. Record outstanding Quark/platform limitations
explicitly in release notes rather than treating a successful build as parity.
