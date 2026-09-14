# GTK welcome and shell setup plan

Status: implemented, September 14, 2026. See [welcome documentation](../welcome/README.md)
for the delivered behavior, verification commands, and remaining release checks.

Implementation refinements: the native GTK frontend remains Zig; a Python
standard-library worker owns subprocess supervision, journaling, and session
selection. The inspected Shelly build exposes sudo password prompts through its
controlling terminal, so the worker provides a private terminal and replies there;
package JSON uses separate pipes. No invented authentication frame or external
Shelly modification is required. Programmatic GTK widgets replace Quark. This
plan below records the intended scope; the README describes the final interfaces.

## Intended result

Replace the Quark welcome interface with a Zig + GTK4 application that uses
Shelly to install the user's chosen desktop shell and configures Aqueous to use
exactly one of **Pearl**, **DankMaterialShell (DMS)**, **Noctalia**, or **Nothing**.
Keep the executable `aqueous-welcome`, desktop identity
`org.aqueous.Welcome`, and manual reopening after first-run completion.

The welcome app owns setup orchestration and user configuration. Shelly owns
package discovery, dependency resolution, installation, package questions, and
privileged package transactions. `aqueous-config` remains the owner of canonical
Aqueous configuration validation and persistence.

Welcome invokes `shelly` directly. When Shelly requests a password, welcome
shows a GTK password popup and sends the entered password back to that pending
request. Select all optional dependencies for every package installed through
this flow, including explicitly selected applications.

Initial installation support is Arch and compatible distributions, matching the
existing Shelly integration. NixOS retains declarative shell selection; Fedora
installation remains a separate workflow. Do not introduce direct pacman, AUR
helper, DNF, or Nix invocations inside welcome.

## Findings that determine the implementation

Local source inspected: Aqueous `1d038dc`, Pearl `5e7e10f`, and Shelly-ALPM
`7b0e1007`. Package availability and compatibility still require release checks.

- `welcome/build.zig` and `build.zig.zon` currently link Quark, including a
  welcome-specific Vulkan presentation shim. `src/main.zig` combines UI,
  background work, an application catalog, and Noctalia customization.
- `src/install_plan.zig`, `shelly_client.zig`, and `shelly_protocol.zig` already
  construct argv arrays, discover installed packages, and decode Shelly's
  base64 JSON frames. Preserve these concepts and their useful tests.
- The runner currently ignores stdin and recognizes progress rather than the
  full transaction lifecycle. Current Shelly supports interactive question
  responses; `--no-confirm` does not eliminate all questions. Shelly can report
  `TransactionCancelled` with exit status zero, so exit status alone is not a
  sufficient success check.
- Shelly's inspected optional-dependency protocol uses `q.optdeps` requests and
  `a.optdeps` responses containing `QuestionId` and `SelectedIndices`.
  `--no-confirm` currently chooses no optional dependencies, so omit that flag
  and respond explicitly. The inspected elevation code relaunches through an
  elevator; it does not establish a structured password request/response
  contract. Verify or add that contract in Shelly as part of this integration.
- Source packaging hard-depends on DMS; binary/Noctalia packaging chooses
  Noctalia. Startup uses `aqueous-dms.service`, `dms.service`, or
  `noctalia.service`, depending on the variant. Some variants ship welcome;
  `packaging/tests/test-dms-git-packaging.py` explicitly expects it to be absent.
- `packaging/aqueous-init` seeds Noctalia configuration when packaged defaults
  exist, independently of a user shell choice. Bindings and portal chooser
  configuration also depend on the packaged shell.
- Pearl is a separate GTK4 shell, not just a settings app. Assume it is available
  from the configured repositories as `pearl-de`, per the requested distribution
  contract. The inspected local package recipe still uses `pearl`; welcome must
  target `pearl-de`. It starts through `pearl.service` and provides `pearlctl`. Its current
  packaging requires an Aqueous helper capability contract that must be checked
  against this checkout before advertising a working installation.
- Both Pearl and Shelly's GTK UI use pinned generated `ghostty-gobject`
  bindings. Reuse that binding approach without linking either application's UI.

## User flow and choice semantics

1. **Choose your desktop.** Present four mutually exclusive choices with a short
   description and installed/available/current status. Require an explicit
   choice on fresh installations; detect the existing shell on established
   installations. Detection failures show “Unknown,” not “Not installed.”
2. **Review setup.** Show package sources, packages to install, configuration
   changes, all optional dependencies reported by Shelly, and when the selected
   shell will become active. State that all optional dependencies are included;
   show any further dependencies when Shelly resolves the transaction. Preserve existing
   settings by default. A change of card must not install or write anything.
3. **Install and configure.** Show separate installation, configuration, and
   activation stages, streamed progress, package questions, and expandable logs.
   Provide retry for failed stages without repeating completed work blindly.
4. **Finish.** Report the installed shell and pending/active session choice.
   Existing sessions switch on the next login by default. Offer a user-triggered
   logout only after setup succeeds; never log out automatically.

| Choice | Package identity to validate | Setup behavior |
| --- | --- | --- |
| Pearl | `pearl-de` (assumed available in configured repositories) | Check Aqueous/helper capabilities; seed missing Pearl settings; select Pearl startup, bindings, and compatible portal configuration. |
| DMS | `dms-shell`, recognizing supported providers such as `dms-aqueous` | Preserve DMS preferences; select one supported DMS startup unit, DMS bindings, and the existing DMS portal integration. |
| Noctalia | `noctalia` for the packaged native v5 integration | Seed missing v5 settings; select Noctalia startup, bindings, and its existing portal chooser. |
| Nothing | None | Install no shell and select no managed shell startup. Keep a terminal shortcut, compositor controls, welcome launcher, and shell-independent portal behavior. |

“Nothing” is an intentional shell-free configuration, distinct from **Skip for
now**, which leaves shell configuration unchanged. Neither action uninstalls
existing shell packages or deletes their settings. When reopening welcome,
choosing Nothing schedules the previous managed shell to stop starting at the
next login; it does not abruptly stop the current desktop.

Retain the current optional application catalog as a separate optional step,
with nothing preselected. All optional dependencies of a selected application
are selected automatically. The Nothing path can finish without installing any
packages; applications require their own explicit selection. Move existing
Noctalia appearance controls behind its adapter, and prefer opening each shell's
own settings after setup over building three complete settings editors.

## Architecture

### GTK frontend

- Keep Zig 0.16 and replace Quark with pinned GTK4/GLib/GIO generated bindings.
  Use `GtkApplication`, `GtkApplicationWindow`, standard selection controls,
  a page stack, and compiled UI/CSS resources. GTK's application lifecycle
  supports application uniqueness and window activation; handle repeated manual
  launches by presenting the existing window. See [GtkApplication documentation](https://docs.gtk.org/gtk4/class.Application.html).
- Keep widgets on the GTK main thread. Run package/configuration operations
  asynchronously, using GIO subprocess streams or a bounded worker abstraction
  that posts results into the main context. [GSubprocess](https://docs.gtk.org/gio/class.Subprocess.html)
  supplies piped I/O and asynchronous process waiting.
- Retain the process while a transaction is active and prevent concurrent
  setup runs with a per-user operation lock. Closing a window must not orphan
  a transaction or synchronously join a blocked worker on the UI thread.
- Use normal theme inheritance, keyboard navigation, accessible labels, and
  responsive layouts. Welcome must run before any desktop shell exists.
- Remove `vulkan_present_shim.c` and welcome's direct Quark/rendering dependency
  after the GTK executable passes smoke checks. Aqueous's own Vulkan dependency
  is unaffected by this frontend migration.

Suggested module boundaries under `welcome/src/`:

| Module | Responsibility |
| --- | --- |
| `main.zig`, `ui/` | GTK lifecycle, pages, actions, progress and questions |
| `setup_model.zig`, `setup_plan.zig` | Explicit choice, preflight, immutable reviewed plan, operation states |
| `shells.zig`, `shells/{pearl,dms,noctalia,none}.zig` | Data-driven package identities and shell setup adapters |
| `shelly_client.zig`, `shelly_protocol.zig` | Discovery, transaction transport, questions, terminal outcomes |
| `ui/password_dialog.zig` | GTK password popup and response to Shelly's pending authentication request |
| `session_setup.zig` | Managed startup selection and activation verification |
| `setup_state.zig`, `first_run.zig` | Recovery journal, migration, completion and autostart compatibility |

### Shelly integration

- Verify the supported Shelly version and actual CLI schemas first. Do not
  assume a capabilities command or a transaction-preview API exists. Use
  available query commands and introduce upstream contract work only where
  required. Distinguish a catalog estimate from a resolved transaction preview.
- Resolve exact package/provider identities against configured repositories.
  Prefer repository packages; support AUR only through a tested explicit
  backend mapping. Do not silently change sources, add repositories, or invent
  Flatpak shell IDs when a package is unavailable.
- Invoke argv arrays beginning with `shelly`, for example
  `shelly install standard pearl-de --ui-mode`. Keep welcome unprivileged and
  let Shelly own elevation. Welcome must not prepend sudo or pkexec, configure
  `SUDO_ASKPASS`, or launch a separate elevation helper. Validate Shelly's
  elevation route, including AUR builds under the invoking user's identity.
- On a Shelly password request, open a modal GTK popup with a masked password
  entry, Authenticate, and Cancel. Send the supplied password only as the
  response to that pending request through Shelly's private input transport.
  Correlate authentication responses with the request and transaction; keep
  them distinct from dependency and confirmation responses on the transport.
  Keep passwords out of argv, environment variables, files, logs, and the setup
  journal; clear application-owned password buffers promptly. Cancel sends the
  contract's cancellation response and never counts as successful authentication.
- Pin the actual Shelly authentication request/response format, retry behavior,
  and cancellation semantics. If the target build lacks this transport, add
  support in Shelly before connecting the popup; do not invent existing event
  names or fall back to welcome-owned sudo/askpass. Let Shelly and its elevation
  backend enforce authentication policy. Handle incorrect passwords, cancelled
  requests, unavailable elevation, and denied permission as recoverable outcomes.
  Show the popup only when requested, including on retries; never cache or replay
  the password across transactions in welcome.
- For every `q.optdeps` request, respond with `a.optdeps`, the matching
  `QuestionId`, and every selectable option's supplied index in `SelectedIndices`.
  Select all optional dependencies, including further optional-dependency
  requests during resolution. Respect already-installed entries without forcing
  reinstalls, and use Shelly's indices rather than positions in a filtered UI.
  Omit `--no-confirm`, whose current defaults skip optional dependencies.
  Apply this policy to shell packages and selected catalog applications; do not
  automatically select unrelated catalog applications. Surface unavailable or
  conflicting dependencies rather than silently dropping them. Other question
  types retain their appropriate review/response handling.
- Add bidirectional framed I/O for question IDs and responses, terminal
  success/failure/cancellation events, bounded diagnostics, fragmented frames,
  and child termination. Drain stdout and stderr concurrently. Unsupported
  questions must produce a recoverable error rather than an automatic answer.
- Re-query installed packages after installation and before configuration.
  A successful process exit or a “100%” progress message is insufficient.
- Implement the cancellation behavior supported by Shelly. Cancelling a pipe
  read is not cancellation of the package transaction. Where safe transaction
  cancellation is unavailable, let the active transaction finish and stop
  before configuration; communicate that state in the UI.
- Treat missing Shelly, unavailable backends, repository/network failures,
  package locks, and declined authorization as distinct recoverable states.
  Nothing and Skip remain usable without Shelly.

### Configuration and startup

- Introduce a versioned user selection, proposed as
  `$XDG_CONFIG_HOME/aqueous/session.toml`, containing `shell =
  "pearl"|"dms"|"noctalia"|"none"`. Keep runtime detection separate from the
  desired next-login choice; distinguish an absent selection from explicit none.
- Add a common Aqueous session selector integrated with both UWSM and the
  existing fallback startup. It resolves the selection after the live session
  environment is available and starts only the selected shell. Preserve shell
  readiness and existing ordering before desktop autostart where supported;
  verify the unit graph does not introduce ordering cycles.
- Remove package-owned unconditional shell enablement as packages migrate to
  the selector. Inventory legacy global/user unit links and desktop autostarts,
  including both DMS unit names. Suppress conflicting Aqueous-managed starts;
  do not delete custom startup scripts or disable shell startup in unrelated
  desktop sessions. Show unresolved custom startup conflicts before applying.
- Apply shell-specific Aqueous bindings through `aqueous-config` using a
  snapshot, expected generation, validation, and apply. Preserve unrelated
  fields/comments and user bindings; review conflicts rather than overwriting
  a whole `wm.toml`. Pearl uses the helper's neutral `--shell none` contract;
  DMS and Noctalia use their verified adapter modes where relevant.
- Seed missing shell configuration only for the selected shell. Existing shell
  preference files remain user-owned. Optional import of DMS preferences into
  Pearl can use Pearl's reviewed migration workflow as later work.
- Select portal chooser configuration along with the shell. DMS/Noctalia can
  reuse existing integrations. Audit Pearl's chooser support; supply a tested
  shell-independent chooser for Pearl/Nothing if no native integration exists.
  Never leave ScreenCast or Screenshot configured to call an absent shell.
- Package a compatible Shelly build and its required elevation runtime so the
  welcome-owned GTK popup can answer Shelly's password request before any shell
  is installed. Verify this in a session with no polkit agent.
  Selected shells may retain their own polkit integration for other desktop
  actions; it is independent of welcome's Shelly password-response flow.
- A fresh shell-free session may offer **Start now** after successful setup and
  ownership/readiness checks. Existing sessions default to next-login changes.
  Do not stop lockers to switch shells. Full live switching is follow-on work.

### Recovery and existing users

- Write a bounded versioned setup journal under `$XDG_STATE_HOME/aqueous/` with
  the reviewed selection, completed stages, backup paths, and pending activation.
  Use private files and atomic replacement. Capture previous startup selection
  and configuration before mutation.
- Journal intent before applying each stage. On restart, reconcile the journal
  against actual package/configuration state rather than assuming completion.
  If configuration fails after installation, retain installed packages and
  restore only this operation's configuration changes when generations still
  match. Report concurrent-edit conflicts; never claim package rollback.
- Honor the existing `welcome-v1` marker and `Hidden=true` autostart override.
  Do not force setup onto existing users after an upgrade. Manual launching
  always remains available. A failed or cancelled setup must not mark completion.
- Preserve an existing shell when importing a legacy installation with no new
  selection file. If multiple startup mechanisms conflict, require resolution
  in the review flow. Fresh installations with no selection launch welcome
  with usable terminal access.

## Implementation sequence and acceptance gates

1. **Lock integration contracts.** Record tested Shelly command/event schemas,
   GTK binding pins, package sources/providers, shell launch/readiness checks,
   and Aqueous/helper capabilities. Use `pearl-de` as the assumed available Pearl
   repository package and resolve its required helper contract. Deliver the
   adapter manifest and source-derived protocol fixtures, including password
   requests/responses and selection of all optional dependencies. Include any
   required Shelly authentication transport changes in this phase.
2. **Replace the UI.** Build the GTK executable with all four choices, review,
   progress, results, and existing first-run/manual-launch behavior. Connect a
   fake installer; verify keyboard access, theme changes, fractional scaling,
   responsiveness, and single-instance activation. Remove Quark from welcome.
3. **Complete the Shelly client.** Implement package status, source resolution,
   question responses, outcome handling, password-popup authorization, and recovery. Verify
   normal/failed/cancelled transactions, fragmented output, stderr pressure,
   missing backends, and retry with a fake Shelly process and a pinned real CLI
   in a disposable environment. Cover incorrect/cancelled passwords, denied
   elevation policy, authentication already satisfied by Shelly, and authentication
   followed by a package question without misrouting responses or logging
   passwords. Verify calls begin with `shelly`, omit `--no-confirm`, and select
   all optional dependencies using supplied indices. Cover empty/all-installed
   lists, repeated requests, noncontiguous indices, and dependency conflicts.
4. **Implement shell setup and session selection.** Add all four adapters,
   canonical binding updates, conditional defaults, Shelly runtime packaging, portal
   selection, and next-login activation. Verify one shell starts and Nothing
   starts none through both UWSM and fallback login paths.
5. **Migrate state and add recovery.** Verify old completion markers, existing
   settings, both DMS service variants, duplicate/custom startup detection,
   interrupted installation, configuration failure, generation conflicts,
   and activation failure. Preserve a usable previous configuration.
6. **Update packaging and release builds.** Make the core Aqueous package
   shell-neutral and include or depend on the GTK welcome package in supported
   Arch desktop distributions. Move shell dependencies into optional/profile
   packages; eliminate mandatory shell dependencies along the entire dependency
   chain so Nothing actually installs no shell. Update all PKGBUILD variants,
   `PKGBUILD-meta`, `aqueous.install`, release workflow, welcome desktop entries,
   and staged packaging tests. Intentional shell profiles may provide a default
   only when no user selection exists. Keep Nix/Fedora behavior explicit.
7. **Run end-to-end acceptance and document.** Test fresh install of each choice,
   each directed change between choices, existing package providers, offline
   setup, declined password requests, login/logout, restart after failure, shell readiness,
   terminal access, and portal source selection. Use disposable Arch sessions
   for real installs and isolated configurations for fixtures. Update root and
   welcome READMEs with installation, switching, Nothing, recovery, and platform
   support. Release only after the four-choice matrix passes.

Acceptance requires an actual first login with no shell preinstalled or polkit
agent running, direct Shelly invocation, successful password-popup responses,
and installation with all optional dependencies for each supported shell. Verify persistence over
the next login, no competing shell startup, and a usable Nothing session. Unit
fixtures or a GTK window opening alone do not establish those results.

## Scope boundaries and outstanding verification

Keep automatic shell removal, greeter/display-manager changes, full live shell
switching, and wholesale settings import outside this migration. The existing
optional application catalog can stay without making those features prerequisites.

Pearl availability is assumed under the repository package name `pearl-de`;
package publication is not an outstanding prerequisite in this plan. The
implementation still needs to establish the matching helper capability set,
the compatible Shelly version, Pearl/Nothing portal chooser behavior, and the
Shelly password request/response integration. These are concrete implementation deliverables, not
reasons to guess working commands or expose a nonfunctional Install button.

Local integration references inspected alongside this repository:

- `/home/zoey/Pearl/packaging/arch/PKGBUILD`
- `/home/zoey/Pearl/packaging/systemd/pearl.service`
- `/home/zoey/Pearl/docs/MIGRATION.md`
- `/home/zoey/RiderProjects/Shelly-ALPM/Shelly.Ui.Gtk/README.md`
- `/home/zoey/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/output/ui_operation.zig`
- `/home/zoey/RiderProjects/Shelly-ALPM/Shelly.Cli.Zig/src/runtime/elevation.zig`

These external checkout paths are research references only; the welcome build
must use pinned dependencies and packaged contracts, not absolute checkout paths.
