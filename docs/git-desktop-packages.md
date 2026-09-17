# Git desktop meta packages

`aqueous-desktop-git` and `aqueous-desktop-intel-git` install a complete optional
desktop around their matching [Git core](git-packages.md). They coexist with
stable Aqueous, the legacy combined packages, and each other. The package names
`aqueous-git` and `aqueous-git-intel` belong to previously published legacy
desktop packages whose recipes have been retired.

| Meta package | Core dependency | Login entry | Welcome command |
| --- | --- | --- | --- |
| `aqueous-desktop-git` | `aqueous-core-git` | Aqueous-Git | `aqueous-welcome-git` |
| `aqueous-desktop-intel-git` | `aqueous-core-intel-git` | Aqueous-Intel-Git | `aqueous-welcome-intel-git` |

Each meta package pulls in session, native welcome, a private screen capture
portal, and DMS/Noctalia/Pearl integration packages for its channel. Integrations
contain conditional services, not the shells themselves. Installing the meta
package does not choose a shell, enable DMS, replace the login manager, or modify
personal configuration. At first login, welcome offers Pearl, DMS, Noctalia or
Nothing. Existing selections and personal files are retained.

## Build and install from source

The recipes fetch upstream Git. Publish these source changes first. The desktop
requires its matching Git core at version `0.7.0` or newer. Core is a separate
VCS recipe, so it does not need to have the desktop's commit/version. Components
within the desktop recipe retain exact version/release dependencies. Use a normal Arch build environment with
base-devel and the declared dependencies; Shelly and any selected shell must
also be available to the package manager. These recipes have not automatically
been published to the AUR or a binary repository.

From the repository root, in Bash:

```bash
channel=git                  # use intel-git for the Intel variant
repo=$PWD
core="$repo/packaging/arch/aqueous-core-$channel"
desktop="$repo/packaging/arch/aqueous-desktop-$channel"

(cd "$core" && makepkg -s)
(cd "$desktop" && makepkg -s)

# Install the core and desktop cohort together. Shell presets remain optional.
mapfile -t core_packages < <(cd "$core" && makepkg --packagelist)
mapfile -t desktop_packages < <(
    cd "$desktop" && makepkg --packagelist | awk '!/\/aqueous-shell-/'
)
sudo pacman -U "${core_packages[@]}" "${desktop_packages[@]}"
```

Stop if either build fails. Install all desktop components from the same build.
Do not use `makepkg -si` in the desktop
split recipe: it would request all its optional shell preset packages as well.

Once the packages are published in a configured binary repository, the entry
point becomes `sudo pacman -S aqueous-desktop-git` (or
`aqueous-desktop-intel-git`). An AUR publication likewise requires publishing the
matching core recipe; dependency solving must be able to find both package bases.

For Remora/Shelly isolated builds, publish the core in a configured repository
before queuing the desktop. An exact dependency on the desktop's `$pkgver` would
ask for its placeholder version during pre-build review, before `pkgver()` runs.
If Shelly reports `IsolatedAurDependencyUnsupported` for the core, check that
the uploaded desktop recipe has the minimum-version dependency above and that
the core is present in the repository database used by the build server.

After installation, log out and select **Aqueous-Git** or **Aqueous-Intel-Git**.
The stable login entry continues to launch stable Aqueous. The session starts
through UWSM and finalizes the live Git toolchain and compositor endpoints before
graphical services start. No manual service enabling is required.

## Optional shell presets

Each recipe also builds these dependency-only presets:

| Shell | Standard Git preset | Intel Git preset |
| --- | --- | --- |
| Pearl | `aqueous-shell-pearl-git` | `aqueous-shell-pearl-intel-git` |
| DMS | `aqueous-shell-dms-git` | `aqueous-shell-dms-intel-git` |
| Noctalia | `aqueous-shell-noctalia-git` | `aqueous-shell-noctalia-intel-git` |

Install a chosen preset archive with `pacman -U`, or make the preset available
through your repository for welcome's reviewed installation flow. Installing a
preset makes a shell available; welcome selects it for the next login. Git
welcome requests both the shell package and the suffixed preset, and uses the
suffixed canonical helper. For Pearl, that means `pearl-git` plus
`aqueous-shell-pearl-git` or `aqueous-shell-pearl-intel-git`. Setup verifies that
both are installed before saving the selection. Both Git variants use
`pearl-git`; stable Aqueous uses `pearl`.

Git screen sharing uses welcome's native picker for DMS, Pearl and Nothing, and
Noctalia's picker when Noctalia is selected. The Git DMS integration does not
install or enable the stable DMS portal/appearance plugins. Existing shell and
application preferences are shared with their normal installations and retained;
the Git packages isolate Aqueous-owned configuration rather than changing every
application's XDG directories.

## Coexistence contract

- Configuration and welcome state use `aqueous-git` or `aqueous-intel-git` under
  the normal XDG config/state roots. Setup does not migrate stable selections.
- Login entries, UWSM defaults, welcome application/autostart identities, shell
  units and desktop-specific portal preference files have separate names.
- The portals own separate D-Bus names, executables and config directories:
  `org.freedesktop.impl.portal.desktop.aqueous_git` and
  `org.freedesktop.impl.portal.desktop.aqueous_intel_git`.
- Git shell units test the matching desktop and the saved active selection.
  Separate conditional drop-ins prevent a globally enabled shell service from
  starting a second copy within that Git session.
- The core's private PATH and library path are exported to session services so
  unsuffixed tool calls inside the Git desktop reach its matching core binaries.
- No package declares replacements or provisions for stable/legacy packages.

The supported workflow is choosing one graphical desktop per user login. This
does not promise simultaneous full desktops on one user's shared systemd/D-Bus
session manager. Standalone nested core experiments remain a separate workflow.

## Verification

```sh
bash packaging/tests/test-git-desktop.sh
zig build --build-file welcome/build.zig test -Dcpu=baseline -Doptimize=ReleaseSafe
bash packaging/tests/test-git-desktop.sh WELCOME_DIST PORTAL_DIST git PORTAL_LICENSE
```

The tests compare component ownership with stable and both Git variants, check
meta dependencies and desktop identities, exercise shell selection, and run the
real welcome worker against isolated helper fixtures. Real artifact checks also
verify the compiled portal identity and exercise session startup with mocked
compositor/service commands. No host packages or services are changed by these
tests. Real display-manager login, hardware capture and third-party shell
acceptance remain separate release checks.
