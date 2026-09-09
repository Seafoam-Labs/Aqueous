# Embedded backend and settings plugin removal

Status: embedded migration and settings plugin removal implemented; target-system and physical-device release validation remain open.  
Source review: 2026-09-09.  
Application: `settingsApplication/`, executable `aqueous-settings`.

This plan supersedes the original migration plan's requirement to retain
`plugin/helper/` and use the `aqueous-config` executable. The existing app is
the starting point. Implement the work below before removing the old interfaces.

## Implementation record

The backend is compiled into the app, the old plugin directories and production
helper are removed, and package/startup references have been migrated. The optional
DMS bridge remains. Regression fixtures now live under `tests/backend/` and run
through a test-only driver. Source inspection also found a Gentoo installer, which
was migrated alongside the planned Arch/release/Nix paths.

Automated checks include 33 backend/model tests, cancellation boundaries, external
command deadlines and limits, legacy result/saved-byte equivalence, all eight
pages, actual raw editing/Validate/Apply, and package staging. Hardware acceptance,
accessibility/IME gaps, and target-system Nix/Gentoo builds remain open and are
listed in the README. Removal follows the user's requested final ownership;
it must not be presented as completion of those platform checks.

The original implementation checklist below is retained as the migration record.

## Target outcome

The standalone application owns both settings UI and configuration operations.
Remove the DMS settings plugin (`aqueousSettings`) and Noctalia settings plugin
(`aqueous/settings`). Remove their editors, launch widgets, registrations,
enablement hooks, and production dependency on the helper executable.

Keep the optional DMS typography bridge (`aqueousSettingsAppearance`) already
under `settingsApplication/packaging/dms-appearance/`. It has no settings UI;
it performs explicit synchronization through DMS's SettingsData service and
reports persisted results. Retain the existing Noctalia typography adapter as
backend code. Shells, portal plugins, Welcome, and unrelated integrations keep
their existing roles.

Preserve canonical TOML locations, comments and unknown keys, user overrides,
generation checks, validation, backups, and shell-specific synchronization
semantics. The application owns the existing configuration implementation;
there must be one TOML writer implementation after migration.

## Architecture

```text
Desktop entry / aqueous-settings [--page …] [--shell …]
                         |
                  Quark UI + drafts
                         |
                serialized backend worker
                         |
              embedded configuration backend
                 /                    \
        Aqueous TOML            toolkit/shell operations
                                      |
                           optional DMS typography bridge
```

Proposed ownership:

```text
settingsApplication/
  src/
    backend/
      root.zig              # callable operation API
      operations.zig        # snapshot, raw, Validate, Apply
      config_document.zig   # existing document preservation and file I/O
      schema.zig
      toolkit_sync.zig
      cursor_sync.zig
    services/
      backend_client.zig    # worker state and result ownership
      process_client.zig    # remaining external commands
      process.c             # bounded subprocesses and instance endpoint
      shell_adapter.zig
      instance.zig
      preferences.zig
    model/                  # current drafts and display model
    tests.zig
  tests/
    fixtures/
    backend/                # migrated configuration regression coverage
    test-ui.py
    test-dms-bridge.py
    test-packaging.sh
```

Use useful module boundaries rather than creating empty files. Expose backend
operations through explicit operation, shell, request, allocator, and I/O
arguments. Library code returns errors/results and never reads stdin, parses
process arguments, prints responses, or calls `std.process.exit`.

Initially retain JSON request and snapshot structures in memory. This preserves
the app's draft model and provides an equivalence check against the old helper.
Typed Zig request/result structures can follow separately. Keep request/file
bounds and schema validation; JSON is still untrusted configuration input even
when it no longer crosses a subprocess boundary. Helper version negotiation
becomes unnecessary for the embedded backend, but malformed data must still
produce recoverable errors.

## 1. Extract and establish backend equivalence

- Inventory all production references to `aqueous-config`, `plugin/helper/`,
  `aqueousSettings`, and `aqueous/settings`, including generated package paths.
  Migrate any additional caller before deleting its entry point.
- Move the five existing helper source files into the application backend.
  Split CLI-only code out of `main.zig`; its large operation implementation
  becomes backend code. Change request handling to accept request bytes/value
  directly instead of a filename or stdin.
- Export snapshot, raw, Validate, and Apply operations. Keep shell mode explicit;
  preserve `none`, `dms`, and `noctalia` behavior.
- Give each operation its own arena and configuration snapshot. Pass environment
  and path configuration explicitly where practical; never change the GUI's
  process-wide environment to emulate a separate helper invocation.
- Temporarily keep a thin CLI wrapper calling the extracted backend so existing
  tests can run during migration. This is a transitional/test tool, not a new
  long-term installed interface.
- Compare old and embedded operation results on isolated fixtures, accounting
  for runtime observations and temporary paths. Confirm equivalent saved bytes,
  errors, generation checks, and side effects.

Exit: backend tests run without Quark or a graphical session, and embedded
Validate/Apply preserve the existing configuration contract.

## 2. Replace helper transport with safe in-process execution

- Link the backend module into `settingsApplication/build.zig`. Replace helper
  invocations with a dedicated `backend_client` worker, keeping the UI responsive
  and serializing operations.
- Retain result ownership until the UI has consumed it. Every completion must
  correspond to its operation/request, with no clearing of later drafts and no
  worker access to Quark state. Separate backend jobs from external-command jobs.
- Preserve the existing editing freeze during Apply and draft retention on
  validation failure, external changes, malformed results, and save errors.
- Audit blocking calls in configuration, Fontconfig discovery, toolkit/cursor
  sync, and compositor observation. The old 30-second helper deadline killed a
  process group; killing an embedded worker thread is not an acceptable substitute.
- Bound external command execution individually, drain/reap child processes, and
  use cooperative cancellation between safe stages. Before writing, cancellation
  can abort. Once saving starts, finish the save/rollback attempt and report its
  result before admitting another operation. Window close must respect this state.
- Report canonical save and toolkit/DMS synchronization independently. A shell
  timeout after a successful save retains that successful save result and offers
  a synchronization retry. Never blindly repeat Apply after a lost completion.
- Keep saved-state inspection and explicit reconciliation for partial/uncertain
  writes. Embedding removes transport failures, not filesystem failures or crashes.
- Keep subprocess support needed by `aqueousctl`, toolkit tools, shell IPC, and
  the DMS bridge. `process.c` also owns single-instance IPC, so it cannot simply
  be deleted with the helper transport.
- Remove `--helper`, helper-path configuration, helper discovery, and helper
  capability mismatch UI. Preserve `--page`, shell selection, and single instance.

Exit: the app edits and applies settings with `aqueous-config` absent from PATH
and filesystem search locations; stalled external tools do not freeze rendering
or leave a second Apply running concurrently.

## 3. Migrate tests and close standalone feature gaps

- Move reusable fixtures and document/schema/operation tests from `plugin/tests/`,
  helper unit tests, and `dms-plugin/tests/test-helper.py` into the application.
  Replace CLI assumptions with direct backend tests or a test-only adapter.
- Retain rule order/move restrictions, snap layout/zone IDs and migration,
  bindings, raw/typed conflicts, numeric bounds, fractional modes, monitor scale,
  mirrors, disconnected drafts, and neutral-shell isolation coverage.
- Exercise missing/unwritable files, inherited overrides, comments/unknown keys,
  multi-file save/rollback failures, stale generations, cancellation, bounded
  child output, timeouts, and partial typography/cursor synchronization.
- Change UI tests to launch the embedded app without `--helper`. Verify typed
  and raw edits, Validate without writes, Apply, invalid-input retention,
  navigation, repeated launch, dirty close, and recovery paths.
- Retain the DMS bridge test and verify its pending/saved/failed/request-ID
  behavior with the app. Preserve relevant real-shell tests before deleting the
  old QML and Luau test harnesses.
- Complete the original plan's outstanding standalone acceptance checks: physical
  monitor mode changes, hotplug, small/mixed-scale windows, keyboard/clipboard and
  multiline editing, DMS/Noctalia appearance, and missing optional services.
  Track accessibility/IME gaps explicitly; do not claim complete parity while
  they remain unresolved. Fix required gaps before retiring the editors.

Exit: old plugin behavior needed by the standalone app has independent coverage;
removal will not delete the only tests for configuration or shell semantics.

## 4. Switch packaging and launch integration

Update these paths together:

| Area | Required changes |
| --- | --- |
| App installers | Remove helper build/copy requirements and `AQUEOUS_CONFIG_BINARY`; install the application, desktop entry, icon, source attribution, and optional DMS bridge |
| Arch source packages | Update `PKGBUILD`, `PKGBUILD-DMS`, `PKGBUILD-git`, `PKGBUILD-intel`, `GitPKGBUILD/PKGBUILD`, `IntelPKGBUILD/PKGBUILD`, and `gitNoctalia/PKGBUILD`; remove helper/plugin build, checks, and install phases; run application/backend tests |
| Binary releases | Change `.github/workflows/release.yml` and `PKGBUILD-bin` together; remove helper/plugin files from staging and required-file lists; add absence assertions for retired assets |
| Nix | Update `nix/default.nix`, `nix/module.nix`, source filters, checks, and wrappers; move required Fontconfig/toolkit command PATH dependencies from the helper wrapper to the app; retain neutral-session support and offline Zig dependencies |
| Noctalia defaults | Remove the settings widget, its bar reference, plugin enablement, and the package-owned source if it serves only this plugin from `packaging/noctalia/config.toml` |
| Startup hooks | Remove `packaging/enable-noctalia-plugin.sh`, its service `ExecStartPost` in `packaging/noctalia.service` and `nix/module.nix`, its installation/wrapper entries, and obsolete tests |
| DMS discovery | Remove only `aqueousSettings` runtime/discovery assets; retain `aqueousSettingsAppearance` and the unrelated `aqueousPortal` chooser |
| Install notices/docs | Update root/variant `.install` files, application and package guides, and the configuration contract to describe direct backend ownership and new launch commands |

Use the existing desktop entry as the default launch path. Document explicit
shell commands such as `aqueous-settings --shell dms --page appearance`.
Old DMS settings IPC open/toggle/close commands and Noctalia panel-toggle
bindings are retired; users should replace them with application launches.
A subsequent launch activates/selects a page and cannot discard drafts.

Fresh installs must have no references to missing settings widgets. Upgrades
remove package-owned assets through packaging, preserve canonical TOML and old
backups, and preserve custom shell bars and unrelated plugin enablement. Document
exact retired widget/plugin/source IDs for cleanup of user-owned configuration
and manual plugin installations; do not recursively delete user plugin folders
or overwrite custom shell configuration. Keep the DMS appearance bridge opt-in.

Exit: staged Arch/release/Nix outputs include one settings UI and no production
helper executable or retired settings plugin, while shell sessions and portals
continue to work.

## 5. Remove old code and finalize ownership

After the preceding exits pass:

- Delete `dms-plugin/` after migrating its reusable tests, reference data, and docs.
- Delete `plugin/settings/`, obsolete plugin installers, and the helper CLI/build
  after its source and tests have moved. Remove `plugin/` only after confirming
  every remaining file has been migrated or is obsolete.
- Remove transitional CLI comparison tools unless a test-only adapter remains
  useful. Do not ship `aqueous-config` or an alias solely for retired plugins.
- Update active documentation links; archive earlier plans as historical records.
  Run a repository reference audit for deleted paths and old launcher commands.
  Historical notes and explicit upgrade instructions may retain old names.
- Run final backend/UI/shell tests and package checks from a clean source tree,
  with the old directories and helper unavailable. Build Nix on a compatible
  Nixpkgs revision; the current environment has not validated that path.

## Completion criteria

- [x] One application binary contains the configuration backend and owns its tests.
- [x] No runtime dependency on `aqueous-config`, `--helper`, or deleted sources.
- [x] Both settings plugins and their automatic enablement are removed.
- [x] The optional DMS bridge and unrelated shell/portal integrations pass isolated regression tests.
- [ ] Save safety, cancellation, conflict/recovery, and feature acceptance pass.
- [x] Fresh-install staging and configuration seeding tests pass; upgrade cleanup is documented without rewriting custom shells.
- [ ] Arch source variants, binary-release staging, and Nix builds/checks pass.
- [x] Documentation accurately describes the final architecture and limitations.
