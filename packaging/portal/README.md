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
- `/etc/xdg/xdg-desktop-portal-aqueous/config`

The desktop portal router is configured by `packaging/aqueous-portals.conf` to
use this backend only for ScreenCast and Screenshot. GTK continues to handle
the remaining portal interfaces.

The backend configuration selects the shell's source picker. Noctalia packages
install `noctalia.conf`, which calls `noctalia dmenu`. DMS packages target **DMS
1.7 or newer** and install `dms.conf`, a small Zig bridge, and the independent
`aqueousPortal` DMS daemon plugin. No additional launcher is required. Both
configurations use `chooser_type=dmenu`, so combined monitor/window requests
are handled without the upstream default chooser skipping `slurp` and searching
for menu programs that are not installed.

The package variant chooses the default; merely installing a second shell does
not change it. DMS screen sharing does not depend on the optional Aqueous
Settings plugin or a DankBar widget. On the first request the bridge waits up
to ten seconds for plugin discovery and enables only `aqueousPortal` through
DMS IPC. An explicit `enabled: false` in DMS's plugin settings is preserved.
To enable it again, use DMS Settings → Plugins → Aqueous Screen Sharing, or:

```sh
dms ipc call plugins enable aqueousPortal
```

The bridge exchanges the original choice list and a selected index with DMS
over a private per-request Unix socket in `$XDG_RUNTIME_DIR/aqueous-portal`.
Only the selected original line is written to stdout. Escape, Cancel, or closing
the picker produces no selection. A second request is rejected while the
first is active. Disconnects, process termination, invalid responses, and
startup errors release the request socket and lock; user selection has no
short timeout. The pinned backend can report chooser failures as cancellation,
so inspect the portal journal for the underlying error:

```sh
journalctl --user -u xdg-desktop-portal-aqueous.service -b
```

For example, `PluginDisabled` means an explicit user disable was respected;
`PluginNotReady` means DMS or the installed portal plugin did not become ready;
`PluginSettingsInvalid` means the bridge refused to change malformed DMS
settings; and `ChooserBusy` means another picker is already active. The bridge
does not start another shell or fall back to an arbitrary screen.

The compiled system config directory is explicitly `/etc`. Backend config
lookup selects the first readable file, in this order for an Aqueous session:

1. `${XDG_CONFIG_HOME:-$HOME/.config}/xdg-desktop-portal-aqueous/Aqueous`
2. `${XDG_CONFIG_HOME:-$HOME/.config}/xdg-desktop-portal-aqueous/config`
3. `/etc/xdg/xdg-desktop-portal-aqueous/Aqueous`
4. `/etc/xdg/xdg-desktop-portal-aqueous/config`

These files are selected as a whole, not merged. Existing user overrides are
never rewritten; add the relevant template's chooser settings to an override
if it masks the new package default. Arch packages preserve administrator edits
using `backup`; after switching package variants, inspect any `.pacnew` if an
edited system file retains the old chooser. Log out/in after upgrading to load
the new backend configuration. Package installation does not restart active
captures. NixOS installs the Noctalia config only when
`programs.aqueous.noctalia.enable` is true and uses the Noctalia store path.

Build and test the DMS bridge:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/aqueous-portal-global \
ZIG_LOCAL_CACHE_DIR=/tmp/aqueous-portal-local \
zig build --build-file packaging/portal/bridge/build.zig \
  -Dcpu=baseline -Doptimize=ReleaseSafe --prefix /tmp/aqueous-portal-dist
packaging/tests/test-portal-chooser.sh \
  /tmp/aqueous-portal-dist/bin/aqueous-dms-portal-chooser
DMS_SOURCE=/path/to/DankMaterialShell \
python3 packaging/tests/test-portal-host.py \
  /tmp/aqueous-portal-dist/bin/aqueous-dms-portal-chooser
python3 packaging/tests/test-noctalia-portal.py
```

The bridge tests use fake DMS processes and real Unix sockets. The host test
loads real DMS QML in an isolated offscreen Quickshell instance and reports the
source revision. The Noctalia test uses a private D-Bus session, two headless
Aqueous outputs, and virtual keyboard input; it needs a built compositor, a C
compiler, Wayland development files, and Noctalia. These tests do not interact
with the active desktop.

Validation status: the Noctalia fresh-profile test, bridge tests, staged DMS
installation, backend config precedence, and DMS component test pass. The DMS
component test passes both v1.6.0 and prospective 1.7 upstream master commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`, with its pinned
`dank-qml-common` commit `26396ce432d6c71c3f5367438f96f4a8d667e160`.
Upstream has not published a DMS 1.7 tag, so final verification against the
released 1.7 build and real recorder/browser stream startup remain release
checks. Keep the 1.7 requirement rather than treating master as a release.

The pinned tarball SHA-256 is
`3122966d46ab108f505525bcb2498f9121b446ee8438fbfceb73a7a1fa1ad400`.
When updating upstream, update the version and checksum in every source
PKGBUILD, the release workflow, `nix/default.nix`, and
`scripts/gentoo-install.sh`, then run `packaging/tests/test-portal-packaging.sh`
against the newly built binary.
