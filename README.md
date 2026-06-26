# Aqueous
A minimal Wayland window manager built on top of **RiverDelta** — a fork of
[River](https://codeberg.org/river/river) vendored in-tree at `compositor/` —
written in C# / .NET 10. The bar/shell is provided by the external
[Noctalia](https://github.com/noctalia-dev/noctalia) project (v5, the native
C++/OpenGL ES shell).

Aqueous is a single-repo project: the .NET window manager and the Zig
compositor live side-by-side. No submodules, no extra clone steps —
`git clone` is enough. See `compositor/ORIGIN.md` and
`docs/architecture.md` for the why.

---

### Components

| Component        | Description                                           |
|------------------|-------------------------------------------------------|
| `Aqueous`        | Wayland/River compositor client (the window manager) |
| `Aqueous.Tests`  | Unit tests for `Aqueous`                             |
| Noctalia (external) | Bar / shell (`noctalia`; v5 native)               |
| tuigreet (external) | Login greeter                                     |

---

### Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/)
- [Zig](https://ziglang.org/) ≥ 0.16.0 — needed to build the in-tree
  RiverDelta compositor at `compositor/`. On Arch, `zig-master-bin` (AUR)
  currently provides 0.16.x.
- [Noctalia](https://github.com/noctalia-dev/noctalia) v5 — the native
  C++/OpenGL ES shell, launched as `noctalia` (not the v4 Quickshell `qs` line)
- [xwayland-satellite](https://github.com/Supreeeme/xwayland-satellite) — rootless XWayland bridge (River has no built-in XWayland; satellite is launched by Aqueous via `[[exec]]` in `wm.toml`).
- [tuigreet](https://github.com/apognu/tuigreet) (optional, for login)
- `wayland`, `wayland-protocols`, `libxkbcommon`, `libinput`, `pixman`,
  `libdrm`, `libevdev` (full list mirrors `compositor/PACKAGING.md`).

---

### Build

```bash
# Window manager (.NET)
dotnet build Aqueous.slnx

# Compositor (Zig). Produces ./bin/riverdelta.
scripts/build-compositor.sh
```

`launch_river.sh` rebuilds the compositor on demand if `./bin/riverdelta`
is missing or older than the sources under `compositor/`, so for normal
dev iteration you can just `./launch_river.sh`. For compositor-only
iteration: `cd compositor && zig build`.

To skip the in-tree compositor and use a system one (or a prebuilt
path), set `AQUEOUS_RIVER_BIN=/path/to/riverdelta` before running
`launch_river.sh`.

### Test

```bash
dotnet test Aqueous.Tests/Aqueous.Tests.csproj
```

### Run (nested River session)

```bash
./launch_river.sh
```

This starts a nested River instance, launches `Aqueous`, and spawns
Noctalia (`noctalia`) as the bar. (In a packaged session the bar is started
as a systemd user unit instead — see Autostart below; the nested dev run has
no user systemd manager, so `launch_river.sh` launches it directly. Override
the command with `AQUEOUS_NOCTALIA_CMD`.) Logs land in `/tmp/`:

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
name    = "swayidle"
command = "swayidle -w timeout 300 'swaylock -f'"
when    = "startup"          # "startup" (default) | "reload" | "always"
once    = true               # don't relaunch on --reload
restart = true               # respawn (with backoff) on non-zero exit
log     = "/tmp/swayidle.log"
env     = { QT_QPA_PLATFORM = "wayland" }
```

Backoff for `restart = true` follows 250 ms → 500 → 1 s → 2 s → 4 s →
8 s → cap 10 s, and resets on a clean (`exit 0`) termination. Setting
`restart = true` on a `when = "reload"` entry is allowed but rarely
useful.

**The bar (Noctalia) is intentionally not an `[[exec]]` entry.** It hosts the
system-tray `org.kde.StatusNotifierWatcher`, and launching it from `[[exec]]`
(after Aqueous has already started, post `xdg-desktop-autostart.target`) makes
it lose the startup race against autostarted tray apps (`nm-applet`,
`blueman-applet`, …) — their icons never populate. Instead it ships as a
systemd user unit (`packaging/noctalia.service`) that is
`WantedBy=graphical-session.target` and ordered `Before=xdg-desktop-autostart.target`,
so the watcher is up before any tray app registers. `ExecStart` runs the v5
native shell as `noctalia --daemon`, which forks the shell and returns once it
is up; `Type=forking` makes systemd wait for that return before marking the
unit active (a real readiness barrier) and tracks the surviving shell as the
unit's main process.

---

### Packaging

A reference Arch `PKGBUILD` is included; it builds `Aqueous` AOT and ships:

- `/usr/bin/aqueous`, `/usr/bin/aqueous-wm` (session launcher).
- `/usr/share/wayland-sessions/aqueous.desktop` so any Wayland-capable
  display manager (greetd/tuigreet, GDM, SDDM, …) lists **Aqueous** in
  its session picker.
- `/etc/xdg/aqueous/wm.toml` as the system default; `aqueous-wm` seeds
  `~/.config/aqueous/wm.toml` on first login if missing.
- `noctalia.service` (a `graphical-session.target` user unit, ordered
  `Before=xdg-desktop-autostart.target`) plus a `graphical-session.target.wants`
  symlink, so the bar / SNI tray watcher starts before autostarted tray apps.

Libinput configuration (pointer accel, tap-to-click, natural scroll, …)
is applied by `Aqueous` itself via the `river_libinput_config_v1`
Wayland protocol — no separate input daemon is involved.

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
- [ ] The scrolling layout is broken – it stacks windows on top of each other
      instead of scrolling them.

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
- [x] Fractional-scale (`wp-fractional-scale-v1`) and `viewporter` story for
      mixed-DPI setups — RiverDelta advertises `wp_fractional_scale_manager_v1`,
      `wp_viewporter`, and `wl_compositor` v6; `wlr_scene` notifies each surface
      of its per-output preferred (fractional) and `preferred_buffer_scale`
      based on the output(s) it intersects, recomputed on every scale commit.
- [ ] `gamma-control` / night-light support.
- [ ] Cursor theme and size configuration.

#### IPC / control surface

- [ ] `aqueousctl` IPC socket: query focused tag/window/title, dispatch any
      `KeyBindingAction`, trigger config reload, drive status bars and
      scripts (`swaymsg`-style).
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
- [ ] Dedicated `exit_fullscreen` action (separate from
      `toggle_fullscreen`) and audit of all state-transition bindings.
- [ ] Scratchpad / iconify-equivalent semantics.
- [ ] `xdg-activation-v1` "demand attention" → tag urgency highlight for
      bars.

#### Session services

- [x] Idle / lock / DPMS: `ext-idle-notify-v1`, `idle-inhibit-v1`,
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
