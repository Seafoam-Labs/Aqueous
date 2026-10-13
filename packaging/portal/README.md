# Aqueous portal backend

Aqueous packages a private, namespaced build of
[`xdg-desktop-portal-wlr`](https://github.com/emersion/xdg-desktop-portal-wlr)
0.8.4. The upstream source is fetched during packaging and the patch in
this directory namespaces the backend and makes dmenu selection asynchronous.
The request remains cancellable while its picker is open; closing its request
or session kills the chooser process group and returns no capture source.
PipeWire streaming and Screenshot retain the upstream implementation.

Installed files:

- `/usr/lib/aqueous/xdg-desktop-portal-aqueous`
- `/usr/share/xdg-desktop-portal/portals/aqueous.portal`
- `/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.aqueous.service`
- `/usr/lib/systemd/user/xdg-desktop-portal-aqueous.service`
- `/etc/xdg/xdg-desktop-portal-aqueous/config`

The desktop portal router is configured by `packaging/aqueous-portals.conf` to
use this backend only for ScreenCast and Screenshot. GTK continues to handle
the remaining portal interfaces.

Arch packages use `aqueous-shell-action chooser`, which follows the active
session selected in Welcome to Aqueous. DMS uses the existing Zig bridge and
`aqueousPortal` plugin; Noctalia uses `noctalia dmenu`. Pearl uses its bundled `/usr/lib/pearl/pearl-capture-picker` (the Git
session uses `/usr/lib/pearl-git/pearl-capture-picker`). Nothing uses
`aqueous-portal-picker`, a standalone GTK picker shipped by the portal package.
It reads the source list from stdin and has no Welcome/setup dependency. All use `chooser_type=dmenu`
and return the selected original source line, with no output on cancellation.

Installing another shell does not change an active session. Welcome writes the
next-login selection and preserves custom portal overrides. It updates recognized
legacy chooser commands while retaining other settings. NixOS retains its
explicit Noctalia chooser configuration.

DMS screen sharing requires DMS 1.6.1 or newer. Its bridge enables only the
`aqueousPortal` plugin through DMS IPC on first use; an explicit plugin disable
is preserved. Enable it again in DMS Settings or with
`dms ipc call plugins enable aqueousPortal`.

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
Final verification against DMS 1.6.1 and real recorder/browser stream startup
remain release checks.

The pinned tarball SHA-256 is
`3122966d46ab108f505525bcb2498f9121b446ee8438fbfceb73a7a1fa1ad400`.
When updating upstream, update the version and checksum in every source
PKGBUILD, the release workflow, `nix/default.nix`, and
`scripts/gentoo-install.sh`, then run `packaging/tests/test-portal-packaging.sh`
against the newly built binary.

Pearl shell presets require the versioned `pearl-capture-picker>=1` capability
(or `pearl-capture-picker-git>=1`), provided by the corresponding Pearl package.
This prevents installation of the new dispatcher with an older Pearl build;
there is no separate picker package. Existing user chooser overrides are retained.
