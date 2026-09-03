# Aqueous portal backend

Aqueous packages a private, namespaced build of
[`xdg-desktop-portal-wlr`](https://github.com/emersion/xdg-desktop-portal-wlr)
0.8.4. The upstream source is fetched during packaging and the small patch in
this directory changes only its executable name, D-Bus identity, and config
directory. ScreenCast and Screenshot remain upstream implementations.

Installed files:

- `/usr/lib/aqueous/xdg-desktop-portal-aqueous`
- `/usr/share/xdg-desktop-portal/portals/aqueous.portal`
- `/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.aqueous.service`
- `/usr/lib/systemd/user/xdg-desktop-portal-aqueous.service`

The desktop portal router is configured by `packaging/aqueous-portals.conf` to
use this backend only for ScreenCast and Screenshot. GTK continues to handle
the remaining portal interfaces.

The pinned tarball SHA-256 is
`3122966d46ab108f505525bcb2498f9121b446ee8438fbfceb73a7a1fa1ad400`.
When updating upstream, update the version and checksum in every source
PKGBUILD, the release workflow, `nix/default.nix`, and
`scripts/gentoo-install.sh`, then run `packaging/tests/test-portal-packaging.sh`
against the newly built binary.
