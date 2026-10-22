# Aqueous desktop: complete stable Devario desktop

Use this [PKGBUILD](PKGBUILD) to build the stable Aqueous desktop with Pearl
integration. It builds all six packages in one invocation:

| Package | Contents or purpose |
| --- | --- |
| `aqueous-core` | Compositor, private wlroots library, `aqueousctl` and `aqueous-config` |
| `aqueous-session` | Login session, session runtime and desktop configuration |
| `xdg-desktop-portal-aqueous` | Screen capture portal and standalone GTK source picker |
| `aqueous-integration-pearl` | Pearl integration service |
| `aqueous-shell-pearl` | Dependency preset selecting Pearl and its capture picker |
| `devario-desktop` | Desktop dependency preset and `/etc/xdg/aqueous/session.toml`, selecting Pearl |

`aqueous-desktop` is the package base and folder name; this Devario recipe
does not produce an installable package with that name. Install
`devario-desktop` for the full desktop. In `devario-core/devario-desktop`,
`devario-core` is the repository name and `devario-desktop` is the package.

`aqueous-core` provides `aqueous` and conflicts with the
[standalone aqueous package](../aqueous/README.md). It already supplies the
stable compositor required by Pearl Greeter.

To build, run from this directory:

```sh
shelly build --makesrcinfo --reviewed PKGBUILD > .SRCINFO
shelly build --isolated --sync-deps --check --json PKGBUILD > build-result.json
```

Publish the release tag `v${pkgver}` before building. Collect all six archives
from the build result's `artifacts` array, including packages with architecture
`any`, and publish them together. Pearl, `pearl-capture-picker` and
`pearl-greeter` are separate packages that must be available for installation;
this recipe does not build them. Select **Aqueous** at login.

Release `1.0.4-3` adds `rtkit` to `devario-desktop` so existing installations
receive realtime audio support through `sudo shelly upgrade standard` after
publication. Reboot after upgrading. RTKit activates through D-Bus on demand.
Publish all six outputs together and ensure RTKit is available in the repository.

The Aqueous components use exact versions for their sibling dependencies.
`devario-desktop` uses `>=${pkgver}-${pkgrel}` for its five Aqueous dependencies,
so an installed preset accepts newer component releases. It does not require
republishing solely because Aqueous or Pearl receives a version bump. The
`pearl` and `pearl-greeter` dependencies have no version constraints.

This recipe supplies `devario-desktop` from the Aqueous repository. The legacy
`devario-aqueous-desktop` package is a different package and conflicts with it.
For the development desktop, see [aqueous-desktop-git](../aqueous-desktop-git/README.md).
See the [Devario packaging guide](../README.md) for validation and migration.
