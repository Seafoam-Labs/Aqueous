# Aqueous compositor interactions

This document describes how the current single-process Aqueous compositor
turns Wayland, input, configuration, and output events into visible window
state. It is an implementation guide rather than a protocol specification.
The most relevant code lives in `compositor/aqueous/` and its `wm/`
subdirectory.

## The central model

Aqueous has two cooperating layers in one process:

- The compositor layer owns Wayland objects, wlroots objects, outputs, seats,
  workspaces, client configure state, and the scene graph.
- The policy layer decides workspace membership, focus, layout, geometry,
  visibility, border state, and user-action results.

`CompositorApi.zig` is the narrow native boundary between them. The policy
receives stable handles and copied snapshots instead of retaining arbitrary
wlroots pointers. It resolves a handle only while applying a decision.

```text
Wayland/libinput event
        |
        v
 Server, Window, Output, Seat, LayerShell
        |
        | dirtyWindowing()
        v
 WindowManager transaction coordinator
        |
        | policySnapshot()
        v
 Aqueous policy: rules -> state -> layout -> focus
        |
        | CompositorApi requests
        v
 Window/Seat/Output scheduled state
        |
        v
 configure clients -> wait for commits -> update scene -> render
```

The policy does not draw a window directly. It schedules the state that the
transaction coordinator will configure and render.

## Component responsibilities

| Component | Responsibility |
| --- | --- |
| `main.zig` | Parses flags, creates the server, starts the backend, exports `WAYLAND_DISPLAY`, starts native policy, runs the session init command, and enters the Wayland event loop. |
| `Server.zig` | Owns wlroots globals and all major managers; creates XDG and XWayland windows and exposes screencopy and foreign-toplevel protocols. |
| `WindowManager.zig` | Coalesces dirty events and runs the manage/configure/render transaction state machine. |
| `Window.zig` | Owns a native or XWayland window, its lifecycle, workspace, requested configuration, rendering state, and embedded policy metadata. |
| `WindowInfoManager.zig` | Extends standard foreign-toplevel handles with one-shot, read-only backend, workspace, geometry, state, and matched-rule snapshots. |
| `Aqueous.zig` | Implements rules, layouts, focus, workspace actions, window state actions, bindings, startup commands, and reload behavior. |
| `CompositorApi.zig` | Builds policy snapshots and translates policy decisions back into compositor operations. |
| `Output.zig` / `Workspace.zig` | Own output geometry, nine per-output workspaces, active workspace state, and workspace transitions. |
| `Seat.zig` / `KeyboardGroup.zig` / `Cursor.zig` | Queue input, resolve bindings, schedule focus, deliver unconsumed events to clients, and manage pointer interactions. |
| `LayerShellOutput.zig` | Arranges panels and docks and calculates the output area left after exclusive zones. |
| `wm/layout/engine.zig` | Dispatches standalone and composable layouts and retains per-output, per-workspace layout state. |
| `wm/rules/engine.zig` | Resolves the first matching app ID, class, and title rule. |
| `wm/output/Service.zig` | Loads native output policy, applies it through `OutputManager`, and hosts the compatibility JSON socket. |

## Startup and session flow

1. `main.zig` selects internal policy by default and calls `Server.init()`.
2. `Server.init()` creates wlroots globals, the renderer, scene, output and
   input managers, `WindowManager`, and the Aqueous policy object.
3. `Aqueous.init()` loads configuration, loads discovered rules, initializes
   focus/layout state, and arms a one-second event-loop reload timer.
4. The Wayland socket and backend are started. `WAYLAND_DISPLAY` and, when
   enabled, `DISPLAY` are exported before policy-started children are created.
5. `Aqueous.start()` starts the embedded output service, applies input policy,
   and runs matching `[[exec]]` startup entries.
6. The session init command is launched in its own process group. Packaged and
   nested sessions use this part of the startup chain to bring up desktop
   services such as Noctalia.
7. The Wayland event loop begins. From this point, state changes are driven by
   listeners and event-loop callbacks rather than a polling window-manager
   process.

`[[exec]]` entries run through `/bin/sh -c`. `once`, `when`, `restart`, `env`,
and `log` affect whether and how a child is launched. Restarting commands use
bounded backoff in a shell loop. The compositor itself does not synchronously
wait for these children.

## Window inspection protocols

Mapped windows are published through both `ext_foreign_toplevel_list_v1` and
the legacy `zwlr_foreign_toplevel_manager_v1`. Publication is owned by the
window map/unmap lifecycle and does not depend on an external policy client.
This keeps `wlrctl toplevel list`, taskbars, and modern foreign-toplevel clients
working while integrated policy is active.

`aqueous_window_info_v1` is a read-only extension of an
`ext_foreign_toplevel_handle_v1`. A request returns a one-shot snapshot of the
window backend, native app ID or XWayland class, output, workspace, geometry,
placement state, and matched rule. Enumeration and stable identifiers stay in
the standard ext protocol. `aqueousctl` combines the two protocols for table,
JSON, and ready-to-paste rule output. All three foreign-window globals are
hidden from Wayland security contexts.

`aqueousctl outputs` separately reads the standard `wl_output` globals and
prints every advertised physical resolution and refresh rate, marking current
and preferred modes without entering the output-management transaction path.

## The transaction cycle

Most interactions converge on `WindowManager.dirtyWindowing()`. It marks the
state dirty and installs one idle callback, so a burst of events becomes one
transaction. The state machine is:

```text
idle
  -> manage
  -> inflight_configures (zero or more client configures)
  -> render
  -> idle
```

### 1. Manage start

`WindowManager.manageStart()` performs output autolayout, lets outputs,
windows, and seats publish scheduled changes, and then invokes
`Aqueous.applyManageCycle()` in internal mode.

The policy builds one copied snapshot containing every usable output and its
active windows. An unassigned new window is admitted on the first usable
output; this breaks the otherwise circular dependency where it cannot map
until configured but historically was not assigned until mapping.

For each output, the policy:

1. Resolves global, output, workspace, and runtime layout selection.
2. Intersects live layer-shell reservations with configured static struts.
3. Ensures newly admitted windows have a workspace.
4. Resolves and reconciles each window rule.
5. Separates minimized, maximized, floating, fullscreen, and tiled windows.
6. Updates focus history and chooses a replacement focus when necessary.
7. Runs the selected layout engine for tiled windows.
8. Merges special and tiled placements, sorts them by z-order, and applies
   their geometry, visibility, border, blur, and opacity requests.

### 2. Manage finish and client configuration

`Seat.manageFinish()` commits scheduled keyboard focus before window
configuration. In internal mode this ordering is essential: the scheduled
focus reaches `wl_seat` and the client receives keyboard enter before the
transaction moves into its configure-wait phase.

`Window.manageFinish()` converts requested dimensions and state into XDG or
XWayland configure operations. A window that has not received an initial size
does not map prematurely. Foreign-toplevel state is also updated here so docks
and taskbars see activation, minimized, maximized, and fullscreen changes.

If client size changes are outstanding, Aqueous saves the current surfaces and
waits for the configure response. XDG configure acknowledgements and commits
advance the tracked configure state. The transaction has a short timeout so a
misbehaving client cannot freeze every other window; timing out can produce an
imperfect frame but lets the compositor continue.

### 3. Render commit

`Window.renderStart()` chooses dimensions from buffers actually committed by
the client. This matters especially for asynchronous X11/Electron clients,
whose configured size may lead their current buffer size.

`WindowManager.renderFinish()` then applies the transaction to the scene:

- Window positions, clipping, borders, visibility, opacity, and blur become
  current.
- Fullscreen windows move to the fullscreen scene layer; normal windows move
  to the window-manager layer.
- Workspace membership determines whether a window tree is enabled.
- Incoming and outgoing workspaces can both remain enabled during a slide.
- Saved buffers are dropped only after the replacement scene is ready.
- Output state is committed atomically through `OutputManager` when required.

If another event dirtied state while the transaction was in progress, the
idle callback starts the next cycle after the current cycle returns to idle.

## Example: opening a terminal

Assume output `DP-1`, workspace 2, a top Noctalia bar with an exclusive zone,
and the `tile` layout.

1. The terminal creates an `xdg_toplevel`. `Server.handleNewXdgToplevel()`
   creates a `Window`, scene trees, and protocol listeners.
2. On its initial surface commit the window enters `ready` state and dirties
   window management.
3. The next policy snapshot admits the unassigned window on `DP-1` and
   `ensureWorkspace()` assigns it to workspace 2.
4. The layer-shell code has already reduced `DP-1`'s usable rectangle. If the
   full output is `(0,0 2560x1440)` and the bar reserves 40 pixels at the top,
   policy sees approximately `(0,40 2560x1400)` before static struts and gaps.
5. Rules are matched against the copied app ID and title. With no special
   rule, the window joins the tiled set.
6. The tile engine computes a placement inside the usable rectangle. The
   policy requests focus and applies the placement to the native `Window`.
7. Manage finish sends the terminal its initial configured size. After the
   terminal acknowledges and commits a buffer, render finish enables its scene
   tree at the final position.
8. The seat sends keyboard enter, and unbound keyboard input now goes directly
   to the terminal.

Opening a second terminal repeats the cycle, but the layout's stored order now
contains both stable handles. Both windows receive new sizes in the same
transaction, avoiding a frame where one uses old geometry.

## Window identity and state ownership

Every `Window` receives a slot-map `Ref`. Its bit representation is the stable
policy handle. Destroying the slot invalidates stale handles, so policy calls
resolve the handle before touching a window.

State is deliberately divided by ownership:

- `Window.workspace`, fullscreen requests, requested dimensions, and scene
  state are compositor-owned truth.
- `Window.policy_state` stores policy metadata with exactly the same lifetime
  as the window: tiled/floating/maximized/minimized kind, remembered floating
  geometry, client-maximize origin, and rule ownership/override flags.
- `StateStore` does not duplicate per-window state. It resolves embedded
  `policy_state` and only retains the cross-window minimized MRU list needed by
  `unminimize_last`.
- Layout order and viewport state are keyed by output handle plus workspace
  number. They persist across arrange calls but are removed when an output
  disappears.
- Focus history is also workspace-specific; pending focus prevents the policy
  from repeatedly requesting the same not-yet-committed target.

When a window closes, `Aqueous.forgetWindow()` removes it from cross-window
indexes and cancels any pending focus or drag that references it before its
stable handle is invalidated.

## Active-workspace overview

`Super+W` opens a compositor-owned overview for the active workspace on the
focused output. Policy filters the output snapshot, preserves its window order,
arranges aspect-fitted cards in the usable output rectangle, and retains only
stable handles and value rectangles. It does not change layout, workspace
membership, client dimensions, or keyboard focus while the overview is open.

The compositor temporarily removes viewport/content clips, clones each
window's complete committed buffer tree, and immediately restores the live
clips. These frozen buffers live under a topmost, output-local scene tree with
a dim input-blocking backdrop. Thumbnail nodes have no `SceneNodeData`, so
normal client hit-testing cannot mistake them for live surfaces. Entry zoom and
backdrop fade run from the output frame loop; builds with
`-Danimations=false` place the same cards immediately.

Once capture succeeds, the compositor suppresses the live window trees and
non-background layer surfaces belonging to the overview's output. The
wallpaper remains beneath the frozen cards, and content on other outputs stays
enabled. Teardown restores every affected scene node to its exact prior state.

While active, input is modal:

- Arrow keys and H/J/K/L choose a spatial neighbor; Tab and Shift+Tab wrap in
  snapshot order.
- Enter or Space confirms, while Escape or `Super+W` cancels.
- Pointer motion hit-tests policy card rectangles and left-click confirms the
  hovered card. Other pointer buttons and unrelated non-modifier keys are
  consumed.

Cancellation destroys the visual, restores pointer constraints and pointer
focus, and leaves keyboard focus unchanged. Confirmation first performs the
same cleanup, then validates the selected handle and focuses it through the
ordinary policy path. This is what reveals an off-screen scrolling window and
keeps normal raise order and focus history intact.

Membership stays frozen until exit. A window close removes one card and chooses
the nearest replacement; a new window, workspace change, output
reconfiguration/removal, configuration reload, or session lock cancels the
overview. Compositor shutdown destroys overview clones before the scene root.

## Rules and manual overrides

Rules use first-match-wins semantics. Every matcher present in one rule must
match. App ID/title updates dirty the manage cycle, so a window can transition
to a different semantic rule after it is created.

Stateful rule properties use ownership rather than being blindly enforced on
every cycle:

- A rule may own workspace, fullscreen, or floating state that it applied.
- A user workspace move, fullscreen toggle, or floating toggle releases only
  that property's rule ownership and records a manual override.
- Re-evaluating the same matcher preserves the manual override.
- Changing to a different matcher rolls back properties still owned by the
  old match, begins a new rule lifecycle, and applies the new rule.
- Editing placement values within the same matcher can update a still-owned
  property without discarding unrelated user overrides.
- Blur and opacity are visual properties and are recalculated each cycle.

Example: a video rule assigns workspace 4 and fullscreen. The first manage
cycle moves and fullscreenes the window. If the user then moves it to workspace
6, subsequent cycles leave it on 6. If its identity later changes so another
rule matches, the new match gets a fresh ownership lifecycle.

Only one fullscreen owner is retained per output. Requesting fullscreen clears
the other fullscreen window and marks that other window's rule property as
overridden where necessary.

## Layout and placement flow

Layout resolution is scoped to an output/workspace pair. Runtime selection has
the highest priority, followed by configured workspace/output selection and
the global default. A matching rule can select the active layout for its
output during the current manage pass.

The dispatcher supports `tile`, `monocle`, `grid`, `rows`, `dwindle`,
`reverse_dwindle`, `scrolling`, `floating`, `game_mode`, and `composable`. Each engine receives:

- The final usable rectangle.
- Only windows participating in that layout.
- Stable window handles and size constraints.
- The focused handle and layout-specific options where relevant.

It returns placements rather than mutating compositor objects. Special states
are overlaid around this result:

- Minimized windows receive an invisible placement.
- Maximized windows use either the usable area or the full output according to
  configuration.
- Floating windows use remembered geometry or a generated placement.
- Fullscreen windows use the full output, have no border, and sort above other
  placements.
- Tiled windows use the selected layout and usable area.

This separation lets all layout algorithms remain testable without wlroots.

Composable mode is a dispatcher over as many as four leaf dispatcher states.
Its TOML configuration resolves normalized four-point rectangles against the
usable output, partitions windows by persistent region membership, and merges
the child placement lists. Keyboard focus on any member marks that member's
region active; newly managed windows enter the active region. Operations such
as scrolling, resizing, floating drag, and pointer reorder are routed by the
window's child membership rather than by the workspace's top-level layout ID.

### Example: rearranging tiled windows with the pointer

1. Super+left-click hit-tests the scene and finds the window handle.
2. For a tiled window in a tiling layout, the drag action is `swap_tiled`; the
   window is not converted to floating.
3. Pointer motion hit-tests the window under the cursor. In the scrolling
   layout, its top/bottom thirds are stack insertion zones and its middle-left
   and middle-right are adjacent-column zones. Other layouts retain pairwise
   swapping.
4. A manage cycle recalculates geometry. A guard waits until scene hit-testing
   reflects the new arrangement before another swap can occur, preventing the
   old scene geometry from immediately swapping the pair back.
5. Releasing the button ends the drag. The scrolling column-major projection is
   copied into initialized dormant layout orders, so the order survives layout
   switches.

Super+right-drag on an ordinary tiled window promotes it to floating and
updates remembered floating geometry. In a scrolling layout it instead keeps
the member tiled: horizontal motion resizes the whole column and vertical
motion resizes that member. Game mode delegates this operation to an active
scrolling remainder or fallback and rejects its anchor. Every pointer update
requests a manage cycle.

A `Super`+double-left-click with no drag restores a scrolling member's standard
size: the configured width for its column and full viewport height for that
member. The click tracker uses release timestamps and a small motion tolerance,
so tiled reorder drags never trigger the reset.

Validated client move and resize requests enter the same integrated-policy
interaction path when the target is a persistent floating overlay or an
ordinary window presented by the workspace floating layout. Native clients are
validated with the `xdg_toplevel` seat and serial. XWayland
`_NET_WM_MOVERESIZE` requests have neither, so Aqueous accepts them only while
the default pointer has an active press focused on the requesting top-level.
Resize requests preserve the client-selected edge or corner. Requests from
ordinary windows in non-floating layouts, maximized windows, or minimized
windows are consumed without changing their geometry or removing them from
layout. Client maximize and minimize requests follow the same presentation
rule. Maximize records whether the window came from a persistent overlay or the
workspace floating layout, so unmaximize restores floating or tiled policy
ownership respectively and the appropriate remembered rectangle is reused.

## Focus, keyboard, and pointer flow

Physical input is queued on a `Seat` so input processing does not interleave
partway through a management transaction.

For a key press:

1. `Keyboard` updates pressed-key state and passes the event to
   `KeyboardGroup`.
2. Built-in compositor handling and the internal Aqueous binding table get the
   first opportunity to consume it.
3. A consumed policy press records its consumer, so the corresponding release
   follows the same path even if modifiers have changed.
4. Otherwise legacy protocol bindings, input-method grabs, or the focused
   client receive the event.
5. A binding action changes policy state and dirties the manage cycle; the
   action does not synchronously redraw windows.

Focus requests are scheduled on `Seat`, then committed in manage finish. Focus
also updates the independently stored selected output. This distinction lets
the user navigate to an empty output: Aqueous selects the output, clears
surface focus, and still knows where the next workspace or window action
belongs.

Output focus selection prefers, in order, explicit seat selection, the output
of the focused window, configured primary output, the output under the cursor,
and finally the first usable output. Left/right output navigation uses physical
output rectangles rather than iterator order.

Pointer motion updates hover state and can request focus when
`focus_follows_mouse` is enabled. Normal clicks are delivered through scene
hit-testing. Modifier drags are intercepted before client delivery. Holding
the configured pointer-untrap binding temporarily suppresses pointer
constraints and restores them on key release.

New windows preserve the current keyboard target by default. Enabling
`focus_new_windows` makes the integrated policy focus the newest admitted
focusable window after its workspace rules are resolved. Windows routed to an
inactive workspace and X11 surfaces which reject keyboard focus do not steal
focus; admission waits while a layer-shell or other non-window surface owns
the keyboard.

## Workspaces

Each output creates nine pinned workspaces and has exactly one active
workspace. A window belongs to at most one workspace; unassigned windows are a
temporary pre-initial-configure state.

Changing workspaces records the prior number per output, activates the target,
dirties policy, and schedules an output frame. The next manage cycle arranges
windows on the newly active workspace and repairs focus using workspace focus
history. Moving a window first marks workspace-rule ownership overridden, then
changes its native workspace membership.

When transitions are enabled, the output retains the outgoing workspace while
the incoming workspace becomes active. Render finish enables both sets of
windows and the animation code moves their inert surface clones. The outgoing
workspace is released after the transition settles.

Example: Super+2 on `DP-1` records workspace 1 as previous, activates workspace
2, restores the last valid focus on workspace 2, and slides workspace 2 in. A
previous-workspace action can then return to workspace 1 without consulting a
global workspace stack.

## Layer shell and Noctalia

Noctalia panels are layer-shell surfaces, not managed application windows.
When a panel maps, unmaps, commits a new exclusive zone, or changes layer,
`LayerShellOutput.arrange()` configures layer surfaces and recalculates
`non_exclusive_area`. If that rectangle changes, window management is dirtied.

The policy snapshot exposes both:

- `area`: the complete output rectangle, used for fullscreen and
  `ignore_struts` placement.
- `usable_area`: the rectangle remaining after live layer-shell exclusive
  zones.

`Aqueous.applyManageCycle()` intersects `usable_area` with configured static
struts. Normal tiled, floating, and maximized geometry uses the result, so a
top bar is not covered. True fullscreen intentionally uses the full output.

Layer-shell keyboard focus has priority where the protocol requests exclusive
focus. On-demand layer focus can temporarily receive input until policy
requests focus elsewhere.

## Outputs and hotplug

The embedded output service reads physical display configuration from
`outputs.toml` first and uses `wm.toml` for settings that are not present there.
An `outputs.toml` containing profiles only retains the legacy `wm.toml`-first
behavior, so existing persisted profiles do not silently migrate a setup.
After optionally resolving profiles, the service converts matching specs into
`Output.State`. `OutputManager.applySpecs()` stages the changes; the normal
transaction performs output layout updates and an atomic backend commit.

On success, output geometry, mode, scale, transform, adaptive sync, HDR, and
enabled state become current together. On failure, Aqueous reverts scheduled
state to the last working state. An initial modeset failure terminates the
session instead of running indefinitely without a usable display.

`hdr = true` selects the HDR10 profile on a capable DRM output: 10-bit
scanout, BT.2020 primaries, and the ST 2084 PQ transfer function with static
mastering metadata. The request is rejected unless the connector advertises
BT.2020 and PQ, the renderer can perform output color transforms, and the
primary scanout path supports a 10-bit format. Disabling HDR restores the
normal 8-bit sRGB output profile. Per-surface mastering metadata, HLG,
display-specific tone mapping, and ICC calibration are outside this profile.

`hdr_level` picks the peak-luminance preset used for the mastering metadata
(100, 400, or 1000 cd/m²; default 1000), so the static InfoFrame matches the
connected display. `hdr_level = "auto"` resolves the preset nearest the
EDID CTA-861 desired-content peak luminance when the connector advertises
one, falling back to 1000 otherwise. `sdr_white_level` (80–1000 cd/m²,
default 200) places SDR diffuse white on the HDR output; the patched wlroots
scene scales relative-luminance content to that level while absolute PQ
content keeps its mastering luminances. Level and white-level changes ride
the same atomic modeset as enabling HDR.

Hotplug creates or destroys native `Output` objects, reapplies configured
policy, updates the output protocol, and broadcasts compatibility events.
Output policy IDs are valid only for the life of their `Output`; stale
per-output layout state is pruned from policy snapshots.

Output positions retain their source: automatic fallback, TOML/persisted
configuration, or an output-management client. Unconfigured outputs are laid
out in a non-overlapping horizontal row. Some output-management clients submit
all newly advertised heads at `(0, 0)` before the user has arranged them; when
every enabled output is still automatic, Aqueous treats that first overlapping
transaction as uninitialized, retains its mode/scale changes, and recomputes
the positions. Once configuration or a valid client arrangement owns a
position, overlapping coordinates are preserved as intentional.

The configured `primary` flag is used only as a deterministic focus/action
fallback. It does not override an explicitly selected output or steal focus
from a window. If several usable outputs resolve primary, the first is used and
a warning is logged.

The Unix socket at `$XDG_RUNTIME_DIR/aqueous/outputd.sock` is hosted inside the
compositor. It preserves the display-panel JSON contract without a separate
`aqueous-outputd` process and accepts only same-UID peers.

The output-service `set` and `save_profile` operations accept an optional
boolean `hdr` field, an optional `hdr_level` field (100, 400, 1000, or
`"auto"`), and an optional numeric `sdr_white_level` field in cd/m². Listed
outputs report `hdr`, the resolved `hdr_level`, `sdr_white_level`,
`hdr_capable`, `hdr_active`, the EDID `hdr_edid_max_luminance` when known,
the current DRM `render_format`, and arrays of supported primaries and
transfer functions.

Output specifications are validated independently. A setting rejected for one
output (for example, an unavailable mode or a connector absent from the current
dock) is logged and reported without cancelling valid settings for other
outputs. `set`, `reload`, and `apply_profile` responses include `applied`,
`partial`, `rejected`, and a `rejections` array containing the spec index,
matcher, affected output when known, and rejection reason. `ok` remains true
for a partial application and is false when every requested output setting was
rejected. The accepted output states are still committed as one backend
transaction so the visible multi-output update remains atomic.

## Configuration reload

Every second, an event-loop timer fingerprints the resolved configuration,
rules, and output files. A change produces complete replacement snapshots,
then schedules a manage cycle. A manage pass therefore sees either the old
snapshot or the new snapshot, never a partially updated set of fields.

Reload can also be requested by a binding. A full reload:

1. Reloads `wm.toml` plus optional layout and input overlays.
2. Reloads discovered rules.
3. Marks global effects for reapplication.
4. Applies XKB/libinput changes.
5. Reloads and optionally applies output policy.
6. Runs matching reload commands and sends a notification.
7. Requests one manage cycle to reconcile every current window.

Rules have a separate reload action. A rules parse failure preserves the
previous rule snapshot, while no discovered rules file disables rules. Other
missing optional configuration uses parser defaults; none of these conditions
stops the compositor event loop.

## Closing and destruction

When an application unmaps, the window enters `closing` and management is
dirtied. Saved buffers may remain available through the transaction so the
last coherent frame can be displayed. The closing window is removed from
focus candidates, and the policy selects a replacement from workspace focus
history or layout order.

At render finish, closed window trees are hidden and destroying implementations
are freed. Slot-map removal invalidates the stable handle. Policy cleanup has
already removed minimized-MRU, pending-focus, and drag references, so later
actions safely ignore the stale handle.

## External compatibility mode

Normal builds run only the internal flow described above. With
`-Dexternal-policy=true`, the legacy `river_window_manager_v1` path can be
enabled for compatibility and trace comparison. In external mode,
`WindowManager` publishes compositor state over that protocol and waits for
the client to finish manage/render phases. It is not part of the shipped
single-process session and there is no bundled external policy client.

Trace snapshots hash window count, render order, geometry, workspace state,
and focus at manage and render boundaries. They are diagnostic summaries, not
another source of compositor state.

## Where to make changes

- Add or change an action in `wm/config/actions.zig` and dispatch it from
  `Aqueous.runBuiltin()`.
- Add policy-visible compositor data through `CompositorApi` instead of
  importing wlroots objects into layout or rule modules.
- Add per-window policy metadata to `Window.PolicyState` when its lifetime is
  exactly one window; use a global index only for relationships spanning
  windows.
- Keep layout code pure: consume rectangles/window snapshots and return
  placements.
- Route visible window changes through `dirtyWindowing()` and the transaction
  cycle. Direct scene mutation is reserved for compositor rendering code.
- Recalculate usable area through layer-shell arrangement when changing panel
  reservation behavior.
- Stage output changes through `OutputManager`; do not modeset an output from
  policy code.

Related references are [architecture.md](architecture.md),
[layout.md](layout.md), and [rules.md](rules.md).
