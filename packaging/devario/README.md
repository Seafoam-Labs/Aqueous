# Devario packages

This directory follows the three-recipe layout in `packaging/arch`, with
Devario maintainers, Shelly builds, Zig `0.16.0` and Pearl desktop defaults.
Each recipe has its own `PKGBUILD` and `.SRCINFO`.

| Recipe | Outputs | Purpose |
| --- | --- | --- |
| `aqueous/` | `aqueous` | Minimal stable compositor, including the dependency used by Pearl Greeter |
| `aqueous-desktop/` | `aqueous-core`, `aqueous-session`, `xdg-desktop-portal-aqueous`, `aqueous-integration-pearl`, `aqueous-shell-pearl`, `devario-desktop` | Complete stable Devario Pearl desktop |
| `aqueous-git/` | `aqueous-core-git`, `aqueous-session-git`, `xdg-desktop-portal-aqueous-git`, `aqueous-integration-pearl-git`, `aqueous-shell-pearl-git`, `aqueous-git` | Separate development desktop using Pearl Git |

The stable recipes fetch `v1.0.4`; publish that tag before building them.
`aqueous` is compositor-only. `aqueous-core` provides `aqueous` and conflicts
with the minimal package because they own the same compositor files. Git uses
suffixed commands, private libraries, services and configuration paths so it
can coexist with either stable installation.

The desktop builds contain no Welcome app, DMS or Noctalia outputs. Stable
builds retain the standalone GTK screen-sharing picker. Pearl uses its own
`pearl-capture-picker`; the Git preset requires `pearl-capture-picker-git` and
`pearl-git`. Both desktop presets depend on the stable `pearl-greeter` package.
Its stable compositor dependency is satisfied by `aqueous` or `aqueous-core`;
`aqueous-core-git` does not provide the unsuffixed compositor.

## Build with Shelly

Run these commands from `packaging/devario` to generate stable metadata and
build the complete stable desktop:

```sh
shelly build --makesrcinfo --reviewed aqueous-desktop/PKGBUILD > aqueous-desktop/.SRCINFO
shelly build --isolated --sync-deps --check --json aqueous-desktop/PKGBUILD > build-result.json
```

Use `aqueous/PKGBUILD` for the minimal stable compositor or
`aqueous-git/PKGBUILD` for the development desktop. Shelly's
`--makesrcinfo` prepares VCS sources and updates `pkgver()` for the Git recipe,
so refreshing Git metadata requires source access. For an offline comparison
of its checked-in version, use `makepkg --printsrcinfo` from `aqueous-git/`.
The Git version follows the most recent tag and commit count, rather than the
stable manifest version.

Shelly resolves shared `makedepends` and `checkdepends` before executing package
functions. Sibling dependencies and Pearl runtime dependencies are declared in
individual package functions; the shared build does not require published
Aqueous siblings or Pearl. Each desktop build produces six archives. Collect
every entry in the successful JSON result's `artifacts` array, including the
architecture-independent packages, and publish the complete set together.

Publish `pearl`, `pearl-capture-picker` and `pearl-greeter` before installing
the stable desktop; publish `pearl-git` and `pearl-capture-picker-git` for the
Git desktop. Standard build and runtime dependencies come from configured
Devario repositories. These recipes do not rebuild those dependencies.

Compiled packages target x86-64-v3 on x86_64 and baseline aarch64. Configuration
and dependency-only packages use `any`. Pearl's recipes currently support
x86_64, so the complete Pearl desktop targets x86_64. The core package functions
remove temporary build paths from the installed compositor's RUNPATH with
`patchelf` and verify `$ORIGIN/../lib/aqueous`.

## Defaults and migration

`devario-desktop` owns `/etc/xdg/aqueous/session.toml`; `aqueous-git` owns
`/etc/xdg/aqueous-git/session.toml`. Both select Pearl, preserve user overrides
and register the system file as a package backup. Their package functions do
not activate services. Pearl Greeter handles its own greeter setup. Select
**Aqueous** or **Aqueous-Git** at login.

Replace the former `aqueous-devario/PKGBUILD` and top-level `PKGBUILD` build
jobs with one `aqueous-desktop/PKGBUILD` job. Its package base is
`aqueous-desktop`, while the installed desktop preset remains
`devario-desktop`. The six existing package names now share version `1.0.4-2`.
The Aqueous components use exact sibling dependency pins. `devario-desktop`
requires those components at its build version or newer (currently `>=1.0.4-2`),
so an installed desktop preset accepts future Aqueous releases. Publish the
updated preset once to replace its previous exact pins. The package base is a build identity;
there is no separate `aqueous-desktop` output on Devario. Update `pkgver` or
`pkgrel` once in this recipe and regenerate its `.SRCINFO` when releasing the
stable desktop. The minimal and Git recipes have independent revisions.

## Validation

From the repository root, check metadata and preset configuration ownership:

```sh
python3 packaging/tests/test-devario-packages.py
```

This requires Shelly, makepkg and Python. To also validate the six stable
archives from a Shelly build, pass the JSON result (also requires `bsdtar` and
`patchelf`):

```sh
python3 packaging/tests/test-devario-packages.py packaging/devario/build-result.json
```

Archive validation checks names, versions, architectures, dependencies,
backups, required files, duplicate ownership and the installed compositor's
RUNPATH. It does not install packages.
