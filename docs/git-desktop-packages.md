# Git desktop meta packages

`aqueous-desktop-git` installs a complete optional desktop around its matching
[Git core](git-packages.md). It coexists with stable Aqueous and the legacy
combined packages. x86_64 builds require x86-64-v3 on Intel or AMD; aarch64
builds retain the baseline CPU target. The separate Intel recipes are retired. The package names
`aqueous-git` and `aqueous-git-intel` belong to previously published legacy
desktop packages whose recipes have been retired.

| Meta package | Core dependency | Login entry |
| --- | --- | --- |
| `aqueous-desktop-git` | `aqueous-core-git` | Aqueous-Git |

Each meta package pulls in session, a private screen capture
portal, and DMS/Noctalia/Pearl integration packages for its channel. Integrations
contain conditional services, not the shells themselves. Installing the meta
package does not choose a shell, enable DMS, replace the login manager, or modify
personal configuration. Welcome is no longer built or installed. Existing shell
selections are retained; a fresh session starts without a shell. Select a shell
as described below. The session conflicts with the obsolete `aqueous-welcome-git`
package so upgrades remove its worker and system autostart entry.

## Build and install from source

The recipes fetch upstream Git. Publish these source changes first. The desktop
requires its matching Git core at version `0.7.0` or newer. Core is a separate
VCS recipe, so it does not need to have the desktop's commit/version. Components
within the desktop recipe retain exact version/release dependencies. Use a normal Arch build environment with
base-devel and the declared dependencies; any selected shell must
also be available to the package manager. These recipes have not automatically
been published to the AUR or a binary repository.

From the repository root, in Bash:

```bash
channel=git
repo=$PWD
core="$repo/packaging/arch/aqueous-core-$channel"
desktop="$repo/packaging/arch/aqueous-desktop-$channel"

(cd "$core" && makepkg -s)
(cd "$desktop" && makepkg -s)

# Install the core and desktop cohort together. Shell presets remain optional.
mapfile -t core_packages < <(cd "$core" && makepkg --packagelist)
mapfile -t desktop_packages < <(
    cd "$desktop" && makepkg --packagelist | awk '!/\/aqueous-shell-(dms|noctalia|pearl)-git-/'
)
sudo pacman -U "${core_packages[@]}" "${desktop_packages[@]}"
```

Stop if either build fails. Install all desktop components from the same build.
Do not use `makepkg -si` in the desktop
split recipe: it would request all its optional shell preset packages as well.

Once the packages are published in a configured binary repository, the entry
point becomes `sudo pacman -S aqueous-desktop-git`. An AUR publication likewise
requires publishing the
matching core recipe; dependency solving must be able to find both package bases.

For Remora/Shelly isolated builds, publish the core in a configured repository
before queuing the desktop. An exact dependency on the desktop's `$pkgver` would
ask for its placeholder version during pre-build review, before `pkgver()` runs.
If Shelly reports `IsolatedAurDependencyUnsupported` for the core, check that
the uploaded desktop recipe has the minimum-version dependency above and that
the core is present in the repository database used by the build server.

After installation, log out and select **Aqueous-Git**.
The stable login entry continues to launch stable Aqueous. The session starts
through UWSM and finalizes the live Git toolchain and compositor endpoints before
graphical services start. No manual service enabling is required.

## Optional shell presets

Each recipe also builds these dependency-only presets:

| Shell | Git preset |
| --- | --- |
| Pearl | `aqueous-shell-pearl-git` |
| DMS | `aqueous-shell-dms-git` |
| Noctalia | `aqueous-shell-noctalia-git` |

Install the chosen preset and its runtime dependencies through your package
manager. Pearl requires `pearl-git`; DMS requires `dms-shell`; Noctalia requires
`noctalia`. Installing the desktop alone does not require any of these shells.

Create or edit `$XDG_CONFIG_HOME/aqueous-git/session.toml`
(default `~/.config/aqueous-git/session.toml`):

```toml
version = 1
shell = "pearl"
```

Valid values are `pearl`, `dms`, `noctalia`, and `none`. Log out and back in after
changing the selection. Shell-specific settings are preserved. Live
`aqueousctl-git shell switch` is retired with Welcome; it reports these manual
selection instructions. With no shell selected, the launcher action opens
Ghostty and no screen locker is configured.

Git packages do not build or install `aqueous-portal-picker-git`. Pearl uses its
own capture picker and Noctalia uses its own picker. DMS and shell-free sessions
have no default screen-sharing chooser: requests return no capture source until
you configure one. Set `chooser_type=dmenu` and `chooser_cmd` in
`${XDG_CONFIG_HOME:-$HOME/.config}/xdg-desktop-portal-aqueous-git/config` to a
command that reads the source list from stdin and prints the selected original
line. This file overrides the system portal config; retain any other settings
you need. Restart the Git portal or log out and back in after changing it. The Git DMS integration does not
install or enable the stable DMS portal/appearance plugins. Existing shell and
application preferences are shared with their normal installations and retained;
the Git packages isolate Aqueous-owned configuration rather than changing every
application's XDG directories.

## Coexistence contract

- Configuration uses `aqueous-git` under the normal XDG config root.
  Stable shell selections are not migrated.
- Login entries, UWSM defaults, shell
  units and desktop-specific portal preference files have separate names.
- The portals own separate D-Bus names, executables and config directories:
  `org.freedesktop.impl.portal.desktop.aqueous_git` is the Git portal identity.
- Git shell units test the matching desktop and the saved active selection.
  Separate conditional drop-ins prevent a globally enabled shell service from
  starting a second copy within that Git session.
- The core's private PATH and library path are exported to session services so
  unsuffixed tool calls inside the Git desktop reach its matching core binaries.
- Each Git component declares `replaces` for its corresponding retired
  `-intel-git` package, including the desktop meta package and shell presets.
  Stable and older combined legacy packages remain independent.
- Package replacement does not migrate Intel configuration or state from
  `aqueous-intel-git` to `aqueous-git`; the login entry is now **Aqueous-Git**.

The supported workflow is choosing one graphical desktop per user login. This
does not promise simultaneous full desktops on one user's shared systemd/D-Bus
session manager. Standalone nested core experiments remain a separate workflow.

## Verification

```sh
bash packaging/tests/test-git-desktop.sh
bash packaging/tests/test-git-desktop.sh PORTAL_DIST git PORTAL_LICENSE
```

The tests compare component ownership with stable and Git, check
meta dependencies and desktop identities, exercise shell selection, and verify
that Welcome and the standalone picker are absent from package output, and
that unsupported chooser requests produce no capture source. Real artifact
checks verify the compiled portal identity and exercise session startup with mocked
compositor/service commands. No host packages or services are changed by these
tests. Real display-manager login, hardware capture and third-party shell
acceptance remain separate release checks.
