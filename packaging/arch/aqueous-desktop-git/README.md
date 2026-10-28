# Aqueous desktop Git for Arch

This [PKGBUILD](PKGBUILD) adapts the [Devario Git desktop](../../devario/aqueous-desktop-git/)
for Arch, with Pearl Git selected by default. It builds six packages:

| Package | Contents or purpose |
| --- | --- |
| `aqueous-core-git` | Compositor, private wlroots library, configuration helper and control client |
| `aqueous-session-git` | Standard Aqueous login session, runtime and configuration |
| `xdg-desktop-portal-aqueous-git` | Screen-sharing portal and standalone GTK source picker |
| `aqueous-integration-pearl-git` | Pearl Git service integration |
| `aqueous-shell-pearl-git` | Pearl Git dependency preset |
| `aqueous-desktop-git` | Full desktop preset and `/etc/xdg/aqueous/session.toml` |

Install `aqueous-desktop-git` and select **Aqueous** at login. As in the Devario
recipe, Git components provide and conflict with their stable counterparts.
They install standard Aqueous commands, services and configuration paths;
installing this desktop replaces the stable desktop. Stable users are not
automatically switched to Git.

This is an alternative to [`../aqueous-git/`](../aqueous-git/), which builds a
desktop that can coexist with stable and offers optional shell presets. The
two recipes share component package names and must not be published together
in the same repository. This preset replaces the old `aqueous-git` preset.
When switching from it, review and merge wanted settings from
`~/.config/aqueous-git` into `~/.config/aqueous`; packaging does not migrate
user configuration.

Pearl's Arch `pearl-git` package provides `pearl-capture-picker-git=1`.
The session uses its suffixed commands, services and picker path. The desktop
also depends on `pearl-greeter` and `rtkit`, which must be available separately.
The greeter's `aqueous` dependency is supplied by `aqueous-core-git`.
Publish all six desktop packages together; component dependencies use exact
versions, while the desktop preset accepts its component versions or newer.

Build with Shelly from this directory:

```sh
shelly build --makesrcinfo --reviewed PKGBUILD > .SRCINFO
shelly build --isolated --sync-deps --check --json PKGBUILD > build-result.json
```

Metadata generation refreshes Git sources and requires source access.
`pkgver()` derives the version from Git tags and commits. The build requires
Zig 0.17.0, targets x86-64-v3 on x86_64 and baseline on aarch64, and includes
the private wlroots library and Aqueous portal backend. It builds the
standalone picker without the Welcome app; Pearl supplies the settings UI.
