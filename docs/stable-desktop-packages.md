# Stable desktop packages

`packaging/arch/aqueous-desktop` targets the complete stable desktop from
`v0.9.1`. Publish that tag with the corrected packaging test before building
from GitHub; `v0.9.0` predates the fix. The split recipe produces `aqueous-core`,
`aqueous-session`, `aqueous-welcome`, `xdg-desktop-portal-aqueous`, the three
shell integration packages, optional shell presets, and `aqueous-desktop`.
All components use version `0.9.1-1` and exact component dependencies.

| Recipe | Purpose |
| --- | --- |
| `packaging/arch/aqueous` | Minimal stable compositor for a greeter or other compositor-only use |
| `packaging/arch/aqueous-desktop` | Stable compositor, configuration helper and full desktop session |
| `packaging/arch/aqueous-core-git` + `aqueous-desktop-git` | Development core and desktop with separate commands and session identity |

The portal component includes `aqueous-portal-picker`; it requires GTK4 but does
not require Welcome. Devario can install the portal and Pearl without setup UI.

The desktop's `aqueous-core` provides `aqueous=0.9.1` for consumers such as Pearl
and conflicts with the minimal `aqueous` package because both own the same
compositor and private library. The new desktop meta package is named
`aqueous-desktop`; the root recipe's legacy meta package is still named `aqueous`.
The stable desktop can coexist with the suffixed Git core and desktop.

## Build and install

Use an Arch build environment with the declared dependencies available.
Builds target x86-64-v3 on x86_64 and baseline CPUs on aarch64.
From the repository root, in Bash:

```bash
cd packaging/arch/aqueous-desktop
makepkg -s
```

After a successful build, install the core and desktop components together:

```bash
mapfile -t packages < <(makepkg --packagelist | awk '!/\/aqueous-shell-/')
sudo pacman -U "${packages[@]}"
```

The filter excludes the three optional shell presets. `makepkg -si` would
request all of them. Select the **Aqueous** login session; welcome offers Pearl,
DMS, Noctalia or Nothing. Installing the desktop does not select a shell or
change the display manager. Existing personal configuration is retained.

The preset packages are `aqueous-shell-pearl`, `aqueous-shell-dms` and
`aqueous-shell-noctalia`. Install the chosen preset and its shell through your
configured repositories, or make the packages available to welcome's installer.

The recipe directory is self-contained: publish `PKGBUILD`, `.SRCINFO`,
`aqueous-desktop.install` together. The activity-launch fixture is corrected in
the source test, with no packaging workaround. The separate portal backend
still uses its existing rename patch. Publishing a recipe or binary repository
is a separate step from building locally.
