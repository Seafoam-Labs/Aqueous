# Canonical Aqueous configuration helper

Build with Zig 0.16.0 from `settingsApplication/` in a full Aqueous checkout
(the helper imports the sibling compositor's canonical configuration sources):

```sh
zig build config -Dhelper-only=true -Doptimize=ReleaseSafe
```

Every build is helper-only; the GUI build and Quark dependency are removed.
`zig build` and `zig build config` both install the canonical helper. The older
helper-only/model-only options remain accepted. `zig build test` runs the backend,
shared parser and subprocess tests without GUI development libraries.

Stage a package without an old settings executable:

```sh
DESTDIR=/tmp/aqueous-config-package PREFIX=/usr \
  AQUEOUSCTL_BINARY=/path/to/matching/aqueousctl \
  packaging/install.sh --helper-only
```

This installs `aqueous-config`, the canonical `aqueousctl` reload command, GPL
license and backend/command documentation. It installs no desktop entry, icon,
theme, Quark files or DMS/Noctalia integration. DESTDIR stages files only. For
distribution packaging, declare runtime dependencies on libc and the libraries
used by the matching aqueousctl build (including libwayland-client). Font
inspection/synchronization uses fontconfig (`fc-list`, `fc-match`); optional
toolkit targets use GLib/GSettings and their desktop schemas when installed.
Package managers must resolve these runtime dependencies; this staging script
does not invoke a package manager. Distribution packages can explicitly add
`--with-dms-appearance` to `packaging/install.sh` to stage the backend-only DMS
typography bridge; default and `--helper-only` installs remain neutral. A running
Aqueous compositor supplies reload acknowledgements. Pearl and these helper executables are sufficient for the
settings frontend; the retired GUI is not required.

Executables are discovered through PATH. Protocol 1 retains `version`,
`snapshot`, `validate`, `apply`, `raw`, `--request -`, and `--shell none`.
Use neutral shell mode for Pearl. Apply performs the canonical save and one
reload; a successful command exit or `accepted` reply does not count as an
`applied` acknowledgement. `--report-reload yes` keeps the legacy stderr report.
Clients must inspect capabilities before using additive interfaces.

Always use a private HOME, XDG_CONFIG_HOME, XDG_STATE_HOME, XDG_RUNTIME_DIR and
private bus/compositor for integration testing. Do not point tests at a running
desktop. Hardware feature acceptance is separate from headless testing.

The additive T11 contracts and remaining capability gates are documented in
[T11.md](T11.md) and [T11_TRANSACTIONS.md](T11_TRANSACTIONS.md). For recoverable
results use `apply --result v1 --operation-id ID`; query lost replies with
`operation-status --operation-id ID`. The shared document and journal sources
now live at `compositor/aqueous/ConfigDocument.zig` and `ConfigTransaction.zig`;
backend imports retain their compatibility wrapper.
