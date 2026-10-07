# Devario desktop

`devario-desktop` installs stable Aqueous `1.0.2` with Pearl and Pearl Greeter. It depends directly
on the core, session, portal and Pearl integration/preset packages,
without Welcome, the general `aqueous-desktop` meta package or DMS/Noctalia
integrations, presets or shells.

The portal package includes `aqueous-portal-picker`, a standalone GTK source
picker. Pearl screen sharing and normal session startup do not require Welcome.
The component recipe uses the `picker` build target from `v1.0.2`; it does not build
or install the Welcome app.

The package installs `/etc/xdg/aqueous/session.toml` selecting Pearl. Aqueous uses
this default when a user has no `~/.config/aqueous/session.toml`; existing user
choices take precedence. Package backup metadata preserves edits to the system
default during upgrades. The desktop preset has no service activation hook.
Its Pearl Greeter dependency selects the greeter for the next boot through its
own install hook, without restarting the running session. Select the **Aqueous**
session at login.

`aqueous-devario/PKGBUILD` is one split-package recipe for Shelly's native
builder. It fetches the upstream `v1.0.2` tag once and builds the compositor,
configuration helper, portal and standalone picker in a shared build lifecycle.
The tag must be published before fetching the release. Each output has its own
package function, runtime dependencies and file ownership. The dependency-only
Pearl preset has an empty payload. No recipe sources a neighboring recipe.
Source preparation corrects two stale `0.8.3` version assertions in the
`v1.0.2` backend tests to the packaged version so the full checks can run.

| Output package | Contents |
| --- | --- |
| `aqueous-core` | Compositor, private patched wlroots, `aqueousctl`, `aqueous-config`, protocols and manuals |
| `aqueous-session` | UWSM login session, shell runtime, desktop configuration and wallpapers |
| `aqueous-integration-pearl` | Conditional Pearl user service and selection integration |
| `aqueous-shell-pearl` | Dependency preset pulling in Pearl and its Aqueous integration |
| `xdg-desktop-portal-aqueous` | Screen-sharing backend and standalone GTK source picker |

From this directory, generate metadata and build all five outputs with Shelly:

```sh
shelly build --makesrcinfo --reviewed aqueous-devario/PKGBUILD > aqueous-devario/.SRCINFO
shelly build --isolated --sync-deps --check --json aqueous-devario/PKGBUILD > build-result.json
```

Shelly uses global `makedepends` and `checkdepends` for the shared build.
Dependencies between outputs, and the runtime-only Pearl dependency, live in
the individual package functions; building the set does not require previously
published Aqueous components or Pearl. The builder emits all five archives.

Repository automation should register one `aqueous-devario` build job in place
of the five former component jobs. Use `shelly --version --json` to check the
worker's build capabilities, and collect every entry in the successful result's
`artifacts` array. A `pkgbase` is a build
identity, not a sixth installable package. Publish all five outputs together;
do not assume one archive per job or filter out the `any` packages.

Publish `pearl` and `pearl-greeter` before building the separate top-level
`devario-desktop` preset. Their recipes are maintained in Pearl's
`packaging/Devario/pearl` and `packaging/Devario/pearl-greeter` directories.

Core, session, portal, Pearl integration/preset and `devario-desktop` are
`1.0.2-2`, consolidating the former standalone recipes while retaining their
installed package names. Existing `1.0.2-1` installations upgrade normally.
Core removes the temporary wlroots build path from the installed compositor's RUNPATH using
`patchelf`, then verifies that only `$ORIGIN/../lib/aqueous` remains. Exact
component dependency pins require the whole cohort to move together; rebuild
and publish all five together. When changing the component version or release,
update `pkgver` or `_component_pkgrel` in the desktop preset and regenerate both
`.SRCINFO` files with Shelly. The desktop preset's own `pkgrel` can advance
independently for configuration changes.
Core and portal use Zig `0.16.0` and
target x86-64-v3 on x86_64, with baseline aarch64 support. The configuration-only
packages are architecture independent. Pearl's current recipes support x86_64,
so the complete Devario Pearl desktop currently targets x86_64.

Standard runtime and build dependencies (including UWSM, greetd, GTK, PipeWire
and the generic XDG portals) come from configured repositories. They are not
rebuilt by these component recipes. None of these recipes depends on
`aqueous-welcome`, DMS or Noctalia.

Build the desktop preset from this directory after publishing its dependencies:

```sh
shelly build --makesrcinfo --reviewed PKGBUILD > .SRCINFO
shelly build --isolated --sync-deps --check PKGBUILD
```

This recipe packages only the default configuration; it does not rebuild
Aqueous or Pearl. It replaces the role of the
general `aqueous-desktop` or older `devario-aqueous-desktop` meta package, which
are declared conflicts.

From the repository root, validate Shelly-generated metadata and all five
archives before publication (requires Shelly, Python, `bsdtar` and `patchelf`):

```sh
python3 packaging/tests/test-devario-packages.py packaging/devario/build-result.json
```

Omit the JSON argument to check only metadata. Archive validation checks names,
versions, architectures, dependencies, backups, required files, duplicate file
ownership and the compositor's installed RUNPATH. It does not install packages.
