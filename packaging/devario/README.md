# Devario packages

This directory follows the three-recipe layout in `packaging/arch`, with
Devario maintainers, Shelly builds, Zig `0.16.0` and Pearl desktop defaults.
Each recipe has its own `PKGBUILD` and `.SRCINFO`.

| Recipe | Outputs | Purpose |
| --- | --- | --- |
| `aqueous/` | `aqueous` | Minimal stable compositor, including the dependency used by Pearl Greeter |
| `aqueous-desktop/` | `aqueous-core`, `aqueous-session`, `xdg-desktop-portal-aqueous`, `aqueous-integration-pearl`, `aqueous-shell-pearl`, `devario-desktop` | Complete stable Devario Pearl desktop |
| `aqueous-desktop-git/` | `aqueous-core-git`, `aqueous-session-git`, `xdg-desktop-portal-aqueous-git`, `aqueous-integration-pearl-git`, `aqueous-shell-pearl-git`, `devario-desktop-git` | Development replacement for the stable desktop using Pearl Git |

The stable recipes fetch `v1.0.7`; publish that tag before building them.
`aqueous` is compositor-only. `aqueous-core` provides `aqueous` and conflicts
with the minimal package because they own the same compositor files.
The Git packages replace their stable counterparts and install the same
Aqueous commands, private libraries, services and configuration paths. Their
package names retain `-git` to identify development builds; the installed
Aqueous desktop identity is unsuffixed. `aqueous-core-git` provides both
`aqueous-core` and `aqueous` and conflicts with the stable core and minimal
compositor.

The desktop builds contain no Welcome app, DMS or Noctalia outputs. Both
builds include the standalone GTK screen-sharing picker at
`/usr/bin/aqueous-portal-picker`. Pearl uses its own capture picker; both presets
require `pearl-capture-picker>=1`, provided by Devario's `pearl` or `pearl-git`.
The Git preset selects `pearl-git` and retains its separate Pearl command,
service and picker paths. Both desktop presets depend on `pearl-greeter`;
its `aqueous` dependency is satisfied by either desktop core, so the Git
desktop does not need a separate stable compositor.

## Build with Shelly

Run these commands from `packaging/devario` to generate stable metadata and
build the complete stable desktop:

```sh
shelly build --makesrcinfo --reviewed aqueous-desktop/PKGBUILD > aqueous-desktop/.SRCINFO
shelly build --isolated --sync-deps --check --json aqueous-desktop/PKGBUILD > build-result.json
```

Use `aqueous/PKGBUILD` for the minimal stable compositor or
`aqueous-desktop-git/PKGBUILD` for the development desktop. Shelly's
`--makesrcinfo` prepares VCS sources and updates `pkgver()` for the Git recipe,
so refreshing Git metadata requires source access. For an offline comparison
of its checked-in version, use `makepkg --printsrcinfo` from
`aqueous-desktop-git/`. The Git version follows the most recent tag and
commit count, rather than the stable manifest version.

Shelly resolves shared `makedepends` and `checkdepends` before executing package
functions. Sibling dependencies and Pearl runtime dependencies are declared in
individual package functions; the shared build does not require published
Aqueous siblings or Pearl. Each desktop build produces six archives. Collect
every entry in the successful JSON result's `artifacts` array, including the
architecture-independent packages, and publish the complete set together.

Publish `pearl` and `pearl-greeter` before installing the stable desktop;
publish `pearl-git` for the Git desktop. The shell packages must provide
`pearl-capture-picker>=1`; the picker need not be a separate package. Standard
build and runtime dependencies come from configured
Devario repositories. These recipes do not rebuild those dependencies.

Compiled packages target x86-64-v3 on x86_64 and baseline aarch64. Configuration
and dependency-only packages use `any`. Pearl's recipes currently support
x86_64, so the complete Pearl desktop targets x86_64. The core package functions
remove temporary build paths from the installed compositor's RUNPATH with
`patchelf` and verify `$ORIGIN/../lib/aqueous`.

## Defaults and migration

`devario-desktop` and `devario-desktop-git` each own
`/etc/xdg/aqueous/session.toml` and conflict with one another. Both select Pearl,
preserve user overrides
and register the system file as a package backup. Their package functions do
not activate services. Pearl Greeter handles its own greeter setup. Select
**Aqueous** at login for either channel.

Replace the former `aqueous-devario/PKGBUILD` and top-level `PKGBUILD` build
jobs with one `aqueous-desktop/PKGBUILD` job. Its package base is
`aqueous-desktop`, while the installed desktop preset remains
`devario-desktop`. The six existing package names now share version `1.0.7-1`.
The Aqueous components use exact sibling dependency pins. `devario-desktop`
requires those components at its build version or newer (currently `>=1.0.7-1`),
so an installed desktop preset accepts future Aqueous releases. Publish the
updated preset once to replace its previous exact pins. The package base is a build identity;
there is no separate `aqueous-desktop` output on Devario. Update `pkgver` or
`pkgrel` once in this recipe and regenerate its `.SRCINFO` when releasing the
stable desktop. The minimal and Git recipes have independent revisions.
The Git recipe's base and folder are `aqueous-desktop-git`, mirroring the
stable `aqueous-desktop` recipe. The installed preset is `devario-desktop-git`,
mirroring `devario-desktop`; the base name is a build identity, and the recipe
emits no package named `aqueous-desktop-git`. The preset replaces, conflicts
with and provides both former preset names, `aqueous-git` and the legacy
combined `aqueous-desktop-git` package, so a normal upgrade performs the
rename. Installing `devario-desktop-git` explicitly replaces conflicting stable
components; stable packages are not automatically switched to Git just because
the development repository is enabled. The old co-installable Git session and
commands are removed when their owning packages upgrade. Existing stable user
configuration remains at `~/.config/aqueous`; users of the old Git session
should review and merge any wanted `~/.config/aqueous-git` settings there.
Package upgrades do not move user configuration. Log out and select **Aqueous**
after switching channels.
