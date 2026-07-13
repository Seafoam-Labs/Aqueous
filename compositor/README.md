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

The same build produces `zig-out/bin/aqueousctl`. While running inside an
Aqueous session, use `aqueousctl windows`, `aqueousctl windows --json`, or
`aqueousctl inspect --rule` to inspect mapped native and XWayland windows.

The headless cutover and output checks are:

```sh
scripts/test-policy-parity.sh
scripts/test-scaling.sh
scripts/test-xwayland-input.sh
```

The policy harness requires Ghostty and `wlrctl`; it maps real windows and
injects virtual keyboard/pointer input instead of testing an idle compositor.
The XWayland harness additionally requires a build with `-Dxwayland`,
XWayland, a C compiler, `wayland-scanner`, and X11/Wayland/xkbcommon development
files. It verifies active keyboard grabs and pointer confinement for real X11
clients under the headless backend.

See `ORIGIN.md` and the repository-level README for source provenance,
packaging, and session integration.
