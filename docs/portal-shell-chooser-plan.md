Portal chooser integration plan — Noctalia and DMS 1.7

Status: chooser configuration, package wiring, the DMS bridge/plugin, and
automated tests are implemented. Noctalia fresh-profile selection/cancellation,
backend config precedence, bridge behavior, staged packaging, and DMS QML
component checks pass. DMS 1.7 is the required target; verification against an
actual 1.7 release and recorder/browser stream startup remain release checks;
the component integration passes prospective 1.7 upstream master commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`.
No Fuzzel, Wofi, or other launcher dependency was introduced. See
`packaging/portal/README.md` for implemented behavior and validation limits.

The intended result is that a fresh Aqueous installation opens a source picker
in its selected shell when an application requests portal screen sharing.
Both monitor and window selection must work. The existing Aqueous portal
backend continues to own capture and PipeWire negotiation.

**1. Establish the supported shell interfaces.**

Noctalia: the installed v5 CLI exposes `noctalia dmenu -p PROMPT`. Its help
confirms that it reads newline-separated choices from stdin and writes the
selection to stdout. Verify this interaction against the minimum Noctalia
package version we will support, including cancellation and shell startup.

DMS: target 1.7. The implemented component and settings-plugin host tests pass
prospective 1.7 upstream master commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3` with its pinned shared-QML commit
`26396ce432d6c71c3f5367438f96f4a8d667e160`. During implementation the upstream
tags endpoint returned v1.6.0 as the newest tag, and `refs/tags/v1.7.0` returned
404. Repeat the tests against the eventual 1.7 tag before release.

First inspect that DMS 1.7 build for a native generic chooser or screencast
picker with a supported request/response interface. If it exists, adapt it
directly. Otherwise implement the dedicated DMS plugin described below.
Do not assume a `dms dmenu` command exists. The checked 1.6 source has plugin
IPC and daemon plugins, but no verified generic stdin/stdout chooser command.

**2. Install an explicit portal configuration for each package variant.**

Add Noctalia and DMS backend configuration templates under `packaging/portal/`.
Install the selected template as
`/etc/xdg/xdg-desktop-portal-aqueous/config` on conventional Linux packages.
Set `chooser_type=dmenu` in both templates. Select the implementation when
building/installing the Aqueous package, rather than choosing whichever shell
binary happens to appear first on PATH.

Noctalia template:

```ini
[screencast]
chooser_type=dmenu
chooser_cmd=noctalia dmenu -p "Select a source to share:"
```

The DMS template will invoke the verified 1.7 native command if suitable;
otherwise invoke the package-owned `/usr/lib/aqueous/aqueous-dms-portal-chooser`
bridge specified in step 4. The same installation path for the selected
template means switching Aqueous package variants also switches their default
chooser, even if both shell executables remain installed.

Make the bundled portal's compiled system configuration directory explicit
and test it. Its pinned 0.8.4 config loader uses `SYSCONFDIR/xdg`; it does not
discover this backend config from `/usr/share/xdg-desktop-portal` or arbitrary
`XDG_CONFIG_DIRS`. Keep router configuration in `aqueous-portals.conf` separate
from this backend chooser configuration.

Preserve upstream precedence: user desktop-specific config, user `config`,
system desktop-specific config, then system `config`. Do not force a backend
`-c` argument, seed user chooser files, or overwrite existing user overrides.
Document that config files are selected as a whole, not merged: an existing
user config can mask new system chooser defaults. Package administrator edits
with the distribution's normal config-file preservation mechanism and explain
how to update the chooser after changing shell variants.

**3. Deliver the Noctalia integration.**

Install the Noctalia template in `PKGBUILD`, `PKGBUILD-git`, `PKGBUILD-intel`,
`GitPKGBUILD/PKGBUILD`, and `IntelPKGBUILD/PKGBUILD`. Include it in the full
release archive in `.github/workflows/release.yml` and make `PKGBUILD-bin`
require and install it. Update `scripts/gentoo-install.sh` as well.

For Nix, install the template through `nix/module.nix`, generate the Noctalia
command with its actual store path, and ensure the backend compiled by
`nix/default.nix` reads the module's `/etc/xdg` file. Respect the existing
`noctalia.enable` option: only select this default when Noctalia is enabled.
Adding a new DMS Nix session option is outside this change's existing package
coverage unless separately requested.

Retain each portal-provided line verbatim when returning a selection. Monitor
descriptions and window identifiers are part of the backend's matching format;
the integration must not replace them with labels generated from `aqueousctl`.
Confirm the command can reach the running shell from the portal's systemd/D-Bus
environment. Diagnose missing shell readiness through stderr/the user journal.

**4. Deliver the DMS 1.7 integration.**

If DMS 1.7 supplies a suitable picker, use its supported API and cover it with
the same behavior tests. If it does not, implement this bounded adapter:

- Add a separate `aqueousPortal` daemon plugin under
  `packaging/portal/dms/`, using the supported DMS 1.7 theme, modal, and plugin
  APIs. It presents the supplied monitor/window entries, searchable by label,
  with keyboard navigation, mouse selection, Enter, Escape, and Cancel.
- Keep it independent of `dms-plugin/`'s optional `aqueousSettings` widget and
  daemon. Recording must work without adding a settings widget to DankBar or
  enabling the settings plugin.
- Add a small bridge executable that reads the backend's choice list from
  stdin, opens a request with the running plugin, waits for selection, and
  writes exactly the original selected line plus a newline to stdout. Build
  it with the repository's existing Zig toolchain; keep its source and protocol
  separate from configuration-editing operations.
- Use a per-request Unix socket under a private directory in
  `XDG_RUNTIME_DIR`. Pass a generated request token through DMS IPC; exchange
  the choice list and selected index over the socket. The plugin must remain
  asynchronous while the bridge waits. Never put titles into shell command
  strings or permit the UI to return an arbitrary output line.
- Bound input size and validate response indices. Clean up on selection,
  cancellation, recorder termination, shell exit, plugin disable/reload, or
  startup failure. Give connection/startup a bounded timeout, while allowing
  a user to take time choosing. Reject overlapping requests with a clear error
  rather than replacing a visible request or mixing responses.
- On explicit cancellation, return no selection. On infrastructure failure,
  return no selection and log a specific error to stderr. The current backend
  may still report cancellation to the application; retain actionable evidence
  in the portal journal and never select an arbitrary monitor as a fallback.

Package the plugin and bridge with `PKGBUILD-DMS`. Verify DMS 1.7's actual system
plugin discovery paths instead of copying the 1.6 layout untested. Arrange
first-use enablement of this dedicated integration through the supported DMS
settings/IPC API after discovery is ready, including for existing Aqueous users
receiving the new plugin. Preserve explicit later disablement and unrelated
plugin/bar settings. Check readiness, not just the exit status of an enable
command. This first-use behavior must be implemented and tested before the DMS
chooser becomes the packaged default.

Update the DMS package requirement to the verified 1.7 version constraint.
Align the existing settings plugin's compatibility metadata, startup checks,
documentation, fixtures, and real-host tests with the required 1.7 baseline;
verify those APIs rather than only changing version strings. Do not label
results from the existing 1.6 host harness as 1.7 validation.

**5. Validate the installed behavior.**

Extend `packaging/tests/test-portal-packaging.sh` to inspect staged package
contents and resolve the actual config and executable paths. Add meaningful
bridge/UI tests where code is introduced. Cover:

| Case | Required result |
| --- | --- |
| Fresh Noctalia install, no other launcher | Noctalia chooser opens and returns the selected monitor or window. |
| Fresh DMS 1.7 install, no settings widget/plugin enabled | DMS picker opens and returns the selected monitor or window. |
| Both shells installed | The Aqueous package variant determines the default chooser. |
| Upgrade or package-variant switch | New system default applies when no user/admin override masks it. |
| Existing user backend configuration | It is preserved and its precedence is documented. |
| Spaces, punctuation, Unicode, duplicate window titles | Exact choice identity survives the round trip. |
| Cancel or application closes its request | No stream begins; picker and request resources are released. |
| Shell absent, starting, restarted, or plugin disabled | No hang or implicit selection; actionable journal output. |
| Concurrent requests | Responses never cross; busy behavior is explicit. |
| Nix/relocated package paths | Config and chooser resolve from the installed runtime environment. |

Run real portal requests with monitor-only, window-only, and combined source
types. Test GPU Screen Recorder's portal mode and a browser/OBS capture request
on fresh profiles; verify a stream actually starts after selection. Repeat on
two outputs and confirm the chosen source. Use the current packaging checks
plus targeted shell/bridge tests; the existing backend-identity string checks
alone cannot detect this regression.

**6. Ship and document.**

Deliver shared config/packaging work and Noctalia support first, then the
verified DMS 1.7 adapter and its package wiring. Each variant must pass its
fresh-profile capture test before its new default ships. Update
`packaging/portal/README.md` and installation notes with the default chooser,
override paths, shell-switch behavior, plugin disablement behavior, and journal
diagnostics. Recommend logging out/in after upgrading; avoid restarting an
active capture from package installation hooks.

Evidence used for planning:

- Local `noctalia dmenu --help` verified stdin/stdout behavior.
- [Pinned portal chooser implementation](https://github.com/emersion/xdg-desktop-portal-wlr/blob/v0.8.4/src/screencast/chooser.c).
- [Pinned portal config lookup](https://github.com/emersion/xdg-desktop-portal-wlr/blob/v0.8.4/src/core/config.c).
- [DMS plugin IPC at the prospective 1.7 commit](https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/DMSShellIPC.qml).
- [DMS upstream tags](https://github.com/AvengeMedia/DankMaterialShell/tags).
