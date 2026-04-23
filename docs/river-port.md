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

### Still outstanding in Phase 4b (next iteration, needs a live River session)

- Per-view write requests — `activate(wl_seat)`, `close()`, `set_minimized()` / `unset_minimized()`, `set_fullscreen()` — the interface tables already describe them; wiring is a short follow-up once the read path is validated end-to-end.
- Route `RiverBackend.FocusView(id)` / `CloseView(id)` / `MinimizeView(id, bool)` through the toplevel handle by id (instead of the current `riverctl` fallbacks) when `ForeignToplevel` cap is present.
- Populate `FocusedViewInfo.AppId` from the `Activated`-flagged toplevel.
- Validation under a nested River (`river` is installed on this machine; `riverctl` is NOT packaged — install `river-git`/AUR equivalent or use the wlr client exclusively).

## Still to do

- **Phase 6** — `RiverConfigService` emitting idempotent `~/.config/river/init`.
- **Phase 7** — Greeter & packaging swap.
- **Phase 8** — Delete Wayfire backend + `wayfire.ini` + old IPC files.
- **Phase 9** — Live-session smoke matrix, AOT publish regression, release tag `vX.0.0-river`.
