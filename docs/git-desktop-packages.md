# Aqueous Git split package

`packaging/arch/aqueous-git/PKGBUILD` is the single source recipe for the Git
compositor and desktop. Its package base and desktop meta package are both
named `aqueous-git`. One build produces eleven packages: core, session, portal,
three shell integrations, four shell presets (including `none`), and the meta
package. Every internal dependency uses the same version and release.

Installing `aqueous-git` pulls in the core, session, portal, integrations and
shell-free preset. Pearl, DMS and Noctalia remain optional. Welcome and the
standalone portal picker are neither built nor installed. Existing shell
selections are retained; a fresh session starts without a shell.

The `aqueous-core-git` output can still be installed independently. It provides
`aqueous-git`, `aqueousctl-git`, and `aqueous-config-git` commands under private
paths. The desktop login entry is **Aqueous-Git**. x86_64 builds require
x86-64-v3 on Intel or AMD; aarch64 retains the baseline CPU target.

## Build and install from source

Use an Arch build environment with `base-devel` and the declared dependencies.
The recipe fetches upstream Git; publish source changes before building against
upstream. Shell packages are only required when installing their optional
presets. From the repository root:

```bash
cd packaging/arch/aqueous-git
makepkg -s
```

After a successful build, install the default desktop packages together:

```bash
mapfile -t packages < <(
    makepkg --packagelist | awk '!/\/aqueous-shell-(dms|noctalia|pearl)-git-/'
)
sudo pacman -U "${packages[@]}"
```

The filter includes `aqueous-shell-none-git` and excludes the three optional
shell presets. `makepkg -si` would install every split output, including all
three shells. Keep components from the same build together.

For AUR or Remora/Shelly builds, publish this directory's `PKGBUILD` and
`.SRCINFO` under the single `aqueous-git` package base. There is no separate core
recipe to build or publish first. Once all split outputs are available in a
configured binary repository, install with `sudo pacman -S aqueous-git`.
These changes do not themselves publish packages.

Log out and select **Aqueous-Git**. The session starts through UWSM and exports
its private toolchain and compositor endpoints before graphical services start.
No manual service enabling is required.

## Upgrade and coexistence

`aqueous-git` replaces and provides the former `aqueous-desktop-git` meta
package. The old core and desktop recipe directories are retired; their
component package names stay the same. The session conflicts with obsolete
`aqueous-welcome-git`, allowing its worker and system autostart entry to be
removed during the upgrade.

The `aqueous-git` name was previously used by a combined legacy package with
unsuffixed files. Starting at `1.0.2.r6`, it names this split desktop meta
package. Upgrading that legacy package removes its old payload and installs
the suffixed Git components. Select **Aqueous-Git** and configure its private
session; personal stable configuration is retained but not migrated.

Stable recipes now limit their legacy conflict to `aqueous-git<1.0.2.r6`.
Installed stable packages with an older, unversioned conflict need updated
package metadata before they can coexist with the new meta package.

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

The supported workflow is choosing one graphical desktop per user login. This
does not promise simultaneous full desktops on one user's shared systemd/D-Bus
session manager. Standalone nested core experiments remain a separate workflow.

## Verification

```sh
python3 packaging/tests/test-arch-git-split.py
bash packaging/tests/test-git-packages.sh
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
