# Aqueous component packages

The stable source recipe now builds separate packages. `aqueous-core` owns the
compositor, `aqueousctl`, `aqueous-config`, private patched wlroots, manuals,
schemas and protocol metadata. Pearl's standalone package should depend on this
name. It does not provide the `aqueous` desktop role or depend on a shell.

`aqueous` remains the full desktop entry point. It depends on core, session,
welcome, portal and the three small shell integrations. Installing an integration
does not install its shell. `aqueous-shell-dms`, `aqueous-shell-noctalia` and
`aqueous-shell-pearl` are explicit dependency presets for the integration plus
DMS, Noctalia or Pearl. Welcome requests these presets on the component path.

`aqueous-git` and `aqueous-git-intel`, including their mirrored recipes, remain
legacy combined packages with their existing DMS integration and session
behavior. The historical `gitNoctalia` recipe retains its existing behavior.
`PKGBUILD-DMS` also remains a combined compatibility recipe. None is converted
into a metapackage or automatically replaced. Legacy packages conflict with
component packages that own their files; changing paths requires an explicit
package-manager transaction. Personal configuration is not deleted or migrated
by packaging hooks.

## Ownership and dependencies

Packaging orchestration and the session runtime are shell scripts. They use `jq`
for JSON and libarchive for secure archive extraction. Welcome's setup worker is
compiled into its Zig executable. Python is still used by existing test suites
and build tools such as Meson; welcome and the session runtime do not require it.

`packaging/components.json` defines allowed and required component paths. The
stager accepts an empty private `DESTDIR`, `PREFIX` and `SYSCONFDIR`; it cannot
install directly onto the host. Existing legacy installer entry points are
unchanged. Each release component has a manifest of file modes, hashes and
symlink targets. Composition rejects overlapping files and mismatched cohorts.

| Component | Runtime requirements |
| --- | --- |
| Core | Native graphics/input/seat libraries used by the compositor and private wlroots; XWayland; PipeWire; Fontconfig and GLib for helper observations/toolkit support |
| Session | Bash, jq, coreutils, UWSM, systemd, D-Bus, terminal and screenshot/clipboard commands used by shipped defaults |
| Welcome | Session runtime, GTK4, Shelly and sudo for explicitly reviewed setup |
| Portal | Wayland, PipeWire, inih, systemd and the portal framework; transitive native GBM/DRM libraries |
| DMS integration | Session and portal; libc chooser executable, QML bridges and DMS discovery links |
| Noctalia/Pearl integration | Session; conditional units and shell-specific defaults |

Core's `systemd-libs` dependency is the native udev/seat API. Optional helper
cursor synchronization detects whether `systemctl` and D-Bus activation tools
exist. GTK, Shelly, sudo, UWSM and Ghostty are not core runtime dependencies.
Source builds may need optional-component build dependencies; these do not become
runtime dependencies of the core subpackage.

Core installs no `/etc` files, units, desktop session, autostart, tmpfiles, udev
rules, chooser preferences or shell plugin discovery. The new session path omits
the broad input `uaccess` rule and uses the compositor's logind/seatd path.
Legacy seat integration is unchanged. Hardware login acceptance remains separate.

Session owns `session-runtime.sh`; welcome runs setup in a native worker process and delegates selection to the shell runtime when installed. Removing
welcome leaves selection, conditions and shell actions available. A missing shell
or adapter causes a shell-free runtime snapshot and a diagnostic without rewriting
`session.toml` or selecting another installed shell. The optional welcome UI can
provide recovery and a generic portal picker; without it, those UI actions report
that their executable is unavailable. DMS and Noctalia retain their own pickers.

## Staging and verification

```sh
AQUEOUS_COMPOSITOR_DIST=/path/to/compositor-dist \
AQUEOUS_CONFIG_BINARY=/path/to/aqueous-config \
DESTDIR=/tmp/aqueous-core-image packaging/stage-component.sh core

bash packaging/tests/test-components.sh
python3 packaging/tests/test-dms-git-packaging.py
python3 packaging/tests/test-fedora-installer.py
bash packaging/tests/smoke-core.sh /tmp/aqueous-core-image/usr
```

The headless smoke check uses a private bus and configuration roots, verifies
that the staged wlroots is mapped, and exercises helper snapshot/validation and
`aqueousctl`. It is not physical display or hardware session acceptance.

Production compositor builds install `share/aqueous/build-policy.json` from
actual build options. Core staging rejects acceptance and output fault-injection
builds. Unknown files, retired GUI/test executables and broken symlinks are
rejected by manifest validation. Arch packaging disables stripping and manual
compression to retain the bytes checked before packaging.

`packaging/release-components.sh` stages all components, checks their real
binaries, writes cohort metadata and produces both component archives and the
historical combined layout. `verify-release.sh` checks version, architecture,
cohort, manifests, runtime helper metadata and compositor linkage. Checksums
cover the final archives. The release tool also emits a `PKGBUILD-bin` with the version and SHA256 pinned
to that archive. The repository template fails closed until populated by this
step; an old combined
archive is not a substitute. The existing compositor-only archive remains a
separate compatibility artifact and is not the complete core.

## Nix and other installers

The overlay exports `aqueousCore`, `aqueousSession`, `aqueousWelcome`,
`aqueousPortal`, `aqueousIntegrations` and the compatibility `aqueous` composition.
Installing `pkgs.aqueousCore` alone does not enable the NixOS module or configure
host services. Core is a separate derivation with no shell/welcome store references.

For a managed session, enable `programs.aqueous.enable` and explicitly choose
`programs.aqueous.shell = "noctalia"`, `"dms"`, `"pearl"` or `"none"`.
DMS/Pearl also require `shellPackage`. `welcome.enable` is optional. Explicit
legacy `noctalia.enable` values map with a deprecation warning; contradictory
settings fail. Configurations that previously relied on implicit Noctalia must
choose before activation. Existing per-user selection takes precedence and is
never overwritten by the module's system default.

Fedora's default invocation retains its legacy DMS desktop RPM and builds from
`PKGBUILD-git`. `--core-only` uses the new core staging path and produces an
`aqueous-core` RPM without session dependencies or service hooks. This selector
cannot be combined with `--dms-git`.

Gentoo accepts `--core-only` before its existing command, for example
`bash scripts/gentoo-install.sh --core-only build`. Both paths use shared staging.
The installer preserves existing `/etc` files and retains packaged defaults for
safe removal checks. Desktop welcome requires Shelly to be available separately
on distributions that do not package it; core does not require it.

## Release acceptance still required

Local staging, fixture tests and artifact smoke checks do not replace clean-chroot
source builds, real dependency-solving upgrades/removals, full Nix builds/closure
checks, NixOS session boots, or Fedora/Gentoo host testing. Test both legacy package
names independently and test explicit switches in both directions. Publish only
after these platform checks, publishing the generated binary recipe and Pearl's dependency
handoff in its own repository. The workstream plan retains the full migration
matrix and release gates.
