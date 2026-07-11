# Aqueous compositor

This directory contains the Zig implementation of Aqueous: a wlroots-based
Wayland compositor with integrated window-management, input, and output policy.

## Building

Required development libraries include Wayland, wayland-protocols, wlroots
0.20, libxkbcommon, libinput, libevdev, pixman, and pkg-config. Zig 0.16 or
newer is required; scdoc is optional for man pages.

```sh
zig build -Doptimize=ReleaseSafe -Dxwayland
zig build test
```

SceneFX is auto-detected and can be selected explicitly with
`-Dscenefx=true|false`. Production builds run integrated policy by default.
For legacy protocol compatibility testing only,
`-Dexternal-policy=true` enables the `external` and `compare` policy modes.

## Usage

Run `zig-out/bin/aqueous` nested in an existing Wayland/X11 session or from a
TTY using DRM/KMS. `-policy internal` is accepted explicitly but is also the
default. Aqueous loads its TOML configuration and directly manages layouts,
focus, workspaces, bindings, startup commands, screencopy, and outputs.

The headless cutover and output checks are:

```sh
scripts/test-policy-parity.sh
scripts/test-scaling.sh
```

See `PACKAGING.md`, `ORIGIN.md`, and the repository-level README for packaging,
source provenance, and session integration.
