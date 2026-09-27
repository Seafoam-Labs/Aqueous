# Devario desktop

`devario-desktop` installs stable Aqueous `0.9.1` with Pearl. It depends directly
on the core, session, portal and Pearl integration/preset packages,
without Welcome, the general `aqueous-desktop` meta package or DMS/Noctalia
integrations, presets or shells.

The portal package includes `aqueous-portal-picker`, a standalone GTK source
picker. Pearl screen sharing and normal session startup do not require Welcome.
The `v0.9.1` tag and component packages must include this picker separation.

The package installs `/etc/xdg/aqueous/session.toml` selecting Pearl. Aqueous uses
this default when a user has no `~/.config/aqueous/session.toml`; existing user
choices take precedence. Pacman preserves edits to the system default through
its normal backup handling. Installation does not enable services or change the
display manager. Select the **Aqueous** session at login.

Publish the `v0.9.1` source tag and build the stable components using
`packaging/arch/aqueous-desktop`. Make these packages and stable `pearl` available
in the configured package repository before installing this package. Component
package releases are pinned to `0.9.1-1` independently of this preset's `pkgrel`.

Build from this directory with `makepkg`, then install the resulting
`devario-desktop` package through pacman. This recipe packages only the default
configuration; it does not rebuild Aqueous or Pearl. It replaces the role of the
general `aqueous-desktop` or older `devario-aqueous-desktop` meta package, which
are declared conflicts.
