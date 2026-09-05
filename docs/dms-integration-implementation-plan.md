# Aqueous shell integration implementation plan

Status: Aqueous implementation delivered; DMS upstream consumers and hardware
release verification remain separate work. The phase descriptions below preserve
the original plan. See the implementation record at the end for actual scope.

Created 2026-09-05. Companion: [DMS upstream PR guide](dms-upstream-pr-guide.md).

## Outcome and baseline

Expose the compositor state and narrowly scoped operations needed for complete
DMS integration: workspace-aware taskbars, focused-monitor routing, keyboard
layout switching, graceful logout, active-window capture, overview control,
and coordinated configuration. Keep the interface usable by other shells.

The source audit covered this Aqueous checkout and the DMS checkout recorded in
[the plugin compatibility notes](../dms-plugin/README.md), upstream commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`, with shared QML commit
`26396ce432d6c71c3f5367438f96f4a8d667e160`. Selected upstream master files were
also inspected. This is a design baseline, not an end-to-end compatibility
certification or a claim that DMS 1.7 has been released. Pin and retest the
actual target revision before upstream integration and release.

Already available:

- Layer shell, session lock, idle notification/inhibition, clipboard control,
  screencopy, toplevel capture, gamma control, output management and output power.
- `ext-workspace-v1` enumeration, grouping by output, activation and lifecycle.
  DMS has a generic workspace-switcher path through `Quickshell.WindowManager`.
- wlr foreign-toplevel activation, close, minimize, maximize and fullscreen.
- Window metadata snapshots and cursor/layout control through
  [aqueous-window-info-v1](../compositor/protocol/aqueous-window-info-v1.xml)
  and [aqueousctl](../compositor/doc/aqueousctl.1.scd).
- Compositor-owned overview and window movement in
  [Aqueous.zig](../compositor/aqueous/wm/Aqueous.zig) and
  [CompositorApi.zig](../compositor/aqueous/wm/CompositorApi.zig).
- Configuration validation/persistence in `aqueous-config`, a DMS settings
  plugin, and an independent portal chooser plugin.

At that baseline, the missing integration was live policy metadata, shell access
to selected operations, shortcut inhibition, and upstream consumers. Do not duplicate
working standard protocols or make an external policy client the shell backend.

## Architecture decision

Add a separate versioned `aqueous-shell-v1` Wayland extension for live state and
shell commands. Reuse existing snapshot construction and policy functions
internally. Preserve the one-shot semantics and version compatibility of
`aqueous-window-info-v1` and existing `aqueousctl` commands.

Use `aqueousctl shell watch --json` as the initial DMS transport adapter: one
persistent Wayland client emitting newline-delimited JSON. Short-lived CLI
commands perform explicit mutations. A direct DMS Go binding can replace the
adapter later without changing the compositor contract. Confirm the transport
choice with upstream before implementing the DMS consumer; protocol/state work
does not depend on their choice.

No separate compositor Unix socket is required. Discover the extension on the
current Wayland connection; use the standard desktop variables and Wayland
socket owner for DMS naming. Export capabilities rather than inferring every
feature from the compositor name or executable version.

## A1 — Freeze identity, transaction and geometry contracts

Deliver a protocol design and JSON schema/examples before server implementation.

| Entity | Required contract |
| --- | --- |
| Session | Opaque compositor-instance ID; changes on restart. Protocol and JSON schema versions, supported capabilities. |
| Window | Existing ext-foreign-toplevel identifier, app ID/class, title, runtime workspace ID, output identity, geometry, policy flags and lifecycle. |
| Workspace | Opaque runtime ID, output association, display name, current number/coordinates, active and urgent states. |
| Output | Connector name, runtime identity, logical bounds and usable bounds; reuse wlr output management for modes, scale and configuration. |
| Seat | Name, selected output, focused window or null, keyboard focus kind, effective keyboard group and overview state. |

Runtime IDs must survive renumbering and output migration while their objects
remain alive. Never reuse an ID within a compositor instance; encode IDs as
strings in JSON to avoid JavaScript integer precision loss. Names and workspace
numbers are labels, not identity. Hotplug removal/recreation creates a new
runtime output identity even when a connector name is reused.

Keep the ext-workspace optional persistent ID absent until Aqueous has genuine
cross-session identity. Its present omission in
[WorkspaceManager.zig](../compositor/aqueous/WorkspaceManager.zig) is intentional.
Provide an explicit association to ext-workspace handles in the new Wayland
extension. The initial QML adapter must choose one authoritative workspace model
for enriched features; it must not join two asynchronous models by workspace
name or number. A direct Quickshell bridge is a separate option if needed.

Likewise, verify whether the supported Quickshell build exposes an identifier
that can join its actionable toplevels to Aqueous metadata. If it does not, use
the adapter's own window model and stable-ID CLI actions. Never join by title,
app ID, list position or assumed equivalence of ext and wlr protocol handles.

Define geometry in global logical compositor coordinates, with negative origins
allowed. Specify separate content and outer/decorated bounds when available,
and distinguish layout targets from current rendered bounds during animation.
Capture and dock overlap must use documented bounds; audit `window.box` before
reusing it. Specify scale, transform and clipping conversions in capture tests.
Document `visible` as compositor visibility, not proof that pixels are unoccluded.

Each connection receives an initial atomic snapshot followed by atomic batches
with monotonically increasing sequence numbers. Include explicit removals and
nulls for cleared properties. Publish after policy transactions settle, including
workspace reaping, so no batch exposes dangling associations. Reconnect discards
old state and obtains a fresh snapshot; define sequence-gap recovery as resync.

Acceptance: protocol examples cover empty desktop, two outputs with identically
named workspaces, migration, minimized windows, layer-shell focus and restart.

## A2 — Implement event-driven shell state

Add the protocol XML, generated binding inputs, `ShellManager.zig`, server
initialization and teardown. Hook invalidation into window map/unmap, title/app
identity, focus, state, workspace membership, geometry, output lifecycle,
workspace rename/reorder, keyboard state and overview transitions.

Primary touchpoints:

- `Server.zig`, `Window.zig`, `Workspace.zig`, `WorkspaceManager.zig`.
- `Seat.zig` (`selected_output`, focus transitions), `Output.zig`,
  `OutputManager.zig`, `wm/Aqueous.zig`, `wm/CompositorApi.zig`.
- `WindowInfoManager.zig` for shared snapshot construction, without changing
  existing request semantics.

Coalesce dirty entities at a transaction boundary. Do not scan all windows on
a periodic timer. Bound per-client queued data; disconnect an irrecoverably slow
consumer rather than allowing unlimited memory growth. A quiet desktop must
produce no repeating metadata traffic. Specify throttling for rendered geometry
during animation so shell observation does not cause unnecessary frame work.

Expose per-seat selected output independently of a focused window. Preserve the
selected output while a bar/popout has keyboard focus, and resolve removed
outputs through the compositor's existing fallback policy. Require explicit seat
selection on ambiguous multi-seat setups; define and report a default seat for
ordinary single-seat CLI use.

Acceptance: a headless client observes coherent initial/delta batches through
map, move, focus, minimize, rename, unmap and hotplug. Multiple subscribers see
the same committed state. Disconnects release resources; idle traffic is zero.

## A3 — Expose narrow commands and CLI transport

The following CLI spellings are proposed, not currently supported:

```text
aqueousctl shell capabilities --json
aqueousctl shell snapshot --json
aqueousctl shell watch --json
aqueousctl window activate --id ID --seat SEAT --json
aqueousctl window close --id ID --json
aqueousctl window state --id ID --minimized true --json
aqueousctl window move --id ID --workspace-id ID --json
aqueousctl window move --id ID --output NAME --json
aqueousctl workspace activate --id ID --seat SEAT --json
aqueousctl workspace rename --id ID --name NAME --json
aqueousctl session exit --json
```

Define the remaining maximize/fullscreen state operations in the same typed
command family if the adapter owns the actionable window model. Standard
foreign-toplevel operations remain preferred for clients that already hold
the corresponding handles. Share their policy implementation with ID actions.

Route commands into existing policy entry points; never expose raw pointers,
arbitrary shell execution or an unrestricted internal action dispatcher.
Specify whether moving a window follows focus (default: do not follow), how an
output target resolves its active workspace, and whether moving affects overview.
Resolve the target again at execution time and return a recoverable stale-target
error if it disappeared. Workspace activation/rename uses runtime identity.

Define request IDs, accepted/applied/error results, and an applied state sequence
where applicable. Successful mutation responses refer to committed state. For
exit, flush an accepted response before scheduling orderly termination; EOF alone
is not success. JSON stays on stdout, diagnostics on stderr, and failure exits
are nonzero. Do not silently truncate a malformed or incomplete watch batch.

Acceptance: native and XWayland window actions, invalid/stale IDs, output removal
during a request, duplicate activation, rename without identity changes, CLI
JSON escaping, and clean compositor shutdown in an isolated test instance.

## A4 — Keyboard layout and shortcut inhibition

Expose the effective keyboard group's layout names, current index, group/device
identity and changes through shell state. Add query/set/next commands with an
explicit seat and optional group target. Define zero-based indices, wraparound,
no-keyboard results, and behavior after keymap reload or device removal. Reuse
`Keyboard.zig`, `KeyboardGroup.zig` and `Seat.zig` state; runtime switching must
not rewrite the configured keymap. Publish changes from physical layout-switch
keys as well as shell commands.

Implement `keyboard-shortcuts-inhibit-v1` using wlroots and wire it into keyboard
dispatch. Advertising the manager alone is insufficient. Honor the inhibitor
only for its eligible focused surface and seat; restore shortcut handling on
focus loss, surface destruction and client disconnect. Reconcile it with session
lock, overview input, XWayland grabs and existing key press/release ownership.
Define the compositor's reserved escape policy explicitly.

Acceptance: two layouts, switching via shell and keyboard, two independent
groups, hotplug and reload. A focused screenshot-like overlay can inhibit normal
bindings; other surfaces/seats cannot inherit that inhibition. No stuck keys or
shortcut leakage across inhibitor destruction and lock transitions.

## A5 — Expose the existing overview

Add idempotent `overview show --output NAME`, `overview hide`, and optional
`overview toggle` commands, plus active output/workspace/selection state events.
Use the existing compositor-owned modal overview and its policy transitions;
see [overview implementation plan](overview-implementation-plan.md) for original
behavior and inspect the implementation for current semantics.

Define shell activation while overview is open, cancel versus confirm behavior,
and removal of the selected window/output. Do not create a second DMS overview
on top of Aqueous's overview. A DMS-rendered thumbnail overview is an optional
later project requiring a verified capture-to-window identity bridge.

Acceptance: opening from DMS/CLI, repeated show/hide, selection and cancellation,
window disappearance, output removal, lock, and operation without animations.

## A6 — Configuration and frame integration contracts

Keep persistent TOML writes in the shared `aqueous-config` helper. Inventory
which existing snapshot/validate/apply fields upstream can reuse for display,
keybind, cursor, typography and appearance settings. Add only missing helper
capabilities, with version negotiation and stale-generation protection.

Specify live preview versus persistent Apply, rejection/rollback behavior, and
ownership when DMS's built-in settings and the Aqueous plugin are both installed.
Do not introduce a second TOML writer or competing automatic theme synchronizer.
Runtime output power and battery refresh changes must not become persistent
display preferences accidentally. Keep fractional refresh rates and offline
monitor configurations intact.

For DMS frame/connected mode, first measure what normal layer-shell exclusive
zones already reserve. Add a runtime, per-output shell margin lease only if
remaining frame edges require it. Define combination with exclusive zones to
avoid double reservation, fullscreen behavior and automatic release on client
disconnect. Specify layer namespace rules for blur and shell-window floating
through supported configuration, rather than broad application matches.

Acceptance: failed display apply propagates to the UI, preview reverts correctly,
saved settings survive restart, concurrent plugin edits conflict safely, cursor
updates reach existing supported paths, and frame margins clear on shell crash.

## Access and compatibility

Apply Aqueous's existing security-context filtering to the new privileged shell
global. Respect session-lock policy for observations and mutations; explicitly
define what stays available while locked, with exit and window manipulation
rejected if policy disallows them. Ordinary same-user shell clients should work
without an installation-specific token or another policy-controller connection.

Keep old snapshot clients functional. Optional capabilities must be absent or
return `unsupported` when unavailable, including external-policy diagnostic
builds. Document supported compositor/helper/CLI versions and publish the protocol
XML under a redistributable license for downstream bindings.

## Delivery and release gates

1. A1: reviewed protocol/schema contract and identity correlation proof.
2. A2 + A3: live state, adapter transport and core commands; first desktop milestone.
3. A4: keyboard integration and shortcut inhibition (can proceed independently
   once common capability/error contracts are settled).
4. A5: existing overview exposed to the shell.
5. A6: built-in settings parity and optional frame coordination.

For implementation changes, run `zig build test` in `compositor/` with the
repository's required wlroots/build setup, plus focused Wayland integration
fixtures. Extend the existing DMS host harness using a pinned real DMS checkout
and its shared-QML submodule. Run helper/plugin/portal regression suites when
their contracts are changed; see their READMEs for exact commands.

Release evidence must include real DMS daemon + Quickshell testing on two
outputs, fractional scaling/rotation, XWayland, workspace reaping/hotplug, shell
restart, lock/unlock and suspend/resume, active-window screenshots, and a real
browser/recorder portal stream. Headless component success does not establish
hardware DPMS, gamma/HDR behavior or PipeWire stream startup. Record unsupported
hardware/backend combinations rather than claiming universal protocol success.

## Implementation record

- A1–A3: implemented `aqueous-shell-v1`, runtime identities, atomic bounded
  snapshot/delta delivery, `aqueousctl` transport and typed actions. Existing
  snapshot commands remain compatible. See the [protocol, schema and examples](../compositor/protocol/aqueous-shell-v1.md).
- A4: implemented effective keyboard group/device state, live switching, and
  focused-surface shortcut inhibition with existing key-release ownership.
- A5: exposed the existing overview and its output/selection state.
- A6: helper 0.7.1 advertises capabilities in version and snapshot responses.
  The [configuration contract](dms-configuration-contract.md) maps existing
  fields and defines provider ownership, preview/Apply and rollback requirements.
  Four standard layer-shell edge reservations were verified to update usable
  bounds and disappear on client crash, so no extra margin lease is needed for
  the audited DMS frame implementation. Upstream settings providers still need
  to implement the documented UI behavior.

The stream rebuilds/diffs committed state on dirty transactions rather than
maintaining a second per-field invalidation cache. Idle sessions produce no
heartbeat or polling traffic. A slow subscriber retains one bounded baseline
and pauses at one unacknowledged batch.

Automated verification and reproducible commands are recorded in
[the shell integration testing notes](dms-integration-testing.md). Headless
regressions do not certify real DMS daemon support, GPU capture, hardware hotplug,
suspend/resume or physical multi-seat behavior. Those remain release gates above;
this change does not claim full upstream DMS support.
