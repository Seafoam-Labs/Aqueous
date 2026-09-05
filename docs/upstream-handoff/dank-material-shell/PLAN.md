# Implement Aqueous integration in DankMaterialShell

Copy this directory, including `reference/`, into the DankMaterialShell checkout.
It contains the context needed to start work without the original conversation.
This is an implementation plan; the upstream changes below are not implemented.

## Objective

Integrate Aqueous with existing DMS services: session detection/logout, live
window/workspace state, focused-output routing, taskbars, keyboard layouts,
active-window screenshots, settings, monitor power and compositor overview.
Keep each area independently reviewable and preserve existing compositor paths.

The Aqueous compositor and CLI prerequisites have been implemented in the Aqueous
working tree. Confirm their availability in the actual test build; a released
minimum compositor version has not yet been established. The settings helper is
`aqueous-config` 0.7.1, protocol 1, with additive capability discovery. Do not
assume a similarly numbered installed Aqueous build contains the new protocol.

## Read first

- [Shell protocol and exact CLI commands](reference/aqueous-shell-v1.md).
- [JSON batch schema](reference/aqueous-shell-v1.schema.json).
- [MIT-licensed Wayland XML](reference/aqueous-shell-v1.xml).
- [Persistent configuration and frame contract](reference/configuration.md).

These are reference snapshots from the Aqueous working tree. Pin the Aqueous
revision or patch set actually tested when preparing PRs. Keep reference files
available during implementation; decide which documentation belongs in the
final upstream changes according to that project's conventions.

The previous DMS audit used commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`, with `dank-qml-common` at
`26396ce432d6c71c3f5367438f96f4a8d667e160`. This was a prospective 1.7 checkout,
not a verified released dependency. File paths below are discovery starting
points. Recheck the current target revision and skip gaps already fixed upstream.

## Architecture and implementation rules

1. Introduce one capability-aware Aqueous service using existing DMS service and
   process conventions. Prefer one persistent `aqueousctl shell watch --json`
   process owned by that service. Share its model across widgets. Use short-lived
   CLI processes for explicit actions. Do not poll snapshots on a timer.
2. Detect the compositor serving the current Wayland connection. Preserve nested
   session detection precedence, custom logout overrides and UWSM behavior.
   Never initialize Aqueous helpers in unrelated compositor sessions.
3. Keep IDs and sequences as strings. Entity identity is `(session, kind, id)`.
   Window IDs are ext-foreign-toplevel identifiers; output/workspace/group/device
   IDs are runtime identities. Connector names and workspace numbers are labels.
   Never correlate models by title, app ID, list position or workspace name.
4. The first record is a full snapshot. Apply subsequent deltas atomically,
   replacing each upserted entity in full and removing `kind:id` keys. Require
   matching session and exact `base_sequence`; sequence jumps are valid. Avoid
   conversion through JavaScript Number. Ignore additive unknown fields while
   validating required fields and the supported schema.
5. Buffer complete UTF-8 NDJSON lines with a 4 MiB JSON payload bound, allowing
   the newline delimiter separately. Pipes can split or combine records. On
   malformed/truncated data, invalid continuity or EOF, mark the model unavailable
   and disable stale-ID actions. Restart with capped exponential backoff and
   jitter; replace the model on the new snapshot. Stop the process on shutdown
   or backend change. A quiet established stream is healthy.
6. Capabilities and state are separate. Internal policy supports commands;
   external/comparison policy disables them. Lock state rejects mutations.
   Preserve generic protocol fallbacks where they provide verified behavior.
   Missing CLI/protocol support must not create a crash or tight retry loop.
7. Execute argument arrays through existing process APIs, never interpolated
   shell strings. Check both process status and JSON results. `applied` means a
   committed operation; `accepted` for close/exit is acknowledgement, not proof
   that a window disappeared. Never blindly retry timed-out mutations.
8. Use explicit seat identity for focus and keyboard actions. A default seat is
   valid only when unambiguous. Output IDs in state must be resolved to connector
   names for commands taking `--output`. Obtain focused output from the seat,
   including empty workspaces and layer-shell focus.
9. Keep persistent writes in `aqueous-config`. Use protocol/capability discovery,
   stdin JSON, validation and `expected_generation`. Keep runtime display power,
   layout switching and keyboard switching separate from saved preferences.
10. Standard output power, layer shell, workspace and capture protocols remain
    useful. Shortcut inhibition is already implemented by Aqueous and consumed
    by DMS. Add changes to those paths only for reproduced compatibility gaps.

## Work packages and proposed PRs

### P0 — Audit the current repository and capture fixtures

- Read repository contribution instructions and identify service registration,
  process utilities, provider dispatch, tests and required checks.
- Record exact DMS, common-QML, Quickshell, Aqueous and helper revisions.
- Run capability discovery and capture sanitized real snapshots/deltas in an
  isolated Aqueous session. Capture helper version/snapshot output too.
- Inspect whether the target Quickshell build exposes the exact identifier
  needed to correlate actionable toplevels with Aqueous metadata. If it does not,
  use Aqueous's own authoritative window model and ID-based actions. An upstream
  Quickshell change is optional, not a prerequisite for the CLI adapter.
- Produce a current file map and fixture set before changing consumers.

### P1 — Detection, capability service and logout

Suggested PR: `compositor: recognize Aqueous and support session exit`.

Start in `quickshell/Services/CompositorService.qml` and `SessionService.qml`.
Add an `AqueousService.qml` if consistent with the repository's architecture.
Recognize the socket-owning `aqueous` process and relevant desktop/session name
using existing precedence rules. Probe `aqueousctl shell capabilities --json`.
Route normal direct-session logout to `aqueousctl session exit --json`; preserve
custom commands and UWSM session handling. Remove the unknown-compositor fallthrough
to another compositor's exit path for detected Aqueous sessions.

Acceptance: direct, nested and UWSM sessions; custom logout; missing/old CLI;
unsupported schema; locked session; command failure; acknowledged orderly exit.
Other compositors must not require the Aqueous executables.

### P2 — Live model and workspace-aware shell consumers

Suggested PR: `compositor: add Aqueous live window and focus integration`.
Depends on P1's service lifecycle; split model and consumer wiring if necessary.

Implement the stream reducer and reconnect lifecycle before wiring UI consumers.
Start in `CompositorService.qml`, `Services/BarWidgetService.qml`, and
`Modules/DankBar/Widgets/WorkspaceSwitcher.qml`; trace dock/taskbar and launcher
consumers from their actual shared interfaces.

Expose workspace membership, app icons, active-workspace filtering, selected
output routing, fullscreen state, dock overlap and the appropriate window flags.
Respect `skip_taskbar`, `skip_switcher`, minimized and hidden states. Use the
adapter's authoritative workspace/window models for enriched features if native
identity correlation is unavailable. Keep generic workspace switching usable
when the Aqueous adapter cannot initialize.

Wire the existing activation, close, state and move UI affordances to stable-ID
commands. Moving a window does not itself request workspace activation or focus
following. Follow command results with authoritative state; do not report success
based solely on launching a process.

Acceptance: two outputs both showing workspace “1”; duplicate titles/app IDs;
empty workspace and layer focus; native and XWayland windows; rename/reaping and
workspace migration; target removal; shell/compositor restart; old IDs rejected;
capability loss; no per-widget watchers or periodic idle subprocesses.

### P3 — Keyboard layout indicator and actions

Suggested PR: `keyboard: support Aqueous layout state and switching`.
Depends on P2.

Start in `Modules/DankBar/Widgets/KeyboardLayoutName.qml`. Consume the seat's
active keyboard group and its effective layout index/names. Route set/next
through explicit seat/group commands. The index is zero-based; next wraps.
Do not infer current layout from configuration. Reflect physical/client-origin
layout changes, keymap reload, device removal and active-group changes.

Acceptance: no keyboard, multiple layouts, independent groups, hotplug/reload,
physical switching, stale group ID, unsupported capability and reconnect.

### P4 — Active-window screenshot backend

Suggested PR: `screenshot: support active-window capture on Aqueous`.
Depends on verified detection and the shell geometry contract. A standalone core
command may obtain a single fresh shell snapshot without the QML service running.

Start in `core/internal/screenshot/compositor.go` and trace its callers. Resolve
the chosen seat's focused eligible window from one atomic snapshot. Define
errors for layer focus, no active window, ambiguous seat and disappearing target.

Use the existing DMS capture backend and document whether the operation crops a
composed output or captures an isolated toplevel. For composed crops, occluders
remain visible. Choose content or outer bounds explicitly. Audit the capture
backend's coordinate conventions so scale/rotation are applied exactly once:
subtract output origin, transform/scale as required, round outward and clip.
Aqueous geometry is the committed destination during movement animations; do not
claim it tracks an animated visual clone pixel-for-pixel.

Acceptance: native/XWayland decorations, fractional scale, rotation, clipping,
moving/closing targets and no-focus errors. Test negative origins in native-only
Aqueous mode; its XWayland mode currently rejects negative output origins.
Attach representative image dimensions/crops to review evidence. Portal/PipeWire
integration is a separate feature, not fixed by this screenshot backend.

### P5 — Generic protocol DPMS fallback

Suggested PR: `compositor: use protocol DPMS for capable fallback compositors`.
Independent of the live Aqueous model.

Inspect `CompositorService.qml` and the existing core `dms dpms on/off` client.
Preserve specialized paths and select the generic fallback using output-power
availability, which is distinct from output-management availability. Reuse
connection lifecycle handling; surface actual failures and avoid fallthrough
after successful dispatch.

Acceptance: physical idle-off/wake-on, unsupported backend, reconnect/resume,
and unchanged specialized/labwc behavior. Headless success cannot prove DPMS.

### P6 — Generic asynchronous display-apply result fix

Suggested PR: `displays: propagate the actual output apply result`.
Independent generic fix; prerequisite for P8 if still required.

Inspect `Services/WlrOutputService.qml` and
`Modules/Settings/DisplayConfig/DisplayConfigState.qml`. The audited
`backendWriteOutputsConfig` path invoked asynchronous apply then immediately
called `finish(true)`. Reproduce against the current revision. If still present,
complete the UI operation from actual success/failure, cancellation or timeout,
and ignore late callbacks from superseded operations. Skip this PR if fixed.

Acceptance: rejected mode, timeout, late/out-of-order completion and successful
apply. Prove the UI no longer reports success before the backend responds.

### P7 — Aqueous keybind provider and cheatsheet

Suggested PR: `keybinds: add the Aqueous configuration provider`.
Depends on helper discovery; independent of P2's live model.

Start in `Services/KeybindsService.qml` and locate the core provider dispatch.
Use the helper schema/action inventory and existing request format discovered
from its source, documentation and fixtures. Cover unbound built-ins, multiple
bindings, custom commands, modifiers and conflicts. Validate drafts and persist
with the observed generation. Preserve stale drafts for reconciliation.

Acceptance: read/edit/remove bindings, validation failure, stale-generation
conflict, unsupported helper, and edits made concurrently by the settings plugin.

### P8 — Persistent display provider

Suggested PR: `displays: persist Aqueous configuration through aqueous-config`.
Depends on helper discovery and P6's correct runtime result behavior.

Keep preview in the existing output-management backend. Retain the previous live
configuration, test/apply the candidate, and implement Keep/Revert. Persist
through the helper only after Keep. Revert only while live state still matches
this preview; otherwise report a conflict. Separate successful persistence from
successful physical application.

Preserve offline monitors, EDID identity, custom modes and fractional refresh
rates. DPMS and battery refresh policy must not overwrite saved preferences.
Handle helper failures, uncertain timeouts and plugin concurrency explicitly.

Acceptance: preview/revert, rejected apply, restart persistence, hotplug during
preview, concurrent external changes, partial failure and offline configuration.

### P9 — Cursor, typography and appearance providers

Suggested PR: `appearance: integrate Aqueous configuration adapters`.
Depends on helper discovery. Split further if the existing providers are separate.

Reuse helper cursor/typography adapters and existing live cursor commands. Define
one explicit owner for automatic synchronization when native DMS settings and
the Aqueous Settings plugin coexist. Merely opening settings must not rewrite
canonical configuration. Preserve partial-success reports and explicit retries.
Retain known font face/slant/width and scaling limitations in UI reporting.

Acceptance: manual Apply, live cursor update, partial toolkit failure/retry,
stale generation, and coexistence with the plugin without feedback loops.

### P10 — Existing overview controls and frame compatibility

Suggested PR: `overview: control the Aqueous compositor overview`.
Depends on P2. Submit frame changes separately only for a reproduced issue.

Route overview controls to show/hide/toggle and observe the reported global
overview output/selection. Preserve lock/cancellation behavior and handle target
removal. Use Aqueous's existing overview; a DMS thumbnail overview is outside this
plan and would require a separate capture/identity design.

Validate `Modules/Frame/FrameExclusions.qml`, readiness/layout-refresh hooks,
four bar edges, dock placement and fullscreen behavior. Aqueous already passed
four-edge layer-shell reservation and crash-cleanup tests using namespace
`dms:frame-exclusion`. No new margin lease exists or is required for that audited
implementation. Reuse standard exclusive zones and avoid double reservation.
Keep persistent user gaps separate. Escalate a reproduced protocol gap as a
concrete Aqueous follow-up instead of inventing an unsupported command.

Acceptance: repeated show/hide, lock during overview, output/window removal,
animations disabled, connected frame on multiple outputs and shell crash cleanup.

## Verification and completion

Use repository-prescribed checks plus focused QML/Go tests. Fake subprocess
fixtures should cover split/coalesced lines, Unicode, oversize/malformed input,
sequence values above 2^53, snapshot reset, delta mismatch, EOF, command failures
and process cleanup. Test reducer atomicity and identity references across moves
and removals. Assert one watcher per service, bounded buffers/retries and no idle
polling. Check normal behavior for existing compositor backends.

Run an isolated Aqueous/DMS session with the real daemon and Quickshell for UI
integration. Record physical-output checks for DPMS, scale/rotation, hotplug and
resume, screenshots, lock and overview. Record browser/recorder portal streaming
as a separate release gate before claiming complete session support.

Existing evidence covers 393 Aqueous unit tests, native/XWayland protocol
fixtures, helper/plugin suites and a pinned DMS QML settings-host harness. It
does not certify these future DMS changes or full hardware/session support.

For each PR, record the concrete before/after behavior, revisions, required
capabilities, fallback behavior, test commands/results and unverified cases.
Keep generic fixes independently reviewable. Use the companion DankLinux-Docs
plan after integration and release dependencies are established. Do not invent
minimum release versions, and do not mark hardware gates complete from mocks.
