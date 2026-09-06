# Aqueous

**A visually expressive Wayland compositor that keeps the fast path fast.**

Aqueous combines a native tiling window manager, fluid compositor-side motion,
and Aqueous-owned Vulkan effects in one Zig process. It is designed for desktops
that want rounded windows, backdrop blur, focus-aware
opacity, animated placement, and sliding workspaces—without turning routine
window management into a chain of scripts, subprocesses, or IPC round trips.

Aqueous began as a fork of [River](https://codeberg.org/river/river). Its
River-derived foundation and retained protocol work are documented as project
provenance. Today, Aqueous owns its window-management policy, layouts, rules,
input, workspaces, and output configuration in-process and configures them
through its own TOML format.

## Why Aqueous?

Aqueous does not make you choose between a visually polished desktop and a
focused window manager. Its defining features are designed as one coherent
system:

- Switch freely between scrolling, classic tiling, recursive tiling, floating,
  monocle, grid, rows, game-focused, and composable multi-region layouts
  without replacing the window manager or installing layout extensions.
- Keep window, workspace, input, rule, and output policy in one typed Zig
  process, configured through validated TOML rather than a collection of
  runtime scripts.
- Add smooth movement, workspace transitions, rounded corners, blur, and
  focus-aware opacity at the compositor level while retaining explicit ways to
  disable their cost.
- Give games a purpose-built layout that can anchor the primary window and
  arrange launchers, chats, terminals, and other companion windows around it.
- Treat multi-monitor setup as native policy, including profiles, hotplug,
  scaling, transforms, adaptive sync, and sensible automatic placement.

The result is a desktop that can change workflow by workspace or output while
remaining one small, predictable system. Visual effects enhance the layout
model; they do not replace it.

## Highlights

- **Effects with an off switch.** The default Vulkan build provides rounded
  corners and damage-aware backdrop blur. Opacity can be global,
  focus-sensitive, or selected by application rules. Expensive effects can be
  disabled globally or avoided for games and fullscreen media.
- **Motion owned by the compositor.** Window placement animates at render time,
  scrolling layouts move as a viewport, and workspace changes can slide without
  making the layout engine or clients produce intermediate geometry.
- **Workspace-local window overview.** Press `Super+W` to inspect frozen
  thumbnails of every focusable window on the active workspace—including
  scrolling windows outside the current viewport—then navigate with arrows,
  H/J/K/L, or Tab and confirm without reconfiguring clients.
- **Ten in-process layouts.** Choose from master/stack `tile`, `monocle`,
  `grid`, `rows`, recursive `dwindle`, mirrored `reverse-dwindle`, column-based
  `scrolling`, `floating`, and
  `game-mode`, or compose up to four of the standard leaf layouts into fixed
  monitor regions. Layout selection can vary by output and workspace.
- **Game Mode that understands the rest of the desktop.** Anchor a game at a
  requested size and position while arranging companion windows with any of the
  standard tiling engines.
- **Rules that respect user intent.** Match app IDs and titles to select
  workspaces, layouts, placement, fullscreen state, floating state, opacity, or
  blur. Rule-owned state can be manually overridden instead of being forced
  back on every manage cycle.
- **First-class multi-monitor behavior.** Aqueous applies modes, scale,
  transform, adaptive sync, position, profiles, and hotplug changes directly
  through wlroots. Unconfigured displays receive non-overlapping automatic
  positions.
- **Wayland-native, with practical X11 support.** Layer shell, screencopy,
  session lock, pointer constraints, color management, and other modern Wayland
  protocols are supported. Optional XWayland is started and managed directly by
  Aqueous—no `xwayland-satellite` process is required.
- **A cohesive desktop without a mandatory suite.** The Git packages start
  Seafoam Labs' [DankMaterialShell](https://github.com/Seafoam-Labs/DankMaterialShell)
  fork (`dms-aqueous`) as their shell, while
  Aqueous continues to use standard layer-shell interfaces and does not embed
  the shell into the compositor.
  These packages include a native [Aqueous Settings plugin for Dank Material
  Shell](dms-plugin/README.md), with a bar popout and IPC-accessible window.

## Performance by design

Visual polish is useful only when the desktop still feels immediate. Aqueous
keeps policy and rendering close together: layouts return final placements,
the compositor applies them in a batched manage cycle, and damage-driven frames
advance only the visual state that is changing. Stable window handles and
per-output/workspace layout state avoid rebuilding policy in external clients.

Effects are also explicit build-time and runtime choices. Animations can be
compiled out with `-Danimations=false`; the Aqueous Vulkan effects backend is
enabled by default; and `-Dvulkan-effects=false` produces a stock-wlroots,
square/no-blur diagnostic build. Blur and opacity default to configurable
policy, and per-application rules can keep latency-sensitive surfaces fully
opaque and unblurred. Aqueous does not claim that effects are free—it makes
their cost visible and optional.

## Configuration

Aqueous discovers five compatible files in `~/.config/aqueous/`:

- `wm.toml` — bindings, actions, workspaces, struts, and global policy.
- `outputs.toml` — preferred physical display policy and output profiles; unset values inherit from `wm.toml`.
- `layout.toml` — layout defaults, slots, options, and workspace/output overrides.
- `input.toml` — XKB and libinput policy, plus optional gesture bindings.
- `rules.toml` — window and layer-shell matching, placement, state, and visual behavior.

Configuration changes are parsed into validated immutable snapshots and
hot-reloaded on the Wayland event loop. Invalid updates do not require a
compositor restart. Start with the repository's `wm.toml` and annotated
`*.toml.example` files.

```toml
# layout.toml
[layout]
default = "scrolling"
gaps_outer = 8
gaps_inner = 4

[layout.options.scrolling]
column_fraction = "0.5"
center_focused = "true"
```

```toml
# rules.toml
[[window]]
app_id = "com.example.Game"
layout = "game-mode"
output = "DP-2"
workspace = 9
blur = false
opacity = 1.0

[[layer]]
namespace = "waybar"
blur = true
blur_popups = true
```

Fractional-scale-aware clients use their exact output scale by default. For a
client whose toolkit produces softer glyphs at fractional device coordinates,
an opt-in rule can request an integer-ceil backing buffer while keeping the
window's logical size and output scale unchanged:

```toml
[[window]]
app_id = "com.example.Editor"
buffer_scale_policy = "integer-ceil"
```

This compatibility mode increases the client's pixel count and GPU/memory
cost. Aqueous ships no application-specific opt-ins; use `aqueousctl inspect
--rule` to obtain the exact, case-sensitive app ID before adding one.

See the [layout guide](docs/layout.md), [rules reference](docs/rules.md), and
[compositor interaction guide](docs/compositor-interactions.md) for the full
configuration and window-flow model.

### Inspecting windows, layers, outputs, and workspace layouts

The build installs `aqueousctl`, a Wayland client for discovering the exact
identities used by window rules, the modes advertised by each output, and the
active workspace layout:

```sh
aqueousctl windows
aqueousctl scene
aqueousctl windows --json
aqueousctl inspect --rule
aqueousctl outputs
aqueousctl outputs --json
aqueousctl overlay-planes
aqueousctl overlay-planes --json
aqueousctl layout --output DP-1 --json
aqueousctl layout --output DP-1 --set grid --json
```

The rule command emits ready-to-paste `[[window]]` entries. Native Wayland
windows use `app_id`; XWayland windows use their `WM_CLASS` as `class`.
The outputs command provides the full wlr-randr information set: identity,
physical size, enabled state, every advertised mode, logical position,
transform, scale, and adaptive-sync state. It also prints a quoted, stable
`sha256:` EDID identifier derived from the make, model, and serial when that
metadata is available. Its JSON form uses wlr-randr-compatible field names and
value types and exposes the identifier as `edid_sha256`. The current and
preferred modes are marked.
The layout command targets the explicitly named output and can apply an
immediate runtime override without editing configuration files.
`wlrctl toplevel list` remains supported through the legacy foreign-toplevel
management protocol for compatibility.

## Build

Building requires Zig 0.16 or newer, Wayland, wayland-protocols 1.49 or newer, libxkbcommon,
libinput, libevdev, pixman, Vulkan headers and loader, pkg-config, Meson, Ninja,
glslang, and the dependencies listed by wlroots 0.20. `-Dxwayland` builds
additionally require the `Xwayland` server executable (`xorg-xwayland` on Arch
Linux).

```sh
scripts/build-compositor.sh
```

For direct development:

```sh
cd compositor
scripts/build-wlroots-render-hook.sh
export PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig"
zig build test
scripts/test-color-management-luminance.sh
scripts/test-proton-hdr-color-management.sh
zig build -Doptimize=ReleaseSafe -Dxwayland -Dllvm
```

The default build uses the pinned Aqueous wlroots render hook, requires
wlroots' Vulkan renderer at startup, and installs that exact shared library
under `lib/aqueous` with an origin-relative runtime path. Use
`-Dvulkan-effects=false` only for the diagnostic stock-wlroots build.
Distribution builds should target a suitably generic CPU rather than
inheriting the build machine's instruction set.

The normal build contains only Aqueous's integrated policy. The retired
`river_window_manager_v1` external-policy path is available solely for
compatibility testing with `-Dexternal-policy=true`; shipped builds disable it
and do not include an external policy client.

## Run a nested development session

```sh
./launch_river.sh
```

The historically named launcher builds or selects Aqueous, starts it nested,
and launches Noctalia inside the new display. Set
`AQUEOUS_COMPOSITOR_BIN=/path/to/aqueous` to select a build or
`AQUEOUS_NOCTALIA_CMD` to replace the shell command. Logs are written to
`/tmp/aqueous.log` and `/tmp/noctalia.log` by default.

Packaged sessions use `/usr/bin/aqueous-wm` to launch `/usr/bin/aqueous`.
`/usr/bin/aqueous-init` exports the live Wayland environment and starts
graphical-session services; it does not start another window manager. For a
new Ghostty profile it also seeds `window-decoration = none`, allowing
Aqueous's compositor-provided rounded border to remain visible. Existing
Ghostty configuration is never overwritten. No greeter-specific configuration
is required beyond selecting the installed Aqueous Wayland session.

## Test

```sh
cd compositor
zig build test
scripts/test-color-management-luminance.sh
scripts/test-proton-hdr-color-management.sh
scripts/test-policy-parity.sh
scripts/test-server-decoration.sh
scripts/test-rule-output-placement.sh
scripts/test-xdg-fullscreen.sh
scripts/test-xdg-floating.sh
scripts/test-qt-transient-natural-size.sh
scripts/test-floating-outputs.sh
scripts/test-output-rotation-keybinding.sh
scripts/test-scaling.sh
scripts/test-cursor-theme.sh
```

The xdg fullscreen harness covers application-originated `xdg_toplevel`
fullscreen requests without relying on rules or compositor keybindings. The
xdg floating harness covers client-side move, edge-aware resize, maximize,
unmaximize, and minimize requests for persistent floats and workspace-floating
windows, and verifies that identical requests do not affect ordinary windows in
non-floating layouts. It also verifies persistent focus raising and hit testing
with overlapping floats. The Qt transient harness verifies that a portal-style
Qt dialog reaches its natural size without pointer input. The floating-output
harness covers active-workspace transfer across mixed scale/transform output
geometry and source-output removal during a drag. The integration harness maps
real Ghostty windows and injects
virtual keyboard and pointer input to exercise layouts, rules, focus, fullscreen,
keybindings, and repeated workspace changes. The scaling harness checks
client-side `wl_output` events, the embedded output service, and the headless
output commit pipeline.
The output-rotation harness verifies that the runtime quarter-turn keybinding
targets only the display beneath the pointer.

## Packaging

The packages install `/usr/bin/aqueous` and its `/usr/bin/aqueousctl` inspection
and workspace-layout client, plus the session launcher, environment hook,
default TOML configuration, desktop entry, and systemd user units.
`PKGBUILD-git`, `GitPKGBUILD/PKGBUILD`, the generic-CPU Intel variants, and
`PKGBUILD-DMS` depend on Seafoam Labs' `dms-aqueous` package. They include the
DMS settings plugin and screen-sharing chooser, start `aqueous-dms.service`,
and use DMS Spotlight and region screenshots in the packaged bindings.
The reference `PKGBUILD` and `PKGBUILD-bin` retain Noctalia integration.
`gitNoctalia/PKGBUILD` and its accompanying `aqueous.install` preserve the
previous Noctalia Git package, including its settings plugin and Welcome app.
It builds `aqueous-git` as an alternative to the DMS Git package.

When switching an existing profile to a Git package, update the launcher and
screenshot commands in `~/.config/aqueous/wm.toml` from the defaults in
`/usr/share/aqueous/wm.toml`; existing user files are preserved. Use
`dms ipc call spotlight toggle` for the launcher and `dms screenshot region`
for both screenshot actions and direct screenshot bindings. Disable any
manually enabled shell service or startup command before using the packaged
`aqueous-dms.service`, so the session runs one shell instance. The Noctalia
Welcome app is omitted from the Git packages; use DMS Settings for appearance.

Aqueous has no
.NET, `aqueous-wm-client`, `aqueous-outputd`, `wlr-randr`, or
`xwayland-satellite` runtime dependency.

## License and origin

Aqueous is licensed under GPL-3.0-only. See [ORIGIN.md](compositor/ORIGIN.md)
for upstream provenance and retained River-derived work.
