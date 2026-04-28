# Aqueous

A minimal Wayland window manager built on top of [River](https://codeberg.org/river/river),
written in C# / .NET 10. The bar/shell is provided by the external
[Noctalia](https://github.com/noctalia-dev/noctalia-shell) project.

---

### Components

| Component        | Description                                           |
|------------------|-------------------------------------------------------|
| `Aqueous`        | Wayland/River compositor client (the window manager) |
| `Aqueous.Tests`  | Unit tests for `Aqueous`                             |
| `Aqueous.InputDaemon` (`aqueous-inputd`) | Privileged libinput sidecar — owns its own libinput context and applies `[input.*]` config (pointer accel, tap-to-click, natural scroll, …) on device add and on every config reload. River 0.4 exposes no Wayland API for libinput configuration, so this runs out-of-process. Talks to `Aqueous` over `$XDG_RUNTIME_DIR/aqueous-inputd.sock`. |
| Noctalia (external) | Bar / shell (`qs -c noctalia-shell`)              |
| tuigreet (external) | Login greeter                                     |

---

### Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/)
- [River](https://codeberg.org/river/river) compositor
- [Noctalia](https://github.com/noctalia-dev/noctalia-shell) (`qs` / Quickshell)
- [tuigreet](https://github.com/apognu/tuigreet) (optional, for login)
- `wayland`, `wayland-protocols`, `libxkbcommon`, `libinput`, `pixman`,
  `libdrm`, `libevdev`

---

### Build

```bash
dotnet build Aqueous.slnx
```

### Test

```bash
dotnet test Aqueous.Tests/Aqueous.Tests.csproj
```

### Run (nested River session)

```bash
./launch_river.sh
```

This starts a nested River instance, launches `Aqueous`, and spawns
Noctalia (`qs -c noctalia-shell`) as the bar. Logs land in `/tmp/`:

- `/tmp/river_log.txt` — River compositor + WAYLAND_DEBUG trace
- `/tmp/aqueous_wm.log` — Aqueous stdout/stderr
- `/tmp/noctalia.log` — Noctalia stdout/stderr

---

### Configuration

`wm.toml` (place at `~/.config/aqueous/wm.toml`) configures layouts, gaps,
keybindings, outputs, etc. See the file in this repo for an annotated example.

---

### Packaging

A reference Arch `PKGBUILD` is included; it builds `Aqueous` AOT and
declares `noctalia-shell` and `tuigreet` as runtime dependencies.

---

### TODO

- [x] Pointer acceleration: apply `[input]` settings at runtime via the
  `aqueous-inputd` libinput sidecar (River 0.4 has no Wayland-side API
  for this; the daemon owns its own libinput context, niri-style).
- [x] Per-device input config (`[input.mouse]`, `[input.touchpad]`,
  `[input.trackpoint]`) matching niri's KDL schema for easy migration.
- [x] Live-reload of `[input]` settings on config reload keybind
  (Aqueous re-sends `apply` to the daemon; daemon re-applies to all
  open devices).
- [ ] `aqueous-inputd`: replace `open(O_RDWR)` with `logind`'s
  `TakeDevice` D-Bus call so the daemon doesn't need the user to be in
  the `input` group.
- [ ] Route floating placement through `FloatingLayout` engine instead of
  the bespoke loop in `LayoutProposer`, and propagate `FloatRect` through
  `WindowEntryView`.
- [ ] Decoration-node based stacking (`get_decoration_above` /
  `get_decoration_below`) for sub-cycle stacking control.
- [ ] Runtime behavioural tests under a live River 0.4 session
  (bring-to-front, focus-follows-mouse, floating centre-on-open).
- [ ] More layout engines and per-output layout overrides.
- [ ] Scratchpad polish: animations, multi-scratchpad bindings.
- [ ] Documentation: annotated `wm.toml` reference and keybind cheatsheet.
