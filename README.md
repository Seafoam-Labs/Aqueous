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

- [ ] Reserved space for the bar (currently hardcoded to 24px)
- [ ] Support for multiple outputs (Technically  works but a bit hacky)
