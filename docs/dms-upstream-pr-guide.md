# DMS upstream pull request guide for Aqueous

Status: proposed PR breakdown. No upstream issues, comments, branches or PRs
have been created by this document.

Companion: [Aqueous implementation plan](dms-integration-implementation-plan.md).
The A1–A6 labels below refer to its delivery phases. Proposed `aqueousctl shell`
and action commands do not exist yet.

## Baseline and upstream approach

The audited DMS checkout is commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`, with `dank-qml-common` at
`26396ce432d6c71c3f5367438f96f4a8d667e160`. Selected upstream master files were
also checked on 2026-09-05. Rebase this inventory against the chosen upstream
revision before coding; the baseline is prospective 1.7 and is not a released
version guarantee. Existing compatibility evidence is in the
[Aqueous DMS plugin README](../dms-plugin/README.md).

Prefer small changes with observable before/after behavior. Separate generic
protocol fixes from Aqueous-specific adapters so other compositors can benefit.
Keep generic ext-workspace, output management and foreign-toplevel paths working.
Do not advertise complete support merely after adding compositor detection.

Suggested order:

| PR | Target | Aqueous prerequisite |
| --- | --- | --- |
| 1. Generic DPMS fallback | DankMaterialShell | Existing output-power protocol |
| 2. Aqueous detection and logout | DankMaterialShell | A3 graceful exit and capability query |
| 3. Live Aqueous shell adapter | DankMaterialShell; possibly Quickshell if native identity bridging is chosen | A1–A3 |
| 4. Active-window screenshots | DankMaterialShell core | Existing snapshots for a basic implementation; A1 geometry contract |
| 5. Keyboard layout integration | DankMaterialShell | A4 layout query/control/events |
| 6. Native settings providers | DankMaterialShell, split by settings area | A6 helper contract |
| 7. Overview and frame coordination | DankMaterialShell, separate commits or PRs | A5 overview; A6 frame contract if needed |
| 8. Supported-session documentation | DankLinux-Docs; packaging changes only where needed | Released and verified dependency set |

Shortcut inhibition is primarily an Aqueous change: DMS already consumes that
protocol. Basic workspace activation also already has a generic DMS path.
Submit fixes there only for failures reproduced against the target build.

## PR 1 — Generic monitor power fallback

Suggested title: `compositor: use protocol DPMS for supported fallback compositors`

Problem: on Aqueous, DMS idle handling reaches the unknown-compositor path even
though Aqueous implements wlr output power management. The inspected code invokes
`dms dpms on/off` for labwc but does not offer it as a general capability fallback.

Change:

- Preserve existing specialized paths; route other capable compositors through
  the existing DMS protocol DPMS client.
- Probe the output-power capability, not the separate output-management global.
- Return after successful dispatch and report command failures accurately.
- Reuse connection/capability lifecycle handling across reconnect and resume.

Touchpoints: [CompositorService.qml][compositor], the existing core DPMS client,
and capability discovery if output-power availability is not already exposed.

Acceptance: idle timeout powers off and wake restores Aqueous outputs; unsupported
backends fail cleanly; labwc and specialized compositor behavior are unchanged.
Include physical-output evidence because a headless test cannot prove DPMS.

## PR 2 — Detect Aqueous and perform graceful logout

Suggested title: `compositor: recognize Aqueous and support session exit`

Problem: Aqueous is classified as unknown, and the inspected default logout path
falls through to `HyprlandService.exit()` after checking known alternatives.

Change:

- Recognize the `aqueous` Wayland socket owner and `Aqueous` desktop/session name.
  Preserve current detection precedence and stale-environment safeguards.
- Add `isAqueous` and a capability-aware adapter initialization path.
- Invoke the supported graceful exit command. Keep custom logout commands and
  UWSM behavior consistent with DMS's session lifecycle.
- Check optional helper availability only in Aqueous sessions; other sessions
  must not require an installed `aqueousctl` binary.

Touchpoints: [CompositorService.qml][compositor],
[SessionService.qml][session], and a small `AqueousService.qml` if appropriate.

Acceptance: direct and UWSM session paths, custom logout override, missing/old
CLI, and a nested Aqueous session under another compositor. The exited process
must be the compositor serving the shell's Wayland connection.

## PR 3 — Consume live state for workspace-aware shell behavior

Suggested title: `compositor: add Aqueous window and focus integration`

Problem: basic ext-workspace switching can work, but the inspected compositor
service returns unfiltered windows for unknown compositors, and focused-monitor
routing explicitly enables only known backends.

Change:

- Start one `aqueousctl shell watch --json` process, or use direct Go protocol
  bindings if upstream prefers that transport. No repeated snapshot polling.
- Negotiate the schema/capabilities and apply each complete state batch once.
  Handle startup, malformed data, EOF, bounded restart backoff and resync.
- Publish window/workspace membership, selected output and geometry to the
  existing shell service interfaces.
- Wire workspace app icons, current-workspace taskbar/dock filtering, focused
  monitor popouts/OSDs, fullscreen state and dock overlap detection.
- Honor skip-taskbar/skip-switcher flags and minimized/hidden distinctions.
- Use explicit IDs for actions; support duplicate titles and application IDs.

Identity is a prerequisite, not a follow-up fix. Verify the target Quickshell
build's toplevel identifier exposure. If it cannot correlate ext identifiers
with actionable wlr toplevels, use the adapter's authoritative window model and
ID-based commands. Similarly, use an authoritative workspace model for enriched
features instead of guessing associations to ext-workspace objects by name.
Keep the generic workspace backend available when the adapter is unavailable.

Touchpoints: new `Services/AqueousService.qml`, service registration where
required, [CompositorService.qml][compositor],
[BarWidgetService.qml][bar], [WorkspaceSwitcher.qml][workspaces], and the dock,
taskbar and launcher consumers that depend on those services.

Acceptance: two outputs each with workspace “1”, focus on an empty workspace,
renumbering/reaping, migration, identical application titles, native/XWayland
windows, shell restart and missing capability fallback. Demonstrate no periodic
idle subprocesses and bounded resource use after repeated reconnects.

If native Quickshell identity support is needed, submit that bounded change to
the actual Quickshell provider used by DMS, then document the new minimum build.
Do not assume `dank-qml-common` can add missing C++ protocol bindings.

## PR 4 — Active-window screenshots

Suggested title: `screenshot: support active-window capture on Aqueous`

Problem: the inspected core active-window geometry switch has no Aqueous backend.
Standard screen/region capture and the Aqueous portal chooser do not fix this
separate CLI/UI feature.

Change:

- Add Aqueous detection and focused-window geometry lookup in the screenshot
  backend. Existing `aqueousctl windows --json` and `outputs --json` may be
  sufficient for an initial implementation after the coordinate audit.
- Define no focused window, layer-shell focus, no eligible output and multiple
  seat behavior; never silently capture an arbitrary window.
- Convert documented logical bounds into output pixels with scale, transform,
  clipping and decoration policy applied consistently.
- State whether the implementation crops the composed output or captures an
  isolated toplevel. Output cropping includes occluders; these are different
  user-visible contracts. Use ext toplevel capture only if DMS's selected capture
  path supports it and identity mapping is verified.

Touchpoint: [core/internal/screenshot/compositor.go][screenshot] and its callers.

Acceptance: negative monitor origins, fractional scales, rotated outputs,
decorated native/XWayland windows, edge clipping, moving/closing targets and
no-active-window errors. Include output images and their dimensions in review
evidence. Keep portal/PipeWire integration outside this PR.

## PR 5 — Keyboard layout indicator and switching

Suggested title: `keyboard: support Aqueous layout state and switching`

Change: consume layout/group events through the Aqueous adapter, show the current
layout and available names, and route next/set actions to the explicit seat/group
commands. Physical layout-switch keys and shell actions must converge on the
same displayed state. Missing capability hides/disables the control accurately.

Touchpoint: [KeyboardLayoutName.qml][keyboard] and `AqueousService.qml`.

Acceptance: multiple layouts, keyboard hotplug, config reload, physical switching,
multiple groups and reconnect. Do not parse configuration to infer the currently
active XKB group.

## PR 6 — Built-in settings providers

Split this work into independently reviewable keybind, display and appearance
PRs. The existing Aqueous Settings plugin remains a supported frontend.

### Keybinds and cheatsheet

Add a provider to [KeybindsService.qml][keybinds] and the corresponding core
provider dispatch discovered at the target revision. Reuse the helper's
schema/action inventory and validated mutations. Cover unbound built-ins,
multiple bindings, custom commands, modifiers, conflicts and stale edits.
Do not directly write TOML from a second implementation.

### Persistent displays and apply results

The generic [WlrOutputService.qml][outputs] already supports live output changes.
Add Aqueous persistence through the helper in
[DisplayConfigState.qml][display-config], preserving offline entries, EDID
identity and fractional refresh. Coordinate preview/revert with canonical Apply.

The inspected generic `backendWriteOutputsConfig` path calls the asynchronous
output apply and immediately invokes `finish(true)`. Reproduce this against the
target revision; if still present, propose a separate generic fix to propagate
the actual apply result before building Aqueous persistence on top of it.

Acceptance: rejected mode, apply timeout, revert, restart, hotplug, concurrent
plugin edits and battery refresh changes that do not overwrite saved preferences.

### Cursor, typography and appearance

Use existing live cursor control and helper adapters. Define a single owner for
automatic color/font/cursor synchronization when both DMS settings and the plugin
are enabled. Preserve helper partial-failure reporting and retry semantics.
Exact font face/slant/width limitations already documented by the plugin should
remain visible rather than being reported as complete synchronization.

## PR 7 — Overview control and optional frame integration

Suggested titles:

- `overview: control the Aqueous compositor overview`
- `frame: coordinate Aqueous reserved margins`

For overview, call Aqueous's existing overview show/hide operations and subscribe
to its state. Handle activation, cancellation and output removal consistently.
Do not make DMS render a competing overview. A separate thumbnail UI would need
its own design and capture/identity evidence.

For frame/connected mode, verify all bar edges, exclusive zones, dock placement,
fullscreen behavior and layer namespaces first. Add margin coordination only
where existing layer-shell behavior is insufficient. Use an Aqueous runtime lease
if required, restoring usable areas when DMS exits or crashes. Keep persistent
user gaps distinct from shell-owned runtime reservations.

Touchpoints: workspace/overview UI, compositor frame readiness and layout refresh
hooks in [CompositorService.qml][compositor], plus the Aqueous adapter.

Acceptance: repeated open/close, lock during overview, target disappearance,
animations disabled, four bar edges, multiple outputs, fullscreen and shell crash.

## PR 8 — Document the supported session

Target [DankLinux-Docs](https://github.com/AvengeMedia/DankLinux-Docs) for compositor
setup documentation. Update DMS's supported-compositor statement only to match
verified capabilities. Packaging PRs belong in the repositories that own the
relevant packages; plugin registry submissions are separate from core support.

Document minimum released Aqueous, helper, DMS and Quickshell versions; session
environment, startup, DMS keybindings, portal routing and plugin enablement;
configuration ownership; feature gaps and reproducible diagnostics. Preserve
the independent `aqueousPortal` plugin and user disable preference.

Do not promote the recorded prospective 1.7 checkout to a released dependency.
Validate the actual release's plugin APIs and full recorder/browser stream startup.

## Review evidence checklist

For each PR, lead with the concrete trigger and resulting behavior. Include:

- Exact DMS, shared-QML, Quickshell, Aqueous and helper revisions tested.
- Required capabilities and behavior when the helper/protocol is unavailable.
- Focused automated tests plus desktop evidence appropriate to the feature.
- Lifecycle coverage: restart, disconnect, hotplug and stale target handling.
- Resource evidence for persistent consumers: idle traffic/process count and
  reconnect behavior, not just a successful initial connection.
- A short recording only where behavior is visual; logs/results for backend work.

Avoid broad support claims based on a headless plugin harness. The integration
gate includes the real DMS daemon, Quickshell, lock/idle/DPMS and resume,
multi-output routing, screenshots and a browser/recorder portal stream.

## Source references

The links below are pinned to the audited checkout so the reported gaps remain
reviewable even if upstream master changes. Recheck their current equivalents
before preparing each PR.

[compositor]: https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Services/CompositorService.qml
[session]: https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Services/SessionService.qml
[bar]: https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Services/BarWidgetService.qml
[workspaces]: https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Modules/DankBar/Widgets/WorkspaceSwitcher.qml
[screenshot]: https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/core/internal/screenshot/compositor.go
[keyboard]: https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Modules/DankBar/Widgets/KeyboardLayoutName.qml
[keybinds]: https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Services/KeybindsService.qml
[outputs]: https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Services/WlrOutputService.qml
[display-config]: https://github.com/AvengeMedia/DankMaterialShell/blob/59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3/quickshell/Modules/Settings/DisplayConfig/DisplayConfigState.qml
