# Aqueous desktop Git: development Devario desktop

Use this [PKGBUILD](PKGBUILD) to build the current Aqueous Git sources with
Pearl Git integration. `aqueous-desktop-git` is the package base and folder
name; like the stable recipe's `aqueous-desktop`, it is a build identity, and
this Devario recipe does not produce an installable package with that name.
It builds six packages:

| Package | Contents or purpose |
| --- | --- |
| `aqueous-core-git` | Development compositor, private libraries, configuration helper and control client |
| `aqueous-session-git` | Standard Aqueous login session, runtime and configuration |
| `xdg-desktop-portal-aqueous-git` | Git screen capture portal and standalone GTK source picker |
| `aqueous-integration-pearl-git` | Pearl integration for the Git session |
| `aqueous-shell-pearl-git` | Dependency preset selecting `pearl-git` and its `pearl-capture-picker>=1` capability |
| `devario-desktop-git` | Full development desktop preset and `/etc/xdg/aqueous/session.toml`, replacing the former preset name `aqueous-git` |

Install `devario-desktop-git` for the full development desktop and select
**Aqueous** at login. It replaces the former `aqueous-git` preset and the
legacy `aqueous-desktop-git` through package `replaces`, so a normal upgrade
renames installed systems. The Git packages provide and conflict with their
stable counterparts,
installing standard Aqueous commands, services, private libraries and
configuration paths. Package names keep `-git`; installed Aqueous files do not.
Installing this preset replaces the stable desktop. Stable users are not
switched automatically merely by enabling the development repository.

When upgrading the former co-installable Git desktop, select **Aqueous** at
login. Review and merge any wanted settings from `~/.config/aqueous-git` into
`~/.config/aqueous`; package upgrades do not move user configuration.

This recipe depends on the stable `pearl-greeter` package. Its compositor
dependency is satisfied by `aqueous-core-git`, which provides the versioned
`aqueous` capability and installs `/usr/bin/aqueous`. No separate stable
compositor is needed.

To build, run from this directory:

```sh
shelly build --makesrcinfo --reviewed PKGBUILD > .SRCINFO
shelly build --isolated --sync-deps --check --json PKGBUILD > build-result.json
```

Metadata generation with Shelly refreshes the Git sources and requires source
access. `pkgver()` derives the version from the latest tag, commit count and
commit hash; it does not use the stable release manifest version. For an
offline metadata refresh using the checked-in version, use
`makepkg --printsrcinfo > .SRCINFO`.

The Git components use exact sibling dependency versions. Like the stable
desktop preset, `devario-desktop-git` accepts its component versions or newer and
depends on `rtkit`. Publish all six archives together when updating them.
`pearl-git`, `pearl-greeter` and `rtkit` must be available separately for
installation; this recipe does not build them. Devario's `pearl-git` supplies
`pearl-capture-picker=1`. Its own suffixed Pearl commands, services and picker
path remain referenced by the Aqueous session and integration service.

See the [Devario packaging guide](../README.md) for shared build requirements
and validation.
