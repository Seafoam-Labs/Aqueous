# Quark source and modifications

Quark is copyright 2025–2026 pparaxan, licensed under the PX License version 1.
The complete license is in `LICENSE` (installed as `quark-LICENSE`).

Corresponding upstream source:
https://codeberg.org/pparaxan/quark/archive/c104e1c953347d677fb1b363260854842217d967.tar.gz

`prepare.py` and its companion `redesign.py` apply the application's changes to that exact source in the
Zig build cache. The Aqueous repository distributes the script with the app;
the installed copy is under `share/aqueous/settings-application/quark/`.
Keep both scripts together. Run `python3 prepare.py <upstream-src-directory> <output-directory>` to obtain
the modified `src/` tree. All other upstream source files are unchanged.
`settingsApplication/build.zig` compiles this tree with the pinned dependencies
in `build.zig.zon`, and links the existing Vulkan presentation workaround.

Changes fix repeated action dispatch, Wayland input capability discovery and
keycodes, initial text, scroll viewport culling and scrollbar layers. They
extend text limits, add multiline rendering/navigation and keyboard traversal, and bound long dropdown menus with wheel browsing. This is an application-specific patch against the recorded
pin; mismatched source fails the build. It is not an upstream release.

Theme support adds transactional `setFonts()` to parent/child windows, with
cleanup on partial load failure and complete measurement-cache replacement.
The patch also converts sRGB palette values according to the actual swapchain
format, replacing the WSL-only color-conversion heuristic and correcting its
transfer-function divisor. This keeps exported shell hex colors faithful on
both sRGB and UNORM surfaces.

The settings-layout changes add wrapped text with shared measurement/rendering
line breaks, semantic control IDs, clipped vertices/UVs and clipped hit testing,
nested scroll intersections, toggle rendering, and centered slider hit targets.
Application typography roles use the existing bundled font data and release
replacement resources transactionally. Navigation icons are original canvas
geometry in Aqueous; no additional icon-font or image license is required.

Focus traversal includes offscreen widgets and scrolls ancestors to reveal them.
Ctrl+F/Escape requests are exposed to the application. Wayland key presses are
queued so rebuilds cannot overwrite pending input. Pending layout changes refresh
the action registry before input dispatch, preventing callbacks into a replaced
widget tree. Text selection/caret state is restored only when semantic identity
and text match; explicit reset and slider values remain authoritative. Row
measurement reserves spacing for fixed and proportional children alike.

The patches remain application-specific. `test-ui-model` covers wrapping, UV and
hit clipping, role-font cleanup and existing ownership behavior. Isolated UI
tests exercise rapid search input, draft retention, controls, theme updates and
Apply/reload using the resulting patched application.

Modal overlays are excluded from the parent's ordinary height allocation. Their
content can scroll within the window and keyboard traversal stays inside the
active dialog. Explicit proportional row widths are retained in the expanding
widget pass, including the color-channel sliders.
