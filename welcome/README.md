# Welcome to Aqueous

A native Zig + GTK4 first-run application for selecting **Pearl**, **DMS**,
**Noctalia**, or **Nothing**, with an optional application catalog. Pearl is
installed as `pearl` for stable Aqueous and `pearl-git` for both Git variants.
Nothing installs no desktop
shell. Close the window to leave the current selection unchanged.

On split desktops, welcome explicitly installs the selected shell and its
matching integration preset together. Stable Pearl selection requests `pearl`
plus `aqueous-shell-pearl`. Git selection requests `pearl-git` plus
`aqueous-shell-pearl-git` or `aqueous-shell-pearl-intel-git`, according to the
welcome build. Both packages
must be reported installed before setup completes. Git welcome retains its Git
preset choice when recovering from a missing session runtime.

Welcome launches `shelly` directly. When Shelly's elevation process requests a
password, a GTK popup collects it and replies through a private controlling
terminal. Package questions travel over separate framed stdin/stdout pipes.
All optional dependencies offered by Shelly are selected automatically, including
for explicitly selected catalog applications. `--no-confirm` is intentionally
omitted because its current optional-dependency default selects none.

The tested transport matches Shelly-ALPM source `7b0e1007`: JSON/base64 frames,
`q.optdeps`/`a.optdeps`, and `alpm.info.EventType` transaction results. Shelly owns
sudo elevation (`SHELLY_ELEVATOR=sudo`). Its standard C-locale sudo password prompt
is supported, including retries; customized/MFA prompts produce an explicit
unsupported-authentication error. Welcome does not invoke sudo/pkexec itself,
use an askpass helper, or require a polkit agent. Passwords are never written to
argv, environment, logs, or the journal. The worker does not cache credentials.

## Setup and session behavior

The flow detects the existing selection and installed packages, reviews changes,
installs through Shelly, verifies installation, applies recognized Aqueous action
and custom-binding updates through `aqueous-config`, and writes the next-login
selection to `$XDG_CONFIG_HOME/aqueous/session.toml`:

```toml
version = 1
shell = "pearl" # pearl, dms, noctalia, none
```

The session init records the active choice under
`$XDG_RUNTIME_DIR/aqueous/welcome-session.json`. `aqueous-shell-action` routes
launcher, screenshot, lock, and portal actions using that active choice, so
choosing another desktop leaves the current session usable until the next login.
Shell defaults are seeded only when missing. Pearl and DMS create their own
preferences on launch; Noctalia uses the packaged Aqueous profile.

The shared Arch installer stages conditional `aqueous-pearl.service`,
`aqueous-dms.service`, and `aqueous-noctalia.service` units. Drop-ins prevent the
upstream shell units from starting a second instance inside Aqueous, while
preserving their use in other desktop sessions. Custom user startup conflicts
are reported before changes. Startup failure opens welcome for recovery.

Nothing retains Ghostty (`Super+Return`), native compositor controls and a GTK
portal picker. `Super+Shift+F1` opens welcome with the packaged bindings. No
locker is configured in Nothing; its lock action explains that in welcome.
Screenshots use grim/slurp/wl-copy independently of the shell. Existing custom
portal commands are kept; recognized legacy DMS/Noctalia chooser commands are
updated without replacing unrelated settings or comments.

Completing setup writes the existing `welcome-v1` completion marker and
`org.aqueous.Welcome.desktop` autostart override. Manual launching always opens.
The GTK window stays open with the result until closed. Closing during a package
transaction is deferred: use Cancel setup and wait for the active transaction
to finish. Declining a pending password/package question cancels that operation.

## Recovery

`$XDG_STATE_HOME/aqueous/welcome-operation.json` records configuration-write intent
before mutation. Reopening setup reconciles an interrupted operation against the
actual files. It restores only matching changes and reports concurrent edits
instead of overwriting them. Canonical helper backups are kept under
`$XDG_STATE_HOME/aqueous/welcome-backups/`. Installed packages are retained after
a later configuration failure. A failed/cancelled run never marks setup complete.

A per-user lock prevents concurrent setup transactions. An unavailable Shelly
backend, denied authentication, failed install, or stale configuration generation
produces a recoverable error. Nothing works without querying Shelly.
Pearl requires the inspected helper 0.8.0 configuration capability set.

## Build and verification

Build with Zig 0.16, GTK4 development packages and pkg-config. The native worker
integration tests additionally require Bash, jq and standard Unix utilities.
The generated GTK/GLib/GIO bindings are pinned in `build.zig.zon`. The frontend
has no Quark or direct Vulkan dependency. `src/setup.zig` runs inside the same
executable in `--worker` mode, before GTK initializes. Its modules implement
Shelly transport, configuration review, recovery journals and legacy session
selection. The UI starts its own executable and exchanges bounded JSON lines
with that child; no Python worker is installed or required at runtime.

Split packages delegate session selection and action dispatch to the session
component's shell runtime. Legacy session launchers call
`aqueous-welcome --worker prepare-session`, `condition`, `external-condition`
and `action`. Recovery journals retain their version-1 format, including base64
file backups, so native setup can recover operations begun by the former worker.

```sh
zig build -Doptimize=ReleaseSafe
zig build test
zig build run
# From the repository root:
python3 packaging/tests/test-dms-git-packaging.py
bash packaging/tests/test-aqueous-init.sh
```

To test the full GTK flow with fake Shelly packages, password requests, and the
real configuration helper, build a diagnostic Aqueous compositor with
`-Dvulkan-effects=false` and run:

```sh
zig build --build-file settingsApplication/build.zig
zig build --build-file welcome/build.zig -Dtest-hooks=true
AQUEOUS_COMPOSITOR_BIN=/path/to/diagnostic/aqueous python3 welcome/tests/smoke-gtk.py
# Rebuild the distributable executable with test hooks disabled:
zig build --build-file welcome/build.zig -Doptimize=ReleaseSafe
```

The smoke test requires a private Wayland/D-Bus socket namespace and grim. It
creates only temporary profiles and fake package installations, exercises all
four choices, and saves screenshots/logs under its printed `/tmp` directory.
Test hooks are disabled by default and are never enabled by package builds.

Verified during the native worker port: 13 Zig unit tests, shell integration
tests covering authentication, cancellation/disconnection during commit, stale
replies and generations, all 16 session transitions, legacy journal recovery,
custom configuration preservation and split-runtime delegation; six legacy
source-package staging fixtures, component packaging checks, existing init tests,
Nix evaluation, GTK rendering and picker selection,
and all four complete GTK setup flows using fake Shelly plus real aqueous-config.
Actual package downloads/installation, physical desktop login, hardware behavior,
and accessibility with a screen reader remain release acceptance checks.

## Add applications

Add a `catalog.Section` under `src/sections/` and register it in `src/sections.zig`.
Package identities are explicit data (backend and name), never shell fragments.
The GTK frontend passes selected identities to the worker as argv elements.
Shell source installation is currently Arch-specific; NixOS and Fedora retain
their existing setup paths.
