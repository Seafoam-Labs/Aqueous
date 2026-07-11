# Aqueous

Aqueous is a single-process Wayland compositor and window manager based on
[River](https://codeberg.org/river/river). The compositor, layouts, rules,
focus/workspace policy, input handling, screencopy, and output management are
implemented in Zig under `compositor/`. No .NET runtime or policy sidecar is
required. [Noctalia](https://github.com/noctalia-dev/noctalia) provides the
external desktop shell.

## Build

Requirements include Zig 0.16 or newer, wlroots 0.20, Wayland and
wayland-protocols, libxkbcommon, libinput, libevdev, pixman, and pkg-config.
SceneFX and Xwayland support are selected by build options.

```sh
scripts/build-compositor.sh
```

The script builds `compositor/` and stages the only required WM/compositor
executable at `bin/aqueous`. For direct development:

```sh
cd compositor
zig build test
zig build -Doptimize=ReleaseSafe -Dxwayland -Dllvm
```

Normal builds contain only the integrated policy. The retired
`river_window_manager_v1` external-policy path can be enabled for protocol
compatibility testing with `-Dexternal-policy=true`; it is disabled in shipped
builds and has no bundled client.

## Run

```sh
./launch_river.sh
```

This starts a nested Aqueous session and Noctalia. Set
`AQUEOUS_COMPOSITOR_BIN=/path/to/aqueous` to use a prebuilt compositor or
`AQUEOUS_NOCTALIA_CMD` to override the shell command. Logs are written to
`/tmp/aqueous.log` and `/tmp/noctalia.log`.

Packaged sessions use `/usr/bin/aqueous-wm`, which launches
`/usr/bin/aqueous`. `/usr/bin/aqueous-init` only exports the live Wayland
environment and starts graphical-session services; it does not launch another
window manager.

## Configuration

Aqueous discovers compatible TOML files in `~/.config/aqueous/`:

- `wm.toml` — actions, key/pointer bindings, workspaces, struts, outputs, and
  global policy.
- `layout.toml` — all eight built-in layouts and their options.
- `input.toml` — XKB and libinput policy.
- `rules.toml` — window matching, placement, state, and per-app behavior.

Configuration is hot-reloaded by the compositor. Output modes, scale,
transform, position, adaptive sync, profiles, persistence, and hotplug are
applied directly through wlroots. Display-panel integrations can use the
compatible JSON socket at `$XDG_RUNTIME_DIR/aqueous/outputd.sock`; this is an
in-process service despite the legacy socket name.

See [layout documentation](docs/layout.md), [rules documentation](docs/rules.md),
and the annotated `*.toml.example` files for details.

## Test

```sh
cd compositor
zig build test
scripts/test-policy-parity.sh
scripts/test-scaling.sh
```

The policy test verifies that implicit/default and explicit internal mode
produce matching traces and that production builds reject external mode. The
scaling test exercises the embedded output protocol and headless output commit
pipeline.

## Packaging

The reference `PKGBUILD` and release workflow build and ship one required
binary: `/usr/bin/aqueous`. The package also installs the session launcher,
environment hook, default TOML configuration, desktop entry, systemd user
units, and shell assets. It has no .NET, `aqueous-wm-client`,
`aqueous-outputd`, or `wlr-randr` dependency.
