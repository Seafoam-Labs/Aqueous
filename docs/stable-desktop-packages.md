# Stable desktop packages

`packaging/arch/aqueous-desktop` builds the stable Pearl desktop: `aqueous-core`,
`aqueous-session`, `aqueous-integration-pearl`, `aqueous-shell-pearl`,
`xdg-desktop-portal-aqueous`, and `aqueous-desktop`. The portal component includes
the standalone GTK `aqueous-portal-picker`; the Welcome wizard is retired.

See the maintained [Arch desktop recipe guide](../packaging/arch/aqueous-desktop/README.md)
for build commands, dependencies, upgrade replacements, and session defaults.
The corresponding [Devario packages](../packaging/devario/README.md) use the same
component structure.

| Recipe | Purpose |
| --- | --- |
| `packaging/arch/aqueous` | Minimal stable compositor for a greeter or other compositor-only use |
| `packaging/arch/aqueous-desktop` | Stable compositor, configuration helper and Pearl desktop session |
| `packaging/arch/aqueous-git` | Development core and desktop with separate commands and session identity |

The desktop's core provides the versioned `aqueous` dependency required by Pearl
and conflicts with the minimal `aqueous` package because both own the compositor
and private library. The root `PKGBUILD` remains a separate generic component
recipe whose desktop meta package is named `aqueous`.

Existing personal configuration takes precedence over system defaults. Generic
component packages support manual shell selection in
`~/.config/aqueous/session.toml`; install the matching shell and integration
preset before selecting it, then log in again. The supported values are `pearl`,
`dms`, `noctalia`, and `none`, with `version = 1`.
