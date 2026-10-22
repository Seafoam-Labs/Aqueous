# Aqueous portal backend

Aqueous packages a private, namespaced build of
[`xdg-desktop-portal-wlr`](https://github.com/emersion/xdg-desktop-portal-wlr)
0.8.4. The upstream source is fetched during packaging and the patch in
this directory namespaces the backend and makes dmenu selection asynchronous.
`SelectSources` validates and stores options; `Start` presents the picker and
returns the stream. Each session can start only once. The request remains
cancellable while its picker is open; closing its request
or session kills the chooser process group and returns no capture source.
Screenshot retains the upstream implementation. PipeWire capture cancels pending
Wayland frames and capture timers on pause or buffer removal. A paused buffer is
retained for resume without publishing an incomplete image, preventing overlapping
frame requests during stream startup and consumer reconnects.

Source selection persists for the requesting application's lifetime when it
requests persistence. A preview followed by sharing can reuse the monitor
selection through the public portal's restore token. Requests with
`persist_mode=0` still require a fresh selection. The backend caps both new and
restored sessions at the same policy, and checks the requested source types and
output availability before restoring. Window selections currently have no
restore data in the pinned upstream backend.

`XDPW_PERSIST_MODE=transient` explicitly selects the default policy;
`XDPW_PERSIST_MODE=none` disables reuse; `XDPW_PERSIST_MODE=permanent` permits
permanent persistence when requested by the application. Set overrides on the
backend service environment. Unknown override values disable persistence.
These settings never increase the mode requested by an application.

The dmenu child receives `AQUEOUS_PORTAL_PARENT_WINDOW` from `Start`, and a
request-specific `XDG_ACTIVATION_TOKEN` if supplied. Inherited activation tokens
are cleared. Source lines on stdin and the selected line on stdout are unchanged.
The updated Pearl and standalone GTK pickers import `wayland:` parent handles
before mapping and mark themselves modal, preserving the parent's display and
modal focus even with `focus_new_windows=false`. Apps that supply no parent
still use normal compositor placement and focus policy.

The DMS bridge adds optional `parentWindow` and `activationToken` fields to its
version-1 JSON request, without changing the index response. Quickshell's current
FloatingWindow API does not import external Wayland parent handles or activation
tokens. Its picker uses the active application's display, falling back to the
first available display; native parent/focus handoff remains a Quickshell
limitation. Noctalia retains its own dmenu presentation behavior.

Installed files:

- `/usr/lib/aqueous/xdg-desktop-portal-aqueous`
- `/usr/share/xdg-desktop-portal/portals/aqueous.portal`
- `/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.aqueous.service`
- `/usr/lib/systemd/user/xdg-desktop-portal-aqueous.service`
- `/etc/xdg/xdg-desktop-portal-aqueous/config`

The desktop portal router is configured by `packaging/aqueous-portals.conf` to
use this backend only for ScreenCast and Screenshot. GTK continues to handle
the remaining portal interfaces.

Stable Arch packages use `aqueous-shell-action chooser`, which follows the active
session selected in Welcome to Aqueous. DMS uses the existing Zig bridge and
`aqueousPortal` plugin; Noctalia uses `noctalia dmenu`. Pearl uses its bundled `/usr/lib/pearl/pearl-capture-picker` (the Git
session uses `/usr/lib/pearl-git/pearl-capture-picker`). Nothing uses
`aqueous-portal-picker`, a standalone GTK picker shipped by the portal package.
It reads the source list from stdin and has no Welcome/setup dependency. All use `chooser_type=dmenu`
and return the selected original source line, with no output on cancellation.

Git desktop packages ship the portal backend without Welcome or the standalone
Aqueous picker. Their dispatcher keeps Pearl and Noctalia's own pickers. DMS and
shell-free sessions return no capture source unless a custom `chooser_cmd` is
configured in the Git portal config. See the
[Git desktop guide](../../docs/git-desktop-packages.md#optional-shell-presets).

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

With backend log level `DEBUG`, `portal:` messages correlate `SelectSources`,
`Start`, chooser launch/finish, request cancellation and owner loss by request
and session handles. A new chooser launch with a new session after cancellation
identifies a new client request; the backend does not retry a cancelled picker.
Activation tokens and exported parent handles are not logged.

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

Backend and GTK parent/focus regressions (build the patched backend first):

```sh
python3 packaging/tests/test-portal-session.py --backend /path/to/xdg-desktop-portal-aqueous
python3 packaging/tests/test-portal-picker-context.py \
  --backend /path/to/xdg-desktop-portal-aqueous \
  --picker /path/to/aqueous-portal-picker \
  --picker /path/to/pearl-capture-picker
```

These tests accept `--compositor`; the GTK test also accepts `--ctl`. They default
to the workspace compositor build. They use private D-Bus, PipeWire and two
headless outputs, and need Python GObject bindings, the desktop portal router,
Wayland development files and a C compiler. Session tests cover simultaneous
sessions, bad handles, persistence modes and overrides, restore validation,
public preview/share reuse, request/session closure, sender authorization and
frontend owner loss. The GTK test uses an exported fullscreen parent on each
output and a persistent virtual keyboard to verify modal focus and Escape.
Pearl's `tests/capture_picker/test_portal.py` additionally validates real
PipeWire frames before and after consumer reconnects; it requires GStreamer's
`pipewiresrc`, `videoconvert` and `pngenc`, plus the GdkPixbuf Python bindings.

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
