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
- **Basic screen mirroring.** Mirror an SDR output to a projector or capture
  card on the same device, with independent refresh and automatic letterboxing.
  See [configuration and limitations](docs/screen-mirroring.md).
- **Wayland-native, with practical X11 support.** Layer shell, screencopy,
  session lock, pointer constraints, color management, and other modern Wayland
  protocols are supported. Optional XWayland is started and managed directly by
  Aqueous—no `xwayland-satellite` process is required.
- **Choose your desktop.** The GTK [Welcome to Aqueous](welcome/README.md)
  installs and sets up Pearl (`pearl-de`), DankMaterialShell, Noctalia, or a
  shell-free session. Shelly handles package installation and all optional
  dependencies; the shell stays separate from the compositor.

## Performance by design

Visual polish is useful only when the desktop still feels immediate. Aqueous
keeps policy and rendering close together: layouts return final placements,
the compositor applies them in a batched manage cycle, and damage-driven frames
advance only the visual state that is changing. Stable window handles and
per-output/workspace layout state avoid rebuilding policy in external clients.

Effects are also explicit build-time and runtime choices. Animations can be
compiled out with `-Danimations=false`; the Aqueous Vulkan effects backend is
enabled by default; and `-Dvulkan-effects=false` produces a square/no-blur
diagnostic build using the same pinned wlroots. Blur and opacity default to
configurable policy, and per-application rules can keep latency-sensitive surfaces fully
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

### Persistent shell IPC

Aqueous exports `AQUEOUS_SOCKET` to session children and services. Shells can
connect directly for capability discovery, snapshots, acknowledged state deltas
and typed runtime commands, avoiding an aqueousctl process for each action.
The compositor hosts the nonblocking socket and shares its state and command
backend with the existing Wayland shell protocol.

See the [IPC v1 contract](compositor/protocol/aqueous-ipc-v1.md) and
[standalone DMS migration plan](docs/dms-ipc-socket-plan.md). DMS needs that
consumer migration to use the socket; settings and keybind configuration helpers
remain a separate follow-on. Existing aqueousctl commands remain supported.

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
`-Dvulkan-effects=false` only for the diagnostic build; it also needs the patched
wlroots library for protocol and scene APIs.
Distribution builds should target a suitably generic CPU rather than
inheriting the build machine's instruction set.

The normal build contains only Aqueous's integrated policy. The optional
`aqueous_window_manager_v1` external-policy path is available solely for
diagnostic testing with `-Dexternal-policy=true`; shipped builds disable it
and do not include an external policy client.

Aqueous's compositor-specific Wayland protocols use the `aqueous_` namespace.
The inherited River protocol names have been replaced completely. Clients using
those interfaces must regenerate bindings from the Aqueous XML definitions
installed under `share/aqueous-protocols/stable/` and update their interface
names. No River aliases or fallback interfaces are provided. Standard Wayland
and upstream extension names are unchanged.

Package builds recreate their generated protocol staging directory. For manual
in-place installations, use a clean staging prefix: `zig build install` does not
remove XML files left by an older installation.

## Run a nested development session

```sh
./launch_aqueous.sh
```

The launcher builds or selects Aqueous, starts it nested,
and launches DMS (`dms run`) inside the new display. Set
`AQUEOUS_COMPOSITOR_BIN=/path/to/aqueous` to select a build or
`AQUEOUS_DMS_CMD` to replace the shell command, including any arguments. Logs
are written to `/tmp/aqueous.log` and `/tmp/dms.log` by default.

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
python3 scripts/test-output-focus.py
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

## Configuration helper

[aqueous-config](settingsApplication/README.md) provides canonical configuration
reading, validation, persistence, generation checks, backups and toolkit sync.
Pearl replaces the retired Aqueous Settings GUI. Existing protocol-1 clients and
scripts remain supported; use `aqueous-config snapshot --shell none` for neutral
operation. The default helper build has no GUI dependency or desktop launcher.

## Packaging

Fedora users can build and install the latest Git `master` as a local RPM:

```sh
bash scripts/fedora-install.sh
```

Run as your normal user; the script uses sudo for DNF transactions. See the
[Fedora installation guide](docs/fedora-install.md) for dependencies, DMS
repository options, building without installing, and removal.

The packages install `/usr/bin/aqueous` and its `/usr/bin/aqueousctl` inspection
and workspace-layout client, plus the session launcher, environment hook,
default TOML configuration, desktop entry, and systemd user units.
Arch packages also provide `/etc/xdg/menus/aqueous-applications.menu` for
application menus in sessions using `XDG_MENU_PREFIX=aqueous-`.
All Arch source variants and the release archive include the GTK welcome app,
Shelly, and a terminal without requiring a desktop shell. On first login, choose
Pearl (`pearl-de`), DMS (`dms-shell`), Noctalia, or Nothing. Welcome answers
Shelly's password request through a GTK popup and selects all optional dependencies.
A normal launcher invocation can reopen setup later. Existing completion markers
are honored; upgrades do not force the wizard onto established users.

The selection is stored in `~/.config/aqueous/session.toml` and becomes active at
the next login. Conditional Aqueous user units start exactly the selected shell;
upstream shell units are suppressed only inside Aqueous. Existing custom startup
files must be reviewed when they conflict. Shell packages and preferences remain
installed when switching, including when choosing Nothing.

Packaged launcher, screenshot and lock actions follow the active session.
`Super+Return` opens Ghostty, and `Super+Shift+F1` reopens welcome. Pearl and Nothing
use the GTK screen-sharing picker; DMS and Noctalia use their own integration.
Welcome preserves custom commands and updates recognized legacy shell bindings
through `aqueous-config`, with a recovery journal and backups. See the
[welcome documentation](welcome/README.md) for recovery and verification details.

Fedora and NixOS retain their existing installation and declarative shell setup;
Shelly installation in welcome currently targets Arch-compatible systems.

Aqueous has no
.NET, `aqueous-wm-client`, `aqueous-outputd`, `wlr-randr`, or
`xwayland-satellite` runtime dependency.

## License and origin

Aqueous is licensed under GPL-3.0-only. See [ORIGIN.md](compositor/ORIGIN.md)
for upstream provenance and retained River-derived work.
