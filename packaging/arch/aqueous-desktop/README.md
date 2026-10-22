# Aqueous desktop for Arch

This [PKGBUILD](PKGBUILD) builds the stable Pearl desktop using the same six
components as the [Devario recipe](../../devario/aqueous-desktop/):

| Package | Contents or purpose |
| --- | --- |
| `aqueous-core` | Compositor, private wlroots library, `aqueousctl` and `aqueous-config` |
| `aqueous-session` | Login session, runtime and desktop configuration |
| `aqueous-integration-pearl` | Pearl integration service |
| `aqueous-shell-pearl` | Pearl and capture picker dependency preset |
| `xdg-desktop-portal-aqueous` | Screen-sharing portal and standalone GTK source picker |
| `aqueous-desktop` | Full desktop preset and `/etc/xdg/aqueous/session.toml`, selecting Pearl |

Install `aqueous-desktop` and select **Aqueous** at login. Pearl supplies the
shell and settings UI. The preset requires `pearl`, `pearl-greeter` and `rtkit`;
Pearl's Arch package supplies the `pearl-capture-picker>=1` capability.
`aqueous-core` provides the versioned `aqueous` dependency needed by Pearl and
its greeter. The Arch preset does not depend on Devario's OS integration package.

Release `1.0.5-2` switches from the Welcome-based shell chooser to this Pearl
preset. It replaces the retired `aqueous-welcome`, `aqueous-shell-none`,
`aqueous-integration-dms`, `aqueous-integration-noctalia`, `aqueous-shell-dms`
and `aqueous-shell-noctalia` packages so their old component version pins do
not block upgrades. DMS and Noctalia applications are not removed.

Existing user configuration remains unchanged and overrides system defaults.
If `~/.config/aqueous/session.toml` selects another shell, change its selection
to `shell = "pearl"` while retaining `version = 1`, then log out and select
**Aqueous** again. Review any `.pacnew` files before merging system settings.
The Welcome app and its shell chooser are no longer built or installed.

Build with Shelly from this directory:

```sh
shelly build --makesrcinfo --reviewed PKGBUILD > .SRCINFO
shelly build --isolated --sync-deps --check --json PKGBUILD > build-result.json
```

Publish the release tag `v${pkgver}` before building. The build requires Zig
0.16.0 and targets x86-64-v3 on x86_64 and baseline on aarch64. It includes the
private wlroots library and Aqueous portal backend, with the standalone picker.
Publish all six archives together, including the `any` packages. Component
dependencies use exact versions; the desktop preset accepts its component
versions or newer. Pearl, Pearl Greeter and RTKit must be available separately.

For the development desktop, see [aqueous-desktop-git](../aqueous-desktop-git/).
