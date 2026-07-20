# Aqueous Settings

A small Zig/Quark shell for the future Aqueous settings application.

The current shell keeps a draft settings model in memory and demonstrates
navigation, editing, apply, and reset behavior. It intentionally does not edit
the compositor's TOML files yet.

```sh
zig build
zig build run
```

Quark currently targets Linux/Wayland and requires Wayland, Vulkan, `glslc`,
FreeType, and xkbcommon development packages.
