# Aqueous Settings

A small Zig/Quark application for editing the complete Aqueous configuration.

It opens `wm.toml`, `layout.toml`, `input.toml`, `outputs.toml`, and
`rules.toml` from the same environment, XDG, HOME, linked-path, and system
locations used by the compositor. Every existing table and value is editable;
booleans use checkboxes and other TOML values appear as editable text-field
contents.

The Add setting form accepts a section name such as `blur`, a repeated table
header such as `[[window]]`, or a displayed numeric table index when adding a
key to one specific repeated table. Values must use TOML syntax. Entries and
entire tables can also be removed.

Save all writes only changed files with an atomic rename while preserving
comments, formatting, ordering, and unrelated settings. Reload discards
unsaved edits and reads the files again.

```sh
zig build
zig build test
zig build run
```

Quark currently targets Linux/Wayland and requires Wayland, Vulkan, `glslc`,
FreeType, and xkbcommon development packages.
