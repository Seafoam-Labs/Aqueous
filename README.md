# Aqueous

**A visually expressive Wayland compositor that keeps the fast path fast.**

Aqueous combines a native tiling window manager, fluid compositor-side motion,
and optional SceneFX effects in one Zig process. It is designed for desktops
that should look deliberate—rounded windows, backdrop blur, focus-aware
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
  monocle, grid, rows, and game-focused layouts without replacing the window
  manager or installing layout extensions.
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

- **Effects with an off switch.** SceneFX builds provide rounded corners and
  optimized backdrop blur. Opacity can be global, focus-sensitive, or selected
  by application rules. Expensive effects can be disabled globally or avoided
  for games and fullscreen media.
- **Motion owned by the compositor.** Window placement animates at render time,
  scrolling layouts move as a viewport, and workspace changes can slide without
  making the layout engine or clients produce intermediate geometry.
- **Eight in-process layouts.** Choose from master/stack `tile`, `monocle`,
  `grid`, `rows`, recursive `dwindle`, column-based `scrolling`, `floating`, and
  `game-mode`. Layout selection can vary by output and workspace.
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
- **A cohesive desktop without a mandatory suite.** The packaged session starts
  [Noctalia](https://github.com/noctalia-dev/noctalia) as its shell, while
  Aqueous continues to use standard layer-shell interfaces and does not embed
  the shell into the compositor.

## Performance by design

Visual polish is useful only when the desktop still feels immediate. Aqueous
keeps policy and rendering close together: layouts return final placements,
the compositor applies them in a batched manage cycle, and damage-driven frames
advance only the visual state that is changing. Stable window handles and
per-output/workspace layout state avoid rebuilding policy in external clients.

Effects are also explicit build-time and runtime choices. Animations can be
compiled out with `-Danimations=false`; SceneFX can be selected with
`-Dscenefx=true|false`; blur and opacity default to configurable policy; and
per-application rules can keep latency-sensitive surfaces fully opaque and
unblurred. Aqueous does not claim that effects are free—it makes their cost
visible and optional.

## Configuration

Aqueous discovers four compatible files in `~/.config/aqueous/`:

- `wm.toml` — bindings, actions, workspaces, struts, outputs, and global policy.
- `layout.toml` — layout defaults, slots, options, and workspace/output overrides.
- `input.toml` — XKB and libinput policy.
- `rules.toml` — application matching, placement, state, and visual behavior.

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
blur = false
opacity = 1.0
```

See the [layout guide](docs/layout.md), [rules reference](docs/rules.md), and
[compositor interaction guide](docs/compositor-interactions.md) for the full
configuration and window-flow model.

## Build

Building requires Zig 0.16 or newer, wlroots 0.20, Wayland,
wayland-protocols, libxkbcommon, libinput, libevdev, pixman, and pkg-config.
SceneFX is optional. `-Dxwayland` builds additionally require the `Xwayland`
server executable (`xorg-xwayland` on Arch Linux).

```sh
scripts/build-compositor.sh
```

For direct development:

```sh
cd compositor
zig build test
zig build -Doptimize=ReleaseSafe -Dxwayland -Dllvm
```

SceneFX is auto-detected. Production and package builds should select desired
features explicitly, and distribution builds should target a suitably generic
CPU rather than inheriting the build machine's instruction set.

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
graphical-session services; it does not start another window manager. No
greeter-specific configuration is required beyond selecting the installed
Aqueous Wayland session.

## Test

```sh
cd compositor
zig build test
scripts/test-policy-parity.sh
scripts/test-scaling.sh
```

The integration harness maps real Ghostty windows and injects virtual keyboard
and pointer input to exercise layouts, rules, focus, fullscreen, keybindings,
and repeated workspace changes. The scaling harness checks client-side
`wl_output` events, the embedded output service, and the headless output commit
pipeline.

## Packaging

The reference `PKGBUILD`, `PKGBUILD-bin`, and generic-CPU `PKGBUILD-intel`
install one required compositor binary: `/usr/bin/aqueous`. Packages also
provide the session launcher, environment hook, default TOML configuration,
desktop entry, systemd user units, and Noctalia integration. Aqueous has no
.NET, `aqueous-wm-client`, `aqueous-outputd`, `wlr-randr`, or
`xwayland-satellite` runtime dependency.

## License and origin

Aqueous is licensed under GPL-3.0-only. See [ORIGIN.md](compositor/ORIGIN.md)
for upstream provenance and retained River-derived work.
