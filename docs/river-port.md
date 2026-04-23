# Aqueous → River Port

Tracking doc for the in-progress compositor port.

## Completed phases

- **Phase 0** — `AstalRiver` project reference wired into `Aqueous.csproj`.
- **Phase 1** — `aqueous-corners` plugin and all corner IPC / Settings / `wayfire.ini` references deleted.
- **Phase 2** — `ICompositorBackend` + static `CompositorBackend` locator; `WayfireBackend` adapter; all feature-code callers migrated.
- **Phase 3** — Event-driven River read side (see below).
- **Phase 5** — SnapTo capability-gated (tag-preset tile path on River, geometry path unchanged on Wayfire).

## Phase 3 — Event-driven River read side

### What landed

- `ICompositorBackend` grew typed read accessors (`Outputs`, `FocusedOutput`, `FocusedViewInfo`, `FocusedTagMask`, `OccupiedTagMask`, `UrgentTagMask`, `LowestFocusedTagIndex`) plus an `OutputsChanged` event.
- GObject signal P/Invoke shims (`g_signal_connect_data`, `g_signal_handler_disconnect`, `g_object_ref`/`unref`) added to `AstalRiverInterop`.
- `AstalRiverRiver` / `AstalRiverOutput` expose `NativePtr` + `ConnectNotify(...)` + `Disconnect(...)`.
- New `RiverStateAggregator` owns the `AstalRiver` handle, subscribes to `notify::focused-output`, `notify::focused-view`, `notify::mode` at the river level and `notify::{focused,occupied,urgent}-tags`, `notify::layout`, `notify::focused` per output, and emits a diffed `RiverSnapshot` stream.
- `RiverBackend` rewritten around the aggregator — polling loop gone; `ViewsChanged` / `WorkspaceChanged` / `OutputsChanged` fire on real compositor events; write methods still throw `NotSupportedException` pending Phase 4.
- `Program.cs` auto-selects `RiverBackend` when `AstalRiverRiver.GetDefault()` returns non-null, falls back to `WayfireBackend`. `AQUEOUS_BACKEND=river|wayfire` env var forces a choice.
- `WorkspaceSwitcherWidget` now reads `FocusedTagMask` directly and reacts to backend `WorkspaceChanged` / `OutputsChanged`.

### Validation matrix (execute on a live River session)

| Scenario | Expected |
|---|---|
| Switch tag with `Super+N` | Workspace switcher highlights the new tag within one frame |
| Focus a different output | `OutputsChanged` fires; focused output is reflected |
| Hotplug an output (disconnect/reconnect) | `OutputsChanged` fires both times; aggregator rewires per-output subs |
| Change focused view (click another window) | `ViewsChanged` fires once; title reflected in focused view info |
| Toggle urgent flag on a non-focused tag | `WorkspaceChanged` fires; urgent mask updated |
| Change River `mode` (`riverctl enter-mode …`) | Snapshot `Mode` updates (no widget consumers yet — plumbing only) |
| Run with `AQUEOUS_BACKEND=wayfire` inside River | Falls back to Wayfire backend (will not talk to compositor; expected on a Wayfire session) |
| Shut down Aqueous | No GLib assertion / double-free; signal handlers disconnect cleanly |

### Known limits (by design for Phase 3)

- No view enumeration — AstalRiver is status-only; deferred to Phase 4 via `wlr-foreign-toplevel-management-v1`.
- No cursor query — River has no cursor IPC; `GetCursorPosition()` returns `null`.
- `FocusedViewInfo.AppId` is `null` on River — only `wlr-foreign-toplevel` exposes app-ids; Phase 4.
- Write methods (`FocusView`, `CloseView`, `MinimizeView`, `SetViewGeometry`, `SetWorkspace`) still throw; Phase 4.

## Phase 4 — Write side (riverctl + wlr-foreign-toplevel scaffold)

### What landed

- `RiverBackend` write methods now shell out to `riverctl`: `SetFocusedTagMask` (`set-focused-tags <mask>`), `ToggleFloatingFocusedView` (`toggle-float`), `FocusView` (`focus-view next`), `CloseView` (`close`), `SetWorkspace(x,y)` (`set-focused-tags` on the 3×3 grid). `MinimizeView` / `SetViewGeometry` are documented no-ops (River has no such concepts).
- `Capabilities` now advertises `TagMaskSwitch | ToggleFloat` whenever `riverctl` is on PATH, and additionally `ForeignToplevel` when the optional wlr client (below) is connected.
- **Phase 4b scaffold** — hand-rolled `zwlr_foreign_toplevel_management_v1` client landed, gated behind env var `AQUEOUS_FOREIGN_TOPLEVEL=1`:
  - `WaylandInterop.cs` — minimal `libwayland-client.so.0` P/Invoke surface (`wl_display_*`, `wl_proxy_marshal_flags`, `wl_proxy_add_dispatcher`) plus the `wl_interface` / `wl_message` ABI structs.
  - `WlInterfaces.cs` — builds the unmanaged interface tables for `wl_registry`, `wl_seat`, `wl_surface`, `wl_output`, `zwlr_foreign_toplevel_manager_v1` (v3), and `zwlr_foreign_toplevel_handle_v1` (v3). All messages declared so requests can be issued later.
  - `ForeignToplevelClient.cs` — owns a dedicated `wl_display_connect()` separate from GDK's, runs `wl_display_dispatch()` on its own worker thread, demuxes events via a single `[UnmanagedCallersOnly]` dispatcher, and exposes an immutable `Toplevels` snapshot of (`Id`, `Title`, `AppId`, `Activated`, `Maximized`, `Minimized`, `Fullscreen`) plus a `Changed` event fired on every `done` / `closed`.
  - `RiverBackend.ListViews()` returns the toplevel list when the client is connected; empty otherwise. `ViewsChanged` is now also raised from foreign-toplevel events.
- AOT publish (`dotnet publish Aqueous -c Release -r linux-x64 /p:PublishAot=true`) succeeds with zero warnings from the new files.

### Phase 4b write-side wiring (landed)

- `ForeignToplevelClient` now exposes `Activate(id)` / `Close(id)` / `SetMinimized(id, bool)` which marshal `zwlr_foreign_toplevel_handle_v1.activate(wl_seat)` (opcode 4), `close` (5), and `(set|unset)_minimized` (2 / 3) against the tracked handle, followed by a `wl_display_flush`.
- `RiverBackend.FocusView` / `CloseView` / `MinimizeView` route through the toplevel client when `IsConnected`, falling back to the `riverctl` paths for `FocusView` / `CloseView` on older/non-foreign-toplevel setups. `MinimizeView` is still a no-op when the wlr client is absent (River itself has no minimized state).
- `FocusedViewInfo.AppId` is now populated from the `Activated`-flagged toplevel via `ForeignToplevelClient.FocusedAppId`.
- Fixed a latent bug: handle destructor on `closed` was using request opcode 5 (`close`); corrected to 7 (`destroy`).

### Still outstanding in Phase 4b

- `set_fullscreen` / `unset_fullscreen` (v2+) and `set_rectangle` — interface tables already describe them; no consumer in Aqueous yet.
- Validation under a nested River (`river` is installed on this machine; `riverctl` is NOT packaged — install `river-git`/AUR equivalent or use the wlr client exclusively). Expected smoke test: `AQUEOUS_FOREIGN_TOPLEVEL=1 aqueous`, then from another toplevel, confirm `ListViews` enumerates, `FocusView(id)` raises the window, `CloseView(id)` closes it, `MinimizeView(id, true)` hides it under compositors that honour the bit.

## Phase B1a — River WM skeleton (river_window_manager_v1 v4)

River 0.4 removed `zriver_control_v1` (and therefore `riverctl`), and instead
delegates **all** window-management policy to a single client that binds the
new `river_window_manager_v1` global. Option 2 (speak `zriver_control_v1` from
the bar) is not viable on River 0.4 — the global is simply not advertised.

### What landed

- `Protocols/river-window-management-v1.xml` — vendored from
  `/usr/share/river-protocols/stable/river-window-management-v1.xml` (v4, the
  currently installed `river 0.4.3` protocol definition).
- `WlInterfaces.cs` — extended with the full v4 interface tables for
  `river_window_manager_v1`, `river_window_v1`, `river_decoration_v1`,
  `river_shell_surface_v1`, `river_node_v1`, `river_output_v1`,
  `river_seat_v1`, `river_pointer_binding_v1`. Every request/event is declared
  with its exact signature string and nested-interface pointer array so
  libwayland-client can marshal the wire format.
- `RiverWindowManagerClient.cs` — mirrors the `ForeignToplevelClient` shape:
  dedicated `wl_display_connect()` + worker thread, single
  `[UnmanagedCallersOnly]` dispatcher demuxing events by proxy identity,
  tracks `river_window_v1` / `river_output_v1` / `river_seat_v1` proxies in
  concurrent dictionaries and logs every event that lands.
- **Auto-ack** — immediately sends `manage_finish` after every
  `manage_start` and `render_finish` after every `render_start`, with no
  intervening state changes. This is the minimum traffic required to keep
  River's manage/render loop progressing and avoid the `unresponsive`
  watchdog; it does **not** constitute real window management.
- `RiverBackend.cs` — starts the client in its constructor via
  `RiverWindowManagerClient.TryStart()` and disposes it on shutdown. The
  entire path is gated on `AQUEOUS_RIVER_WM=1`; in the default bar build the
  WM client is inert.
- AOT publish (`dotnet publish Aqueous -c Release -r linux-x64 /p:PublishAot=true`)
  succeeds with zero warnings from `RiverWindowManagerClient` / `WlInterfaces`.

### Scope and caveats

- **Not a usable window manager.** No layout, no focus policy, no keybindings,
  no decoration placement. Windows appear at whatever default dimensions
  River chooses. Aqueous must be run *alongside* an actual WM in practice —
  but note River allows only one WM client at a time, so enabling
  `AQUEOUS_RIVER_WM=1` makes Aqueous the WM and nothing else can bind it.
- **Protocol errors will crash the live compositor.** A single wrong opcode
  or signature byte will trip `sequence_order` / `role` / `unresponsive` and
  take the whole session down. The interface tables were extracted
  mechanically from the installed XML (`/tmp/extract_sigs.py` helper) to
  minimise hand-edit mistakes, but this code has not yet been run against a
  live River session.
- All proxies are indexed by their raw `IntPtr`; the current skeleton never
  sends destroys, so a long-running session would accumulate entries. Fine
  for first-boot validation; needs a `destroy`-on-`closed`/`removed` pass
  before long-term use.

### Validation matrix (execute inside a nested River; expect iteration)

| Scenario | Expected log output |
|---|---|
| Launch Aqueous with `AQUEOUS_RIVER_WM=1` inside River | `[river-wm] attached as window manager (v4)` |
| Spawn a terminal | `+ window 0x…`, then `manage_start` / `manage_finish` round-trip, then `window … app_id=foot`, `window … title=…` |
| Resize the terminal | repeated `render_start` ↔ `render_finish` with `window … dimensions WxH` between them |
| Close the terminal | `window … closed` |
| Plug a second monitor | `+ output 0x…` followed by `output … wl_output_name=N`, `output … position=X,Y`, `output … dimensions=WxH` |
| Kill Aqueous (`SIGTERM`) | River reverts to headless / next WM client |
| Any compositor-side crash | **Stop here and iterate on signatures.** The most likely culprit is a mis-declared message in `BuildRiverWindowManagement()`. |

### Follow-up phases (B1b+)

- Stop logging every event, replace with a proper domain model.
- Send `propose_dimensions` / `set_borders` / `show` during `manage_start` to
  produce a real (if trivial) layout — e.g. stack all windows at the origin.
- Bind `river_input_manager_v1` + `river_xkb_bindings_v1` to register
  keybindings (otherwise River has no bindings at all in this mode).
- Integrate with the existing Aqueous bar's `RiverStateAggregator` so tag/
  workspace widgets continue to work in WM mode.
- Ship a systemd user-unit / River `init` script that launches Aqueous with
  `AQUEOUS_RIVER_WM=1` and a fallback WM in case we crash.

## Still to do

- **Phase 6** — `RiverConfigService` emitting idempotent `~/.config/river/init`.
- **Phase 7** — Greeter & packaging swap.
- **Phase 8** — Delete Wayfire backend + `wayfire.ini` + old IPC files.
- **Phase 9** — Live-session smoke matrix, AOT publish regression, release tag `vX.0.0-river`.
