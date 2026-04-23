# Aqueous → River Port

Tracking doc for the in-progress compositor port.

## Completed phases

- **Phase 0** — `AstalRiver` project reference wired into `Aqueous.csproj`.
- **Phase 1** — `aqueous-corners` plugin and all corner IPC / Settings / `wayfire.ini` references deleted.
- **Phase 2** — `ICompositorBackend` + static `CompositorBackend` locator; `WayfireBackend` adapter; all feature-code callers migrated.
- **Phase 3** — Event-driven River read side (see below).

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

## Still to do

- **Phase 4** — `RiverCtl` subprocess wrapper + `ForeignToplevelClient` (wlr-foreign-toplevel-management-v1 under AOT) wiring all write methods.
- **Phase 5** — SnapTo reduced to tag presets + floating-only geometry.
- **Phase 6** — `RiverConfigService` emitting idempotent `~/.config/river/init`.
- **Phase 7** — Greeter & packaging swap.
- **Phase 8** — Delete Wayfire backend + `wayfire.ini` + old IPC files.
- **Phase 9** — Live-session smoke matrix, AOT publish regression, release tag `vX.0.0-river`.
