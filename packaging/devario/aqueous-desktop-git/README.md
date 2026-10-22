# Aqueous Git: development Devario desktop

Use this [PKGBUILD](PKGBUILD) to build the current Aqueous Git sources with
Pearl Git integration. It builds six packages:

| Package | Contents or purpose |
| --- | --- |
| `aqueous-core-git` | Development compositor, private libraries, configuration helper and control client |
| `aqueous-session-git` | Separate Git login session, runtime and configuration |
| `xdg-desktop-portal-aqueous-git` | Git screen capture portal |
| `aqueous-integration-pearl-git` | Pearl integration for the Git session |
| `aqueous-shell-pearl-git` | Dependency preset selecting `pearl-git` and `pearl-capture-picker-git` |
| `aqueous-git` | Full development desktop preset and `/etc/xdg/aqueous-git/session.toml` |

Install `aqueous-git` for the full development desktop and select
**Aqueous-Git** at login. Its commands, services, private libraries and
configuration paths are separated from stable Aqueous, allowing both
installations to coexist.

This recipe depends on the stable `pearl-greeter` package. Its compositor
dependency still needs either [standalone aqueous](../aqueous/README.md)
or `aqueous-core` from [aqueous-desktop](../aqueous-desktop/README.md).
`aqueous-core-git` does not provide the unsuffixed `aqueous` dependency.

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

The Git packages, including the `aqueous-git` desktop preset, use exact sibling
dependency versions. Publish all six archives together when updating them.
`pearl-git`, `pearl-capture-picker-git` and `pearl-greeter` must be available
separately for installation; this recipe does not build them.

See the [Devario packaging guide](../README.md) for shared build requirements
and validation.
