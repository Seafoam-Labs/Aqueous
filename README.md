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
- [xwayland-satellite](https://github.com/Supreeeme/xwayland-satellite) — rootless XWayland bridge (River has no built-in XWayland; satellite is launched by Aqueous via `[[exec]]` in `wm.toml`).
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

### Autostart

Aqueous launches supervised commands itself via `[[exec]]` blocks in
`wm.toml`. Each entry fires once after River advertises all its globals
(so layer-shell clients like the bar attach successfully on first
connect). Commands run via `/bin/sh -c` detached with `setsid`.

```toml
[[exec]]
name    = "noctalia"
command = "qs -c noctalia-shell"
when    = "startup"          # "startup" (default) | "reload" | "always"
once    = true               # don't relaunch on --reload
restart = false              # respawn (with backoff) on non-zero exit
log     = "/tmp/noctalia.log"
env     = { QT_QPA_PLATFORM = "wayland" }
```

Backoff for `restart = true` follows 250 ms → 500 → 1 s → 2 s → 4 s →
8 s → cap 10 s, and resets on a clean (`exit 0`) termination. Setting
`restart = true` on a `when = "reload"` entry is allowed but rarely
useful.

---

### Packaging

A reference Arch `PKGBUILD` is included; it builds `Aqueous` and
`aqueous-inputd` AOT and ships:

- `/usr/bin/aqueous`, `/usr/bin/aqueous-inputd`, `/usr/bin/aqueous-wm`
  (session launcher).
- `/usr/share/wayland-sessions/aqueous.desktop` so any Wayland-capable
  display manager (greetd/tuigreet, GDM, SDDM, …) lists **Aqueous** in
  its session picker.
- `/etc/xdg/aqueous/wm.toml` as the system default; `aqueous-wm` seeds
  `~/.config/aqueous/wm.toml` on first login if missing.
- `aqueous-inputd.{service,socket}` systemd user units (opt-in via
  `systemctl --user enable --now aqueous-inputd.socket`; otherwise the
  launcher spawns the daemon directly).

For a turn-key login experience see
`packaging/greetd/config.toml.example` (greetd + tuigreet, with an
optional autologin snippet).

---

### TODO

#### Known bugs

- [x] Monocle layout crashes the WM — `LayoutProposer` drops `Visible=false`
      placements with `Rect.Empty` on the floor (zero-dimension guard fires
      before the visibility check). See
      `scratches/monocole_currently_causes_wm_crash.md`.
- [x] Fullscreen demote path is fragile; there is no dedicated
      `exit_fullscreen` action — only the `toggle_fullscreen` chord
      (`Super+Shift+F`) can leave fullscreen. See
      `scratches/currently_fullscreening_a_window_cannot.md` and
      `scratches/keycombo_to_unfullscreen.md`.

#### Compositor / shell integration

- [x] Reserved space for the bar (currently hardcoded to 24px) — implement
      proper `wlr-layer-shell` exclusive-zone negotiation so bars of any
      height and on any edge work.
- [ ] Support for multiple outputs (technically works but a bit hacky) —
      per-output tag state, hot-plug add/remove, per-output
      layout/scale/transform persistence, "move window/workspace to next
      output" semantics.
- [ ] `[[output]]` config block: mode, scale, position, transform, VRR /
      adaptive-sync, DPMS / power management.
- [ ] Fractional-scale (`wp-fractional-scale-v1`) and `viewporter` story for
      mixed-DPI setups.
- [ ] `gamma-control` / night-light support.
- [ ] Cursor theme and size configuration.

#### IPC / control surface

- [ ] `aqueousctl` IPC socket: query focused tag/window/title, dispatch any
      `KeyBindingAction`, trigger config reload, drive status bars and
      scripts (`swaymsg`-style). Today only `aqueous-inputd.sock` exists
      and it is libinput-only.
- [ ] On-the-fly config reload from a keybind / external tool, with error
      reporting when `wm.toml` is malformed.
- [ ] Man page, shell completions, log rotation (logs currently land in
      `/tmp/*.log` from `launch_river.sh`).

#### Window management features

- [ ] Window rules (`[[rule]]` matching `app_id` / `class` / `title` →
      float / tile / tag / size / position / sticky). Required for things
      like "always float `pavucontrol`" or "send `firefox` to tag 2".
- [x] XWayland transport (rule-free): `xwayland-satellite` launched via
      `[[exec]]` in `wm.toml`; session launcher exports `DISPLAY=:0`,
      `QT_QPA_PLATFORM=wayland;xcb`, `GDK_BACKEND=wayland,x11`,
      `SDL_VIDEODRIVER=wayland,x11`, `MOZ_ENABLE_WAYLAND=1`,
      `_JAVA_AWT_WM_NONREPARENTING=1`, and `XCURSOR_*`.
- [ ] XWayland policy / rules engine (Steam, JetBrains splash, Zoom, …) —
      `xwayland_shell_v1` binding, `RuleMatch.XWayland`, auto-float
      heuristics for `_NET_WM_WINDOW_TYPE` (`DIALOG`, `UTILITY`, `SPLASH`,
      …) and non-null `WM_TRANSIENT_FOR`.
- [ ] Floating-window keybinds: toggle-float on focused tile, move/resize
      by keys, center-on-spawn, remembered geometry.
- [ ] Surface `Features/SnapZones` as a daily-use feature (pointer
      drag-to-snap for floating windows).
- [ ] Dedicated `exit_fullscreen` action (separate from
      `toggle_fullscreen`) and audit of all state-transition bindings.
- [ ] Scratchpad / iconify-equivalent semantics.
- [ ] `xdg-activation-v1` "demand attention" → tag urgency highlight for
      bars.

#### Session services

- [ ] Idle / lock / DPMS: `ext-idle-notify-v1`, `idle-inhibit-v1`,
      `lock_command` config key. Watching video should inhibit blanking.
- [x] Screencopy: `wlr-screencopy-unstable-v1` (v3) is exposed by
      RiverDelta and bound in-process by `WlrScreencopyClient`
      (`wl_shm` + `memfd_create` path). `xdg-desktop-portal-wlr` rides
      on the same global, so browser / Discord / OBS screen sharing
      works out of the box once the portal package is installed.
- [ ] Clipboard-persistence daemon (or document `wl-clip-persist`) and
      primary-selection guarantees beyond what River provides.
- [ ] Per-seat keyboard layout switching exposed as a `KeyBindingAction`
      (today only the input daemon applies static config).
