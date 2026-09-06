# Aqueous Settings for Dank Material Shell

`aqueous-config` 0.7.1 adds capability discovery in version and snapshot JSON;
existing protocol-1 clients retain their 0.7.0 minimum. See the
[shared DMS configuration contract](../docs/dms-configuration-contract.md).

A DMS plugin for editing Aqueous configuration, based on the Noctalia v5
Aqueous Settings plugin. It provides a DankBar popout and a separate settings
window, sharing one draft model across all bar instances.

Targets DMS **1.7 or newer**, the shared **aqueous-config 0.7.0** helper,
`aqueousctl`, and Aqueous. The helper is built with Zig 0.16. DMS supplies
Quickshell and the QML components.

## Install for development

From the repository root:

```sh
./dms-plugin/packaging/dev-install.sh
```

This builds `plugin/helper/`, installs `aqueous-config` in
`${XDG_BIN_HOME:-$HOME/.local/bin}`, and links `dms-plugin/` into
`${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/aqueousSettings`.
Ensure the helper directory is on the PATH used by DMS, or set its absolute
path in the plugin's settings. Existing unrelated plugin directories are
preserved.

Enable **Aqueous Settings** in DMS Settings → Plugins, then add its widget to
DankBar. Left-click opens the attached popout; right-click opens the separate
window. Plugin settings include the helper executable path.

The enabled plugin also supports opening without a bar widget:

```sh
dms ipc call aqueousSettings open
dms ipc call aqueousSettings toggle
dms ipc call aqueousSettings close
```

After source changes, reload through DMS's plugin UI or:

```sh
dms ipc call plugin-scan reload aqueousSettings
```

Drafts survive closing a window or popout. Disabling/reloading the plugin or
restarting the shell destroys its in-memory drafts; apply or discard them first.

## Editing

- **Overview** shows paths and warnings and offers immediate workspace layout
  switching for a selected output. This live action is labeled separately.
- **Appearance** includes effects, colors with alpha, cursor management,
  installed font families/faces, font size, and adapter status/retry actions.
- **Layouts** includes every schema-backed layout setting, Game Mode,
  Stacking aliases, named snap layouts, legacy A–D zones, presets, migration,
  padding, editable IDs, and shortcut creation.
- **Input** provides schema-backed input controls.
- **Displays** combines live Quickshell screens with configured outputs.
  Drag cards or edit X/Y and rotation/flip values; changes are staged in
  `outputs.toml`. Resolution and refresh selectors use the advertised monitor
  modes, retaining fractional Hz. Editable selectors accept custom modes for
  offline outputs. Automatic refresh writes only `WIDTHxHEIGHT`; explicit rates
  write `WIDTHxHEIGHT@Hz`. Mode drafts survive movement and rotation, and the
  canvas uses the selected resolution at the effective scale.
- **Rules** edits ordered window rules. Apply/discard each move before making
  other rule edits, matching the helper's ordering contract.
- **Keybinds** lists all built-in actions and commands, including unbound
  shortcuts, and supports adding/removing custom bindings.
- **Advanced** edits the complete six Aqueous TOML files. Raw and typed drafts
  affecting the same file must be resolved before Validate or Apply.

Search filters schema-backed settings on the selected page. Numeric controls
show input errors; the helper validates the complete request, including complex
collections and raw TOML. The reset arrow stages the field's default value.

**Validate** retains drafts and does not write configuration. **Apply** saves
through the helper and lets Aqueous hot-reload. An external file edit blocks a
stale Apply and retains drafts; Reload/Discard requires confirmation when edits
are present. An uncertain Apply timeout or invalid response requires reloading
and inspecting the saved state before retrying.

The helper preserves unrelated TOML and comments, creates user overrides for
system files, and backs up multi-file edits under
`${XDG_STATE_HOME:-$HOME/.local/state}/aqueous/dms-plugin/backups`. Files are
replaced atomically; toolkit updates are individually observable and may fail
independently of the canonical save.

## Shared helper and appearance

The plugin uses the existing `plugin/helper/` binary, not a fork. Protocol 1
is retained. Version 0.6.0 adds:

```sh
aqueous-config snapshot --shell dms
aqueous-config validate --shell dms --request -
aqueous-config apply --shell dms --request -
```

`--request -` accepts JSON over stdin with the existing 4 MiB request limit.
Version 0.7.0 adds `live_outputs` mode discovery and an optional `mode` member
in each `monitor_changes` entry. Both frontends require that version so an older
helper cannot silently ignore a mode edit. File-based `--request /path` remains supported. Omitting `--shell` keeps
Noctalia behavior. DMS mode never writes or reloads Noctalia settings.
`sync_typography: true` retries toolkit typography without requiring a change
to the canonical font settings; `sync_cursor` retains its existing behavior.

After a canonical typography Apply, the QML adapter uses DMS's `SettingsData.set`
API for family, weight, and scale. DMS's 14-pixel normal text tier is aligned to
Aqueous point size at 96 DPI (`points × 96 / 72 / 14`). It reports partial
coverage: exact face, slant, width, and independently scaled bars are not fully
represented by DMS's global typography settings. A failed DMS settings save is
reported and can be retried. GTK, GSettings, Qt, and opt-in cursor synchronization
remain owned by the shared helper.

## Packaging

`PKGBUILD-git`, `GitPKGBUILD/PKGBUILD`, both Intel variants, and `PKGBUILD-DMS`
build/test the shared helper and install this plugin. They follow the Aqueous
repository revision and depend on Seafoam Labs' `dms-aqueous` package from
[its DMS fork](https://github.com/Seafoam-Labs/DankMaterialShell).
The release `PKGBUILD` and `PKGBUILD-bin` retain Noctalia integration.

A standalone staged install is also supported:

```sh
DESTDIR="$pkgdir" PREFIX=/usr ./dms-plugin/packaging/install.sh
```

The installer places the helper in `/usr/bin`, runtime assets under
`/usr/share/aqueous/dms-plugins/aqueousSettings`, and a discovery symlink at
`/etc/xdg/quickshell/dms-plugins/aqueousSettings`. `PREFIX`, `DESTDIR`, and
`SYSCONFDIR` are configurable. For a prebuilt helper, set
`AQUEOUS_CONFIG_BINARY=/path/to/aqueous-config`. It does not rewrite DMS settings
or bar layouts; enablement remains the user's persistent choice.

## Tests and compatibility

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/aqueous-plugin-zig-global \
ZIG_LOCAL_CACHE_DIR=/tmp/aqueous-plugin-zig-local \
zig build test --build-file plugin/helper/build.zig
zig build --build-file plugin/helper/build.zig
./dms-plugin/tests/test-all.sh
```

The DMS suite needs Python 3, `rg`, Qt's `qmlformat`/`qmltestrunner`, and
Quickshell. Override `QMLFORMAT`, `QMLTESTRUNNER`, or `QUICKSHELL` for other
installation paths. It checks helper writes in isolated XDG directories,
Noctalia isolation, stdin content, generation conflicts, toolkit retry,
packaging, QML syntax, drafts, and asynchronous process failures/recovery.
Run `plugin/tests/test-all.sh` for the complete Noctalia regression suite.

For real DMS QML components on an isolated headless Aqueous compositor:

```sh
DMS_SOURCE=/path/to/DankMaterialShell ./dms-plugin/tests/test-host.sh
```

Initialize the DMS checkout's `dank-qml-common` submodule first. This test needs
an existing compositor build and permission to create local Wayland/IPC sockets.
It copies the host into a temporary directory and uses temporary HOME/XDG
settings. Set `KEEP_DMS_TEST=1` to keep its logs and screenshot.

The host contract passes prospective DMS **1.7** upstream master commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`, with pinned `dank-qml-common`
commit `26396ce432d6c71c3f5367438f96f4a8d667e160`. Upstream has not published a
1.7 tag, so repeat this validation against the eventual release before shipping.
The headless test covers eight pages, four bar edges, helper Validate/Apply,
font synchronization, and IPC. Interactive font-picker behavior, physical
monitor hotplug, and distro package installation should also be checked on a
normal desktop before a release. The full DMS Go application is not required
by the host harness; DMS service warnings about a missing `dms` executable in
that harness are expected.

API references at the validated commit: [plugin guide](https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/PLUGINS/README.md),
[manifest schema](https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/.agents/skills/dms-plugin-dev/assets/plugin-schema.json),
[PluginService](https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Services/PluginService.qml),
[SettingsData](https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Common/SettingsData.qml).
