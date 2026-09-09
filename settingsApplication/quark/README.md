# Quark source and modifications

Quark is copyright 2025–2026 pparaxan, licensed under the PX License version 1.
The complete license is in `LICENSE` (installed as `quark-LICENSE`).

Corresponding upstream source:
https://codeberg.org/pparaxan/quark/archive/c104e1c953347d677fb1b363260854842217d967.tar.gz

`prepare.py` applies the application's changes to that exact source in the
Zig build cache. The Aqueous repository distributes the script with the app;
the installed copy is under `share/aqueous/settings-application/quark/`.
Run `python3 prepare.py <upstream-src-directory> <output-directory>` to obtain
the modified `src/` tree. All other upstream source files are unchanged.
`settingsApplication/build.zig` compiles this tree with the pinned dependencies
in `build.zig.zon`, and links the existing Vulkan presentation workaround.

Changes fix repeated action dispatch, Wayland input capability discovery and
keycodes, initial text, scroll viewport culling and scrollbar layers. They
extend text limits, add multiline rendering/navigation and visible-control
keyboard traversal, and bound long dropdown menus with wheel browsing. This is an application-specific patch against the recorded
pin; mismatched source fails the build. It is not an upstream release.

Theme support adds transactional `setFonts()` to parent/child windows, with
cleanup on partial load failure and complete measurement-cache replacement.
The patch also converts sRGB palette values according to the actual swapchain
format, replacing the WSL-only color-conversion heuristic and correcting its
transfer-function divisor. This keeps exported shell hex colors faithful on
both sRGB and UNORM surfaces.
