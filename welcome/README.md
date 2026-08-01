# Welcome to Aqueous

The first-run setup application for Aqueous. It presents a composable catalog
of common desktop applications, detects installed software through Shelly, and
installs the user's selections through Shelly's repository, AUR, and Flatpak
backends.

The automatic `--first-run` launch exits after the user completes setup. A
normal launcher invocation always opens, so the application can be used again
later.

## Add an application section

1. Add a module under `src/sections/` that exports a `catalog.Section` named
   `section`.
2. Register it in `src/sections.zig`.
3. Run the catalog and command-generation tests.

Package identities are data, not shell fragments. Each application names an
exact Shelly backend and package ID; the installation layer constructs argv
arrays and never invokes a shell or a package manager directly.

```sh
zig build
zig build test
zig build run
```

Quark targets Linux/Wayland and requires Wayland, Vulkan, `glslc`, FreeType,
and xkbcommon development packages. Runtime installation requires Shelly and
`pkexec` for system-package authorization.
