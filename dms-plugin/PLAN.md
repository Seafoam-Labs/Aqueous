# Aqueous Settings for Dank Material Shell

Status: implemented as plugin 0.2.0 with shared helper 0.7.0. Automated
backend, draft, process, packaging, and headless host checks are available.
Normal-desktop interactive checks remain part of release validation.

Implementation decisions relative to the proposal:

- DMS v1.6.0 is the verified host API baseline.
- A composite widget + daemon owns shared drafts and IPC; the daemon can open
  a separate window without a bar widget.
- Requests use the new bounded stdin transport instead of temporary files.
- DMS system discovery uses `/etc/xdg/quickshell/dms-plugins`, linked to the
  package-owned runtime assets under `/usr/share/aqueous/dms-plugins`.
- Explicit user enablement preserves settings, layouts, and later disablement.
- `sync_typography` provides a retry even when canonical values have not changed.

The original implementation plan follows; `README.md` documents shipped usage.

Create a native Dank Material Shell (DMS) settings plugin in `dms-plugin/`,
using the existing Noctalia plugin in `plugin/` as the behavior reference.
The target is feature parity with its current `0.5.0` implementation, with a
DMS-themed QML interface and the same shared configuration backend.

## Repository findings

- `plugin/settings/panel.luau` implements eight pages: Overview, Appearance,
  Layouts, Input, Displays, Rules, Keybinds, and Advanced. The source is Noctalia
  v5 Luau, so its presentation must be rewritten for DMS.
- `plugin/helper/` builds `aqueous-config`. Its JSON protocol is version 1,
  with `version`, `snapshot`, `raw`, `validate`, and `apply` commands.
  Validate and Apply currently consume a file through `--request`.
- The helper already owns schema discovery, TOML preservation, validation,
  generation checks, user overrides, backups, cursor sync, and toolkit sync.
- `plugin/helper/src/toolkit_sync.zig` currently always includes Noctalia as
  an active typography target and writes its settings during synchronization.
  Reusing the helper unchanged would therefore affect Noctalia from DMS.
- `PKGBUILD-DMS` already packages the compositor and DMS session service, but
  does not build or install `aqueous-config` or a settings plugin. Its source
  currently targets Aqueous `v0.4.8`; packaging must use a release containing
  the new plugin when this ships.
- `packaging/aqueous-dms.service` already starts DMS. Plugin integration should
  use this existing session setup.

## Architecture and scope

Keep `plugin/helper/` as the single backend implementation and build one
`aqueous-config` executable for both shells. Keep DMS-specific UI, development
scripts, tests, and documentation in `dms-plugin/`. A later backend directory
move can be considered separately; copying the Zig sources would create two
implementations to maintain.

The data flow will be:

```text
DankBar widget / plugin open action
                 |
           QML settings panel
                 |
         draft model + helper client
                 |
           aqueous-config
          /              \
 Aqueous TOML files   appearance synchronization
          |
 compositor hot reload
```

Configuration remains in Aqueous's existing files. DMS plugin storage is only
for preferences such as helper location and last selected page. Persisted
compositor edits require Apply; Validate must remain read-only. The existing
live workspace layout action remains an explicitly labeled immediate action.

The first release includes all eight pages, search, display arrangement,
stacking layouts and snap zones, keybindings, rules, typography, cursor
management, and raw file editing. Publishing to the DMS registry and adding a
new Nix shell-selection interface are follow-up work.

## Proposed directory structure

```text
dms-plugin/
├── PLAN.md
├── README.md
├── plugin.json
├── AqueousWidget.qml
├── AqueousPanel.qml
├── Settings.qml
├── StartupCheck.qml
├── components/
│   ├── ConfigField.qml
│   ├── ApplyBar.qml
│   └── MonitorCanvas.qml
├── pages/
│   ├── OverviewPage.qml
│   ├── AppearancePage.qml
│   ├── LayoutsPage.qml
│   ├── InputPage.qml
│   ├── DisplaysPage.qml
│   ├── RulesPage.qml
│   ├── KeybindsPage.qml
│   └── AdvancedPage.qml
├── services/
│   ├── ConfigClient.qml
│   ├── DraftModel.qml
│   └── DmsAppearanceAdapter.qml
├── translations/
├── packaging/
│   ├── dev-install.sh
│   └── install.sh
└── tests/
    ├── test-all.sh
    ├── test-packaging.sh
    ├── tst_DraftModel.qml
    └── tst_ConfigClient.qml
```

Only runtime assets are installed; development files remain in the repository.
Use the plugin ID `aqueousSettings` and display name **Aqueous Settings**.

## DMS integration

Use a `plugin.json` manifest with `type: "widget"`, a QML component, a settings
component, and a startup check. Declare `dankbar-widget`, dependencies on
`aqueous-config` and `aqueousctl`, and `settings_read`, `settings_write`, and
`process` permissions. Set `requires_dms` to the oldest release actually
verified in milestone 1. These fields and the identifier format follow the
[upstream manifest reference](https://github.com/AvengeMedia/DankMaterialShell/blob/master/.agents/skills/dms-plugin-dev/references/plugin-manifest-reference.md).

Use `PluginComponent` for horizontal and vertical bar pills and
`PopoutComponent` for the settings flyout. Style controls with DMS theme tokens.
Pass the originating screen to the panel for monitor-specific live actions.
Reserve auto-saving `PluginSettings` controls for plugin preferences; compositor
fields bind to the draft model. Adapt translated text to `I18n.trFor` instead
of copying Noctalia's translation calls. These integration points are described
in the [DMS plugin guide](https://github.com/AvengeMedia/DankMaterialShell/blob/master/quickshell/PLUGINS/README.md).

Start from the existing 860×720 panel size, clamp it to the available screen,
and provide scrolling and a compact navigation layout on small displays.
Verify keyboard focus, Escape behavior, scaling, and all four bar positions.
Closing and reopening the flyout should retain drafts for the loaded plugin
instance; explicit Reload/Discard asks before dropping edits. Warn before a
plugin reload when the host lifecycle permits it.

Provide a documented open/toggle action through DMS's supported plugin/IPC
mechanism. Discover and test the actual runtime API in milestone 1 before
documenting a command. Confirm opening without a placed bar widget; if that
requires a persistent component, establish it during that milestone. Avoid
creating duplicate IPC handlers or independent draft owners on multiple bars.

## Helper client and draft lifecycle

1. Check helper version/protocol, then load a snapshot. Read the schema from
   the response rather than duplicating field defaults and bounds in QML.
2. Keep the loaded snapshot and its generation separate from typed, raw,
   monitor, keybinding, snap-layout, and rule drafts. Preserve array order and
   stable IDs. Define conflicts between raw and typed edits to the same file
   explicitly, following the existing panel's behavior.
3. Serialize requests using the existing fields, including
   `expected_generation`, `changes`, `raw_files`, `monitor_changes`,
   `custom_keybind_changes`, `snap_layouts`, `default_snap_layout`,
   `window_rule_changes`, `normalize_stacking`, and `sync_cursor` as needed.
   Preserve JSON array/object distinctions and omission semantics.
4. Invoke processes asynchronously using executable/argument arrays. Write
   unique request files in a private runtime directory, await write completion,
   pass `--request`, and clean up after completion. Keep backups in a persistent
   XDG state directory. Do not build shell commands from edited values.
5. Serialize write operations and prevent stale callbacks from replacing newer
   state. Distinguish launch failure, malformed JSON, nonzero exit, validation
   error, external-change conflict, and partial synchronization.
6. Validate retains all drafts. Successful Apply replaces the baseline with
   the returned snapshot. Failed validation or generation conflicts retain
   drafts and offer an explicit reload/review path, without force-overwriting.
   Reconcile uncertain Apply completion by reading current state before retrying.

Keep the helper's existing comment preservation, 1 MiB raw-file limit,
atomic replacement, backup behavior, and `/etc/xdg` override handling. Atomic
replacement is per file; do not present multi-file Apply or toolkit sync as a
single all-or-nothing transaction.

## Feature parity

| Page | Required behavior |
| --- | --- |
| Overview | Loaded paths, status, warnings, draft count, and current workspace layout on the selected output; immediate layout switching through `aqueousctl`. |
| Appearance | Effects and colors with alpha; opt-in cursor management; installed font families and faces, size, and per-target synchronization status. |
| Layouts | All schema-backed layout settings, Game Mode, canonical Stacking aliases, named snap layouts, stable/editable layout and zone IDs, padding, presets, migration, and binding creation. |
| Input | Schema-backed keyboard, pointer, touchpad, and other recognized input fields with defaults and validation. |
| Displays | Connected and offline configured outputs, common-scale drag canvas, logical geometry, rotations/flips, exact X/Y fields, and inherited `wm.toml` values; staged overrides go to `outputs.toml`. |
| Rules | Ordered window-rule creation, editing, removal, and stacking-related fields, preserving unknown content through the backend. |
| Keybinds | All built-in actions including unbound ones, comma-separated chords, custom bindings, snap-command presets, and launcher/terminal/screenshot/lock commands. |
| Advanced | Complete raw editors for `wm`, `layout`, `input`, `outputs`, `rules`, and `appearance`; validation and generation checks shared with typed editing. |

Connected output discovery must use an Aqueous-compatible source: inspect the
existing helper response and Quickshell screen information in milestone 1.
Do not depend on DMS's compositor-specific niri or Hyprland services. Confirm
output-name matching, negative coordinates, fractional scale, rotation, and
hotplug behavior while drafts are present.

## Appearance adaptation

Add an explicit shell selection to the shared helper, proposed as
`--shell dms` for snapshot, validation, and Apply. Keep the current behavior for
existing callers that omit it. DMS mode skips Noctalia inspection, writes, and
reload commands while retaining the canonical appearance file and GTK,
GSettings, Qt, and cursor adapters.

Implement DMS font synchronization in `DmsAppearanceAdapter.qml` through
verified DMS settings APIs after the canonical Apply succeeds. Inspect the
supported family, face, and size representation before defining the mapping;
do not reuse Noctalia's 12-point scale conversion without evidence. If DMS
cannot represent a selected face or size exactly, show a partial result with
the limitation. An unavailable target must not be reported as synchronized.
Read back the DMS values and expose a retry action for failed synchronization.
Avoid competing direct writes to DMS's settings file while the shell owns it.

This requires a helper version increase. Keep protocol 1 if the change remains
additive, and make the DMS plugin require the new helper version so it cannot
silently run against the old Noctalia-only behavior. Extend shared helper tests
to verify both the unchanged default and DMS-specific selection.

## Installation and packaging

- Add a development installer that builds the shared helper and installs or
  links runtime assets into the user plugin directory, respecting XDG paths.
  Document plugin discovery, enablement, and adding the DankBar widget using
  commands or UI verified against the supported DMS release.
- Add a `DESTDIR`/`PREFIX`-aware installer. Proposed system asset location:
  `/usr/share/aqueous/dms-plugins/aqueousSettings/`, with the shared helper at
  `/usr/bin/aqueous-config`. Verify DMS system discovery; where registration
  is necessary, register this bundle through a supported user-level path.
- Update `PKGBUILD-DMS` to build the helper, run helper and DMS plugin checks,
  and install both runtime assets and helper dependencies. Keep package
  ownership of `aqueous-config` unambiguous; there is only one binary.
- Preserve existing DMS settings and bar layouts. Any first-run registration
  hook must be idempotent and respect a user's later disablement. Reuse
  `packaging/aqueous-dms.service` only if a verified registration hook is needed.
- Document optional installation from the source tree for other distributions.
  Keep changes to default Noctalia packaging limited to shared-helper needs.

## Implementation milestones

1. **Verify the DMS host contract.** Select and record a tested DMS release and
   commit. Prove widget/popout loading, settings access, process results,
   request-file writes, output discovery, plugin lifetime, IPC opening, and
   install discovery in a small scaffold. Resolve the appearance API mapping.
   Exit: a DMS widget can display a real Aqueous snapshot and open via IPC.
2. **Implement the shared client and drafts.** Add shell selection to the
   helper, then implement typed field rendering, Validate, Apply, Reload,
   generation conflicts, request cleanup, and actionable errors.
   Exit: a typed edit round-trips without losing unrelated TOML text, and a
   stale-generation Apply leaves the draft intact.
3. **Port all settings pages.** Complete the feature matrix, including monitor
   arrangement, named snap layouts, custom bindings, ordered rules, raw editing,
   and DMS appearance synchronization. Port behavior from the current Luau
   source and fixtures, not only the older design notes.
   Exit: every listed Noctalia feature has a working DMS equivalent.
4. **Package and document.** Add installers, update `PKGBUILD-DMS`, and write
   build, enablement, IPC, troubleshooting, and compatibility instructions.
   Exit: a clean staged install contains everything needed to load the plugin.
5. **Validate the release.** Run shared-backend regressions, DMS UI tests,
   package checks, and manual Aqueous+DMS smoke tests.
   Exit: all acceptance criteria below pass on the recorded DMS version.

## Validation and acceptance criteria

- Reuse Zig helper tests and `plugin/tests/test-helper.sh` with isolated HOME
  and XDG directories. Test schema validation, comment preservation, user
  overrides, ordered records, external changes, and partial synchronization.
- Add meaningful QML tests for draft lifecycle and request construction, plus
  a fake helper for malformed output, launch failure, delayed responses,
  stale generations, failed Apply, and recovery. Exercise array deletion and
  the raw/typed edit conflict path.
- Validate the manifest against the selected DMS schema and run QML tooling
  with the matching DMS imports. Test real plugin loading in the host; source
  inspection alone is insufficient.
- Verify DMS Apply creates no Noctalia settings and invokes no Noctalia reload.
  Run existing Noctalia checks after shared-helper changes to prevent regressions.
- Stage packaging into a temporary root; check asset completeness, executable
  permissions, helper availability, custom prefixes, and repeated registration.
- Manually exercise horizontal/vertical bars, multiple screens, small screens,
  light/dark themes, keyboard navigation, monitor hotplug, and popup reopening.
- Confirm no persisted configuration changes occur before Apply, except the
  separately labeled live workspace action. Applying valid settings must
  trigger normal Aqueous hot reload without restarting the compositor.

The environment has no `dms` executable. The DMS v1.6.0 QML source and pinned
shared dependency were used with Quickshell and a headless Aqueous compositor
for host verification. The full DMS application and physical-monitor desktop
checks remain release-validation work.
