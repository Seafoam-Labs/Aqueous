# Aqueous Settings

A small Zig/Quark settings application for Aqueous.

It reads the same `wm.toml` and optional `input.toml` locations as the
compositor, including `AQUEOUS_CONFIG`, `AQUEOUS_INPUT`, XDG, HOME, and system
fallback paths. Apply updates only the changed TOML keys while retaining the
file's comments, formatting, and unrelated settings.

```sh
zig build
zig build test
zig build run
```

Quark currently targets Linux/Wayland and requires Wayland, Vulkan, `glslc`,
FreeType, and xkbcommon development packages.
