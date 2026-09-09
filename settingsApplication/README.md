# Aqueous Settings

Standalone Quark UI settings application, built with Zig 0.16. The executable
is `aqueous-settings`, with desktop ID `org.aqueous.Settings`. Configuration
reading, schema validation, document preservation, backups, and toolkit
synchronization are compiled into the application under `src/backend/`.

## Build and launch

Install Zig 0.16, a C toolchain, Python 3, pkg-config, shaderc (`glslc`), Wayland
development files, Vulkan headers/loader, Fontconfig, FreeType, libxkbcommon,
and a working Vulkan driver. Quark and its dependencies are pinned by
`build.zig.zon`; the first build needs access to their sources.

From the repository root:

```sh
zig build --build-file settingsApplication/build.zig -Doptimize=ReleaseSafe
settingsApplication/zig-out/bin/aqueous-settings --shell none
```

Or `zig build --build-file settingsApplication/build.zig run -- --page displays`.
The app needs a Wayland session and `XDG_RUNTIME_DIR`. `--shell auto` probes
running shell IPC services; neither shell, or ambiguous detection, selects
`none`. Explicit choices are `none`, `dms`, and `noctalia`. The UI runs without
either shell. Neutral mode still permits explicit toolkit synchronization.

`--page` accepts `overview`, `appearance`, `layouts`, `input`, `displays`,
`rules`, `keybinds`, or `advanced`. A second launch selects a page in the
existing instance and requests activation through `aqueousctl`, preserving
its drafts and shell selection.

## Editing and operation safety

All eight pages share one draft. Schema controls include defaults and numeric
constraints. Collection editors cover monitors, snap layouts/zones, ordered
window rules, and custom keybindings. Advanced exposes the complete six TOML
files. Built-in keybindings accept comma-separated chords; empty means unbound.
Long dropdowns support wheel browsing. Tab/Shift-Tab traverse visible controls;
arrow keys cycle focused dropdown choices.

Validate checks the entire draft without writing. Apply retains the loaded
generation and uses the existing backup, atomic replacement, and rollback
implementation. Raw and structured edits affecting the same file must be
resolved before saving. External changes retain the draft. Uncertain writes
require inspecting saved files and explicitly reconciling in Advanced.

After a successful Apply, the app runs `aqueousctl session reload --json` and
checks the compositor's acknowledgement. A failed or unavailable reload keeps
the saved settings and displays a warning; Apply can retry with no new edits.
This requires the updated `aqueousctl` and a running compositor supporting
shell protocol version 2. Restart the session after upgrading an older compositor.
Automatic file watching remains active, but is not treated as confirmation.

Configuration jobs run on one worker with an operation-owned arena. The UI
freezes editing until completion. **Cancel operation** can abort preparation;
once saving begins, the worker completes its save/rollback attempt. Window
close respects a running job. External commands have a five-second maximum
and share a thirty-second operation budget. Blocking filesystem operations
are allowed to finish; no thread is killed during file writes. Cancellation
is cooperative and may wait for the current bounded command to return.

Canonical save and toolkit/DMS synchronization are reported separately.
Synchronization failures after a save offer an explicit retry, without
repeating canonical edits. Opening the application never initiates font or
cursor synchronization.

Display positions, scale, transformations, mirroring, and modes stay staged.
Use `WIDTHxHEIGHT` for automatic refresh or `WIDTHxHEIGHT@Hz` for exact refresh.
**Refresh connected displays** updates live observations while preserving the
base generation and drafts, including disconnected outputs. Overview's
**Switch layout now** is an immediate workspace action.
Its dropdown reads the selected output's active workspace from the compositor
and refreshes on Overview once per second. It does not display the saved default
from `layout.toml`. A selection awaiting **Switch layout now** is retained until
the workspace/output changes; unavailable live state is shown explicitly.

UI preferences live in `$XDG_CONFIG_HOME/aqueous/settings-application.json`.
Backups go to `$XDG_STATE_HOME/aqueous/settings-application/backups`, with
standard home fallbacks. Canonical paths and old plugin backups are unchanged.

## Follow DMS or Noctalia appearance

Appearance now has an **Application theme** selector: **Follow shell**, **DMS**,
**Noctalia**, or **Built-in**. The preference saves immediately. Colors, fonts,
and basic rounding update live while preserving editor state; this does not
write canonical settings or trigger Apply/reload.

Enable one of the shipped palette templates using the
[theme setup instructions](packaging/themes/README.md). Installed templates and
registration examples live under `/usr/share/aqueous/settings-application/themes/`
(or the package's custom prefix). DMS and Noctalia generate separate versioned
JSON files in the XDG cache directory. Neither retired settings plugin is needed.
Missing/invalid exports and font fallback are reported in Appearance.

Noctalia follows its application theme mode, including automatic changes; its
shell-only mode override remains separate. Source readers target DMS JSON and
Noctalia v5 TOML. Palette generation was tested with DMS 1.6.1 and Noctalia 5.0.1.
See the setup guide for field mappings, bounds, and fallback behavior.

## Shell integration and upgrading

The former DMS `aqueousSettings` and Noctalia `aqueous/settings` settings
plugins are removed. Launch **Aqueous Settings** from the application menu or
run `aqueous-settings`. The helper executable and `--helper` option are retired.
External scripts/providers that used that CLI must migrate; this application
does not publish a replacement configuration IPC service.

Package-manager upgrades remove package-owned old plugin files. For a previous
Gentoo script installation, uninstall its recorded manifest before installing
the new build so obsolete system files are removed; modified tracked `/etc`
configuration and per-user settings are preserved by that script. Custom shell bars,
user plugin copies, settings, and backups are preserved. For existing profiles:

- Remove old Aqueous Settings widgets and plugin enablement in the shell UI.
- In a hand-written Noctalia config, remove `aqueous_settings` bar references,
  `[widget.aqueous_settings]`, and `aqueous/settings` from enabled plugins.
  Remove the `aqueous` path source pointing to the retired
  `/usr/share/aqueous/noctalia-plugins` only if it serves no other plugins.
- Replace old panel-toggle or `dms ipc call aqueousSettings …` bindings with
  `aqueous-settings --shell noctalia` or `aqueous-settings --shell dms`.
- Remove manually installed copies of those two settings plugins through their
  original installation mechanism. Do not remove unrelated shell plugins.

Noctalia typography remains in the embedded backend. DMS uses the optional
`aqueousSettingsAppearance` daemon shipped under `packaging/dms-appearance/`.
Enable that bridge in DMS when using DMS typography synchronization. It targets
DMS 1.7's SettingsData service and confirms both live and persisted family,
weight, and normal text size. Face/slant/width and separate bar scales remain
partially supported. Missing bridge or failed persistence is reported separately
from the canonical save. The bridge has no editor or background synchronizer.
Portal plugins and shell startup retain their independent roles.

## Install and package

```sh
DESTDIR=/tmp/aqueous-settings-stage PREFIX=/usr \
  settingsApplication/packaging/install.sh
```

`packaging/dev-install.sh` builds and installs under `~/.local`. Supported
installer overrides are `AQUEOUS_SETTINGS_BINARY`, `PREFIX`, `DESTDIR`,
`SYSCONFDIR`, and `AQUEOUS_SETTINGS_BRIDGE_DISCOVERY`. System packages discover
the optional DMS bridge under `/etc/xdg/quickshell/dms-plugins`; personal installs
use the DMS user plugin path. No installer enables the bridge automatically.
Arch, release/binary, Nix, and Gentoo recipes build the embedded application.

## Validation

```sh
zig build --build-file settingsApplication/build.zig test test-driver -Dmodel-only=true
zig build --build-file settingsApplication/build.zig test-ui-model
settingsApplication/tests/test-backend.sh
settingsApplication/tests/test-packaging.sh
python3 settingsApplication/tests/test-retirement.py
python3 settingsApplication/tests/test-dms-bridge.py
AQUEOUS_SETTINGS_TEST_INPUT=1 python3 settingsApplication/tests/test-ui.py
python3 settingsApplication/tests/test-theme-templates.py
AQUEOUS_SETTINGS_TEST_THEME=dms AQUEOUS_SETTINGS_TEST_INPUT=1 python3 settingsApplication/tests/test-ui.py
AQUEOUS_SETTINGS_TEST_THEME=noctalia AQUEOUS_SETTINGS_TEST_THEME_MODE=light python3 settingsApplication/tests/test-ui.py
```

The `test-driver` target builds `aqueous-backend-test`, a test-only adapter for
migrated regression fixtures. It is not installed by application packages or
required by the app. Model/backend tests need no Quark build or display. Backend
integration tests use temporary XDG profiles; the optional equivalence test
accepts a preserved legacy executable as its comparison oracle.

UI tests start an isolated headless Aqueous compositor. They need a Vulkan
software driver and a compositor built with Pixman support; use
`AQUEOUS_COMPOSITOR_BIN` to select that build. Input tests additionally need
`wayland-scanner`, a C compiler, and Wayland/xkbcommon development files.
`AQUEOUS_SETTINGS_ARTIFACTS` saves screenshots with `grim`, and
`AQUEOUS_SETTINGS_TEST_PAGES` narrows page coverage. The DMS bridge test runs
real Quickshell with an isolated SettingsData fixture.

Theme UI tests require `grim` and Python Pillow, check rendered palette colors,
and exercise live light/dark and font-size changes without losing raw-editor
selection or drafts. `AQUEOUS_SETTINGS_TEST_THEME_MODE` selects the initial mode
for all eight pages. Template tests run the installed DMS/Noctalia generators
in temporary profiles. `test-ui-model` checks Quark widget ownership and sizing
without opening a display.

## Remaining platform validation

The embedded migration has automated backend, page-rendering, input, and
package-staging coverage. Physical-monitor acceptance, mixed-scale/hotplug
hardware checks, and full real-session typography/upgrade checks remain release
validation. Nix and Gentoo recipes have not been built in their target systems.

The pinned Quark requires the fixes described in [quark/README.md](quark/README.md).
The raw editor lacks syntax highlighting, undo history, and visible multiline
selection highlighting. IME composition and screen-reader integration are not
implemented. Partially visible controls are culled by scroll views, so small
windows and accessibility still need work. Plugin removal does not resolve
these existing platform gaps. See [the migration record](BACKEND_MIGRATION_PLAN.md).
