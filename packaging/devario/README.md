# Devario desktop

`devario-desktop` installs stable Aqueous `1.0.2` with Pearl and Pearl Greeter. It depends directly
on the core, session, portal and Pearl integration/preset packages,
without Welcome, the general `aqueous-desktop` meta package or DMS/Noctalia
integrations, presets or shells.

The portal package includes `aqueous-portal-picker`, a standalone GTK source
picker. Pearl screen sharing and normal session startup do not require Welcome.
The portal recipe uses the `picker` build target from `v1.0.2`; it does not build
or install the Welcome app.

The package installs `/etc/xdg/aqueous/session.toml` selecting Pearl. Aqueous uses
this default when a user has no `~/.config/aqueous/session.toml`; existing user
choices take precedence. Pacman preserves edits to the system default through
its normal backup handling. The desktop preset has no service activation hook.
Its Pearl Greeter dependency selects the greeter for the next boot through its
own install hook, without restarting the running session. Select the **Aqueous**
session at login.

Each subdirectory is an independent build directory with its own `PKGBUILD` and
`.SRCINFO`. Source recipes select the upstream `v1.0.2` tag, which must be
published before fetching the release; the dependency-only
Pearl preset needs no source checkout. No recipe sources a neighboring recipe.

| Directory | Contents |
| --- | --- |
| `aqueous-core` | Compositor, private patched wlroots, `aqueousctl`, `aqueous-config`, protocols and manuals |
| `aqueous-session` | UWSM login session, shell runtime, desktop configuration and wallpapers |
| `aqueous-integration-pearl` | Conditional Pearl user service and selection integration |
| `aqueous-shell-pearl` | Dependency preset pulling in Pearl and its Aqueous integration |
| `xdg-desktop-portal-aqueous` | Screen-sharing backend and standalone GTK source picker |

Build with `makepkg` inside each directory, publishing packages in this order:
`aqueous-core`, `aqueous-session`, `aqueous-integration-pearl`, then
`aqueous-shell-pearl`. The portal can be built independently. Publish `pearl`
before building its dependency preset, and publish `pearl-greeter` before
building the top-level `devario-desktop` preset. Their recipes are maintained in
Pearl's `packaging/Devario/pearl` and `packaging/Devario/pearl-greeter` directories.

Core, session, portal, Pearl integration/preset and `devario-desktop` are
`1.0.2-1`, the first release built from the `v1.0.2` source tag. Core removes
the temporary wlroots build path from the installed compositor's RUNPATH using
`patchelf`, then verifies that only `$ORIGIN/../lib/aqueous` remains. Exact
component dependency pins require the whole cohort to move together; rebuild
and publish all five in the order above.
Core and portal use Zig `0.16.0` and
target x86-64-v3 on x86_64, with baseline aarch64 support. The configuration-only
packages are architecture independent. Pearl's current recipes support x86_64,
so the complete Devario Pearl desktop currently targets x86_64.

Standard runtime and build dependencies (including UWSM, greetd, GTK, PipeWire
and the generic XDG portals) come from configured repositories. They are not
rebuilt by these component recipes. None of these recipes depends on
`aqueous-welcome`, DMS or Noctalia.

Build from this directory with `makepkg`, then install the resulting
`devario-desktop` package through pacman. This recipe packages only the default
configuration; it does not rebuild Aqueous or Pearl. It replaces the role of the
general `aqueous-desktop` or older `devario-aqueous-desktop` meta package, which
are declared conflicts.
