# Aqueous — Remaining Work

Status snapshot of what is still outstanding to complete the River port and
reach feature parity with the existing Wayfire backend. See
[`docs/river-port.md`](docs/river-port.md) for the full phase-by-phase
history of what has already landed.

Last updated: 2026-04-23.

---

## 1. Live validation (blocking gate for everything below)

Most of the new code — the hand-rolled Wayland clients in particular — has
only been build/AOT-verified. It has **not** been run against a live River
session. A protocol mistake in the unmanaged interface tables can crash the
whole compositor, so live iteration must happen before any further scope is
added.

- [ ] **Phase 3 read-side validation matrix** (`docs/river-port.md` §Phase 3).
      Run Aqueous as a bar under a real River session and walk every row:
      tag switch, output focus, hotplug, view focus, urgent flag, mode
      change, clean shutdown.
- [ ] **Phase 4b foreign-toplevel validation** — start Aqueous with
      `AQUEOUS_FOREIGN_TOPLEVEL=1` under a wlr-foreign-toplevel–capable
      compositor and confirm:
  - [ ] `ListViews()` enumerates real toplevels.
  - [ ] `FocusView(id)` activates the window.
  - [ ] `CloseView(id)` closes it.
  - [ ] `MinimizeView(id, true)` is honoured (compositor-dependent).
  - [ ] `FocusedViewInfo.AppId` tracks the activated toplevel.
  - [ ] No proxy leak after a long session (destroy-on-closed path).
- [ ] **Phase B1a WM-skeleton smoke run** — launch a *nested* River
      (`river -c "sh -c 'aqueous &'"`) with `AQUEOUS_RIVER_WM=1` and
      `WAYLAND_DEBUG=1`; walk the validation matrix in
      `docs/river-port.md` §Phase B1a. Expect 1–3 iterations fixing
      signatures in `WlInterfaces.BuildRiverWindowManagement()`.

## 2. Phase 4b — foreign-toplevel polish

Small items left once the write path is validated:

- [ ] `set_fullscreen` / `unset_fullscreen` (wlr v2+) — interface table
      already declares them; no Aqueous consumer calls them yet.
- [ ] `set_rectangle` — same status.
- [ ] Explicit `destroy` pass on `closed` / `finished` to keep long-lived
      sessions from leaking handles.
- [ ] Promote `AQUEOUS_FOREIGN_TOPLEVEL` from opt-in to default-on once
      validated on a real session.

## 3. Phase B1b+ — real River window-manager client

The B1a skeleton only auto-acks `manage_finish` / `render_finish`. To make
`AQUEOUS_RIVER_WM=1` usable as a daily driver the following are required.
Each is a significant project in its own right.

- [ ] **B1b — trivial layout.** Emit `propose_dimensions` / `set_borders` /
      `show` during `manage_start` so windows render at sane sizes.
- [ ] **B1c — keybindings.** Bind `river_input_manager_v1` +
      `river_xkb_bindings_v1`; without this the WM mode has no bindings at
      all.
- [ ] **B1d — focus policy.** Per-seat focus tracking and
      `river_seat_v1.focus_window` wiring.
- [ ] **B1e — tag / workspace model.** Map Aqueous's existing tag semantics
      onto `river_window_v1.set_tags` and surface the result in
      `RiverStateAggregator` so the bar keeps working in WM mode.
- [ ] **B1f — proxy lifecycle.** Send `destroy` on `closed` / `removed`
      events in `RiverWindowManagerClient`; currently proxies accumulate.
- [ ] **B1g — safety net.** Systemd user unit / River `init` snippet that
      launches Aqueous with `AQUEOUS_RIVER_WM=1` *and* a fallback WM so a
      crash doesn't leave the user with a headless compositor.

## 4. Phase 6 — `RiverConfigService`

- [ ] Idempotent generator for `~/.config/river/init` mirroring the
      existing `wayfire.ini` emitter (keybindings, autostart, spawn rules,
      tag bitmasks).
- [ ] Settings-page parity: anything exposed in the current Wayfire
      Settings UI must have a River-equivalent control or a clearly labelled
      "not supported on River" state.

## 5. Phase 7 — Greeter & packaging swap

- [ ] `AqueousGreeter` session entry switched from Wayfire to River.
- [ ] `aqueous.desktop` / `aqueous.install` updated accordingly.
- [ ] `PKGBUILD`:
  - [ ] Drop `wayfire` / `wf-config` / any Wayfire-only deps.
  - [ ] Add `river` (already) and any protocol/runtime packages surfaced by
        §3 work.
  - [ ] `aqueous-dev-setup.sh` — mirror for dev environments.

## 6. Phase 8 — Wayfire removal

- [ ] Delete `WayfireBackend.cs` and its IPC helpers.
- [ ] Delete `wayfire.ini` template + generator.
- [ ] Delete `aqueous-wayfire-setup.sh`.
- [ ] Remove the `AQUEOUS_BACKEND=wayfire` fallback in `Program.cs`.
- [ ] Strip Wayfire-specific branches from `ICompositorBackend` consumers.

## 7. Phase 9 — Release

- [ ] Live-session smoke matrix (bar + WM + greeter + packaging, on a fresh
      install).
- [ ] AOT publish regression run (`dotnet publish … /p:PublishAot=true`)
      with zero new warnings.
- [ ] Update `README.md`:
  - [ ] Supported-compositors matrix (Wayfire → legacy, River → current).
  - [ ] River semantics section: 32-tag bitmask, 3×3 grid mapping in
        `GetWorkspace`, no per-view IDs without foreign-toplevel,
        WM-replacement caveats, `AQUEOUS_*` env vars.
- [ ] Tag `vX.0.0-river`.

## 8. Housekeeping

- [ ] Commit the currently-unstaged River port tree in logical chunks
      (bindings, services, WM client, foreign-toplevel client, docs,
      packaging).
- [ ] Decide whether `docs/` ships in the package or stays repo-only.
- [ ] AstalRiver smoke tests (`AqueousBindings/AstalRiver.Tests`) are green
      in skipped state; re-run them on a host with a live River session so
      the three `[SkippableFact]`s actually execute.

## 9. Known environment gaps on the current dev host

- `riverctl` is **not packaged** in the installed `river 0.4.3`; Phase 4's
  `riverctl`-based write paths silently no-op here. Install the
  `river-git` / AUR build, or rely exclusively on the foreign-toplevel and
  WM clients for validation.
- `WaylandDotnet` NuGet (scanner 0.2.0–0.4.0 × library 0.4.0) is
  incompatible with itself as released; the project intentionally uses
  hand-rolled `libwayland-client` P/Invoke instead. Re-evaluate if
  upstream ships a compatible toolchain.

---

## TL;DR

Code is in place for bar-side read (Phase 3), riverctl/foreign-toplevel
writes (Phase 4 + 4b), and a read-only River WM skeleton (Phase B1a).
**The blocking next step is live validation under a real River session.**
Only after that should effort move to turning the WM skeleton into a usable
daily-driver (B1b–g), emitting River config (Phase 6), swapping the
greeter/packaging (Phase 7), deleting Wayfire (Phase 8), and cutting a
release (Phase 9).
