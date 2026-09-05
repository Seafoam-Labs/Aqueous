# Aqueous integration: complete upstream implementation plan

Copy this **single document** into the relevant project. It contains the DMS
implementation plan, DankLinux-Docs plan, shell/CLI contract, configuration
contract, full JSON schema and Wayland protocol XML. No companion handoff files
or original conversation are needed. Repository source and the actual installed
runtime still need to be inspected and tested as directed below.

Suggested instruction for an implementation agent:

> Implement the sections of this document that belong to the current repository.
> Read its contribution instructions and audit the current revision first. Follow
> the work-package dependencies, keep proposed PRs independently reviewable, run
> required checks, and report any remaining cross-project or hardware verification
> gaps accurately. Use the embedded contracts as the Aqueous reference.

| Current repository | Applicable work |
| --- | --- |
| DankMaterialShell | DMS work packages P0–P10 and their verification requirements |
| DankLinux-Docs | Documentation steps and release/support verification |
| Quickshell | No prerequisite change for the CLI adapter; scope a separate binding change only if DMS chooses a native identity bridge |
| Packaging or plugin registry | Only specific dependency/registry changes established by the implementation; these belong in their owning repositories |

The Aqueous prerequisites are implemented in its working tree. The DMS upstream
work below has not been implemented or submitted by this handoff. Confirm tested
revisions and released availability before making support claims.

Contents:

- [DMS implementation plan](#dms-plan)
- [DankLinux-Docs plan](#docs-plan)
- [Shell protocol and CLI contract](#shell-contract)
- [Configuration and frame contract](#configuration-contract)
- [Complete JSON batch schema](#json-schema)
- [Complete Wayland protocol XML](#wayland-xml)

<a id="dms-plan"></a>

## DMS implementation plan

Apply this section in the DankMaterialShell checkout. All handoff references are
embedded below. This is an implementation plan; the upstream changes below are
not implemented.

### Objective

Integrate Aqueous with existing DMS services: session detection/logout, live
window/workspace state, focused-output routing, taskbars, keyboard layouts,
active-window screenshots, settings, monitor power and compositor overview.
Keep each area independently reviewable and preserve existing compositor paths.

The Aqueous compositor and CLI prerequisites have been implemented in the Aqueous
working tree. Confirm their availability in the actual test build; a released
minimum compositor version has not yet been established. The settings helper is
`aqueous-config` 0.7.1, protocol 1, with additive capability discovery. Do not
assume a similarly numbered installed Aqueous build contains the new protocol.

### Read first

- [Shell protocol and exact CLI commands](#shell-contract).
- [JSON batch schema](#json-schema).
- [MIT-licensed Wayland XML](#wayland-xml).
- [Persistent configuration and frame contract](#configuration-contract).

These are reference snapshots from the Aqueous working tree. Pin the Aqueous
revision or patch set actually tested when preparing PRs. The contracts and
schemas are embedded in this document; decide which documentation belongs in
the final upstream changes according to that project's conventions.

The previous DMS audit used commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`, with `dank-qml-common` at
`26396ce432d6c71c3f5367438f96f4a8d667e160`. This was a prospective 1.7 checkout,
not a verified released dependency. File paths below are discovery starting
points. Recheck the current target revision and skip gaps already fixed upstream.

### Architecture and implementation rules

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

### Work packages and proposed PRs

#### P0 — Audit the current repository and capture fixtures

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

#### P1 — Detection, capability service and logout

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

#### P2 — Live model and workspace-aware shell consumers

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

#### P3 — Keyboard layout indicator and actions

Suggested PR: `keyboard: support Aqueous layout state and switching`.
Depends on P2.

Start in `Modules/DankBar/Widgets/KeyboardLayoutName.qml`. Consume the seat's
active keyboard group and its effective layout index/names. Route set/next
through explicit seat/group commands. The index is zero-based; next wraps.
Do not infer current layout from configuration. Reflect physical/client-origin
layout changes, keymap reload, device removal and active-group changes.

Acceptance: no keyboard, multiple layouts, independent groups, hotplug/reload,
physical switching, stale group ID, unsupported capability and reconnect.

#### P4 — Active-window screenshot backend

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

#### P5 — Generic protocol DPMS fallback

Suggested PR: `compositor: use protocol DPMS for capable fallback compositors`.
Independent of the live Aqueous model.

Inspect `CompositorService.qml` and the existing core `dms dpms on/off` client.
Preserve specialized paths and select the generic fallback using output-power
availability, which is distinct from output-management availability. Reuse
connection lifecycle handling; surface actual failures and avoid fallthrough
after successful dispatch.

Acceptance: physical idle-off/wake-on, unsupported backend, reconnect/resume,
and unchanged specialized/labwc behavior. Headless success cannot prove DPMS.

#### P6 — Generic asynchronous display-apply result fix

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

#### P7 — Aqueous keybind provider and cheatsheet

Suggested PR: `keybinds: add the Aqueous configuration provider`.
Depends on helper discovery; independent of P2's live model.

Start in `Services/KeybindsService.qml` and locate the core provider dispatch.
Use the helper schema/action inventory and existing request format discovered
from its source, documentation and fixtures. Cover unbound built-ins, multiple
bindings, custom commands, modifiers and conflicts. Validate drafts and persist
with the observed generation. Preserve stale drafts for reconciliation.

Acceptance: read/edit/remove bindings, validation failure, stale-generation
conflict, unsupported helper, and edits made concurrently by the settings plugin.

#### P8 — Persistent display provider

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

#### P9 — Cursor, typography and appearance providers

Suggested PR: `appearance: integrate Aqueous configuration adapters`.
Depends on helper discovery. Split further if the existing providers are separate.

Reuse helper cursor/typography adapters and existing live cursor commands. Define
one explicit owner for automatic synchronization when native DMS settings and
the Aqueous Settings plugin coexist. Merely opening settings must not rewrite
canonical configuration. Preserve partial-success reports and explicit retries.
Retain known font face/slant/width and scaling limitations in UI reporting.

Acceptance: manual Apply, live cursor update, partial toolkit failure/retry,
stale generation, and coexistence with the plugin without feedback loops.

#### P10 — Existing overview controls and frame compatibility

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

### Verification and completion

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
Keep generic fixes independently reviewable. Use the [DankLinux-Docs section](#docs-plan)
after integration and release dependencies are established. Do not invent
minimum release versions, and do not mark hardware gates complete from mocks.

<a id="docs-plan"></a>

## DankLinux-Docs plan

Apply this section in the DankLinux-Docs checkout. It describes the documentation
work accompanying Aqueous integration in DankMaterialShell. DMS upstream support
and released dependency versions must be verified before publishing support claims.

### Objective and baseline

Add an Aqueous setup guide and an accurate feature/support statement. Integrate
with the repository's existing compositor guide structure, navigation and style.

Aqueous now has a versioned shell protocol, live `aqueousctl` state/actions,
keyboard layout control, shortcut inhibition, overview control and graceful
logout. Helper `aqueous-config` 0.7.1 adds capability discovery while retaining
protocol 1. These Aqueous changes were implemented in its working tree; identify
the actual released version that includes them before writing requirements.

The previous integration audit used DMS commit
`59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3` and common QML commit
`26396ce432d6c71c3f5367438f96f4a8d667e160`. This is a historical prospective 1.7
baseline, not a released minimum version. No upstream PRs were opened as part of
the Aqueous implementation. Check current merged work rather than assuming the
planned adapters/settings providers are available.

### Implementation steps

1. Read project instructions and find the current compositor guides, navigation,
   supported-compositor table, installation and portal troubleshooting pages.
2. Establish exact released Aqueous, aqueousctl, aqueous-config, DMS and
   Quickshell dependencies. Correlate each documented feature with merged DMS
   support and desktop test evidence. Describe development builds explicitly if
   documentation precedes a release.
3. Add an Aqueous session guide covering installation through the supported
   packaging source, session startup, DMS launch, session environment and
   compositor keybindings using the actual released syntax. Respect existing
   direct-session and UWSM guidance; do not start duplicate shell processes.
4. Explain configuration ownership: Aqueous TOML is canonical, persistent writes
   go through `aqueous-config`, and the Aqueous Settings plugin can coexist with
   merged native DMS providers. State which features require which frontend.
   Runtime layout/keyboard/DPMS changes do not imply persistent configuration.
   Only one provider should own automatic cursor/font/color synchronization.
5. Document portal routing and screen sharing separately from screenshots.
   Preserve the independent `aqueousPortal` plugin and user enable/disable
   preference. Verify exact portal packages, service names and configuration
   from the released integration; do not invent generic replacement settings.
6. Document native overview controls and standard frame exclusive zones.
   Aqueous already supports four frame-edge reservations and automatic cleanup.
   Do not instruct users to add an unimplemented margin command or duplicate
   frame reservation using persistent gaps.
7. Add diagnostics and failure guidance: missing/outdated CLI, unsupported
   protocol, wrong/nested session, stream disconnect, stale IDs, locked-session
   rejection, ambiguous seat and partial toolkit synchronization. Explain that
   runtime IDs expire on compositor restart and timed-out mutations may have
   executed already.
8. Update navigation/support tables to match verified capabilities, link to the
   setup guide, and run the repository's documentation build/link checks.

### Diagnostic commands

Run in the Aqueous session being diagnosed:

```sh
aqueousctl shell capabilities --json
aqueousctl shell snapshot --json
aqueousctl shell watch --json
aqueous-config version
aqueous-config snapshot --shell dms
```

The watch command intentionally remains running and prints an initial snapshot
then changes. Stop it with Ctrl+C. Window titles and configuration paths can
appear in output; request only the relevant redacted diagnostics in bug reports.
Capability discovery is more reliable than assuming support from executable names.

### Verification and review evidence

Verify setup instructions in a fresh session with the real DMS daemon and
Quickshell. Record package/revision versions and results for workspace/taskbar
integration, focused-output routing, keyboard layout changes, logout, lock,
overview, frame layout, screenshots, settings save/restart and plugin coexistence.
Use physical outputs for DPMS, hotplug, fractional scale/rotation and resume.
Test a real browser/recorder stream for portal support.

Distinguish unsupported features from untested combinations. Existing Aqueous
headless protocol and DMS QML settings-host tests do not certify a full desktop
session. Submit packaging fixes in their owning repositories and plugin registry
submissions separately. A Quickshell dependency change is only needed if DMS
actually chooses a native identity bridge; the aqueousctl adapter avoids that
requirement.

Suggested PR title: `docs: add the verified Aqueous session setup guide`.
Lead the description with the supported setup and tested dependency set; include
the documentation build/link checks and any outstanding feature limitations.

<a id="shell-contract"></a>

## Shell protocol and CLI contract

The MIT-licensed [Wayland XML](#wayland-xml) and
[JSON schema](#json-schema) describe the shell interface.
`aqueousctl` is the supported command/stream adapter. There is no separate
compositor socket or external window-manager connection to configure.

### Discovery and compatibility

Bind `aqueous_shell_manager_v1` on the current Wayland display. Its capabilities
JSON includes `schema: 1`, a random 128-bit session token, maximum batch size,
and independent `state`, `commands`, `keyboard`, `overview` and
`shortcut_inhibition` booleans. The token changes on compositor restart.
Commands/keyboard control/overview control require integrated internal policy;
external and comparison diagnostic modes expose observation only. Locked
sessions remain observable to trusted shell clients but reject every mutation.
The shell global is hidden from Wayland security-context clients. Shortcut
inhibition is available to ordinary application surfaces, scoped to focus/seat.

Use capability discovery rather than assuming that installing `aqueousctl`
means the running compositor supports this protocol. Schema 1 permits additive
fields. Ignore unknown optional fields; reject unsupported schema versions.

```sh
aqueousctl shell capabilities --json
aqueousctl shell snapshot --json
aqueousctl shell watch --json
```

The first command prints capabilities, the second prints one complete snapshot,
and the third prints a snapshot followed by deltas, one JSON object per line.
The CLI allows five seconds for connection/initial state or command completion.
An established watch has no idle timeout, heartbeat or polling subprocess.
Malformed/truncated input or a broken sequence terminates the CLI with a nonzero
exit code. A consumer restarts it with bounded backoff and replaces its old model
with the new snapshot. Do not automatically retry a timed-out mutation: it may
already have executed; inspect fresh state first.

### Identity and entities

All IDs and sequences are JSON strings. IDs are scoped to the session token;
never interpret them as pointers, indices or persistent configuration keys.
Window IDs are the exact `ext_foreign_toplevel_handle_v1.identifier` values.
Output, workspace, keyboard group and keyboard device IDs are monotonically
allocated runtime identities. Seats use their names. Removal/recreation gives
outputs/devices/groups new IDs even if their names are reused.

Workspace identity survives rename, renumbering and output migration while the
workspace exists. `number` is a one-based display position. The optional
ext-workspace persistent ID remains absent: Aqueous does not promise identity
across sessions. Native Wayland clients can send `identify_workspace` with their
own ext-workspace handle and receive the corresponding runtime ID; removed
handles return an empty string.

| Kind | Principal fields |
| --- | --- |
| `output` | `id`, connector `name`, `enabled`, `powered`, `bounds`, `usable_bounds`, `scale`, `transform`, `active_workspace` |
| `workspace` | `id`, `output`, `name`, `number`, `active`, `urgent` |
| `window` | `id`, `backend`, `app_id`, `class`, `title`, `workspace`, `output`, `geometry`, `outer_geometry`, presentation/visibility flags and per-window capabilities |
| `seat` | name as `id`, selected `output`, focused `window`, `focus_kind`, active `keyboard` group |
| `keyboard` | group `id`, `seat`, layout names in `layouts`, zero-based effective `index` |
| `keyboard_device` | `id`, `name`, `seat`, `group`, `virtual` |
| `session` | fixed `id: "session"`, `locked`, unambiguous `default_seat`, `overview_output`, `overview_window` |

Cleared optional values are `null`. Full entity replacements are sent on change;
missing optional values must not preserve an earlier value. Backend `xwayland`
uses `class` for application identity when `app_id` is null.

`enabled` includes temporarily powered-off outputs; `powered` reports whether
the output is currently on. `can_activate` reflects focus eligibility.

`visible` means mapped on an active workspace and not policy-hidden, not that
pixels are unoccluded. `can_minimize` and `can_maximize` describe eligibility for
client requests in floating presentations; tiled layouts generally reject these
requests. A compositor-owned maximize may not be undone by a client request.
`focused` means focused by at least one seat; consult the seat entities for the
specific seat. Selected output is independent of window focus and persists while
layer-shell surfaces have focus. No keyboard or ambiguous seat defaults use null.

### Geometry and capture

`geometry` is the committed global logical content box (`Window.box` after a
render transaction). Negative coordinates are valid. `outer_geometry` adds the
compositor-owned enabled border edges; it does not invent client shadow extents.
Client-side decorations included in the client's content geometry remain there.
Fullscreen suppresses compositor borders.

During movement animations these boxes describe the committed destination. The
compositor's frozen visual clone may still be moving. Per-frame clone geometry
is intentionally not streamed; there is no animation timer or rendered-pixel
claim in this interface. A screenshot consumer must choose composed-output crop
versus isolated toplevel capture explicitly. Output crop includes occluders.
For a crop, subtract output logical origin, apply scale and output transform,
round crop edges outward, and intersect with the output pixel extent. Do not
assume an unrotated scale-1 origin or include another workspace's hidden window.
Use existing wlr output management for full modes/transform information and
standard capture protocols for pixels.

### Atomic batches and flow control

`subscribe` is allowed once per manager. The server sends `begin(serial)`, one
or more `data(bytes)` fragments, then `done(serial)`. Concatenate fragments before
UTF-8 decoding and JSON parsing: fragment boundaries can split codepoints.
Maximum complete JSON size is 4 MiB. Entity state is limited to 2 MiB including
accounting overhead. A compositor permits at most 16 bound shell managers.

A complete batch has this envelope (the entity list below is abbreviated):

```json
{"schema":1,"session":"6b94a179d09456846b94a179d0945684","sequence":"12","base_sequence":null,"type":"snapshot","upsert":[{"kind":"workspace","id":"7","output":"2","name":"Code","number":1,"active":true,"urgent":false}],"removed":[]}
```

Deltas contain changed full entities and removal keys in `kind:id` form:

```json
{"schema":1,"session":"6b94a179d09456846b94a179d0945684","sequence":"15","base_sequence":"12","type":"delta","upsert":[{"kind":"workspace","id":"7","output":"2","name":"Review","number":1,"active":true,"urgent":false}],"removed":["window:closed-window-id"]}
```

Apply all replacements/removals atomically, regardless of their order in the
arrays. A real initial snapshot contains all current entities, including empty
workspaces and outputs. Two outputs may both have a workspace named `1`; use
runtime associations. A delta can move a workspace to a surviving output and
remove the old output in the same batch. A layer-focus delta clears the seat's
window but retains its selected output. After restart, discard all old IDs.

Acknowledge the exact `done` serial only after accepting the batch. One batch
can be in flight per manager. A slow consumer pauses delivery rather than
accumulating an unbounded queue. Changes meanwhile coalesce into the next delta
against the client's acknowledged baseline. Sequence numbers can jump;
`base_sequence` must exactly match the consumer's previous sequence. Duplicate
subscriptions or invalid acknowledgements are protocol errors. State size and
client limits fail explicitly rather than truncating data. A paused connection
is bounded; it is released normally on disconnect.

Publication is event-driven after policy/render transactions and workspace
publication settle. No repeating scan is scheduled. At each dirty publication
Aqueous constructs/diffs committed entity state; unchanged entities generate no
wire traffic. This favors a consistent whole-desktop transaction over per-field
invalidation caches. Future optimization can narrow reconstruction without
changing the wire contract.

### Typed commands

```sh
aqueousctl window activate --id ID [--seat SEAT] --json
aqueousctl window close --id ID --json
aqueousctl window state --id ID --minimized true --json
aqueousctl window state --id ID --maximized false --json
aqueousctl window state --id ID --fullscreen true --json
aqueousctl window move --id ID --workspace-id ID --json
aqueousctl window move --id ID --output CONNECTOR --json
aqueousctl workspace activate --id ID [--seat SEAT] --json
aqueousctl workspace rename --id ID --name NAME --json
aqueousctl keyboard query --json
aqueousctl keyboard set [--seat SEAT] [--group ID] --index 1 --json
aqueousctl keyboard next [--seat SEAT] [--group ID] --json
aqueousctl overview show --output CONNECTOR --json
aqueousctl overview hide --json
aqueousctl overview toggle --output CONNECTOR --json
aqueousctl session exit --json
```

Omit `--seat` only when exactly one seat exists; omit `--group` to target that
seat's active keyboard group. Keyboard query returns the complete atomic shell
snapshot, including keyboard groups, devices and seat associations. Group
indices are zero-based; next wraps. Switching changes live XKB state, not TOML.
Physical/client-origin layout changes and hotplug/reload produce normal deltas.

Moving by output selects its currently active workspace. Moving does not request
workspace activation or focus-following; ordinary policy repairs focus when the
source window becomes hidden. Activation reveals the target workspace and
restores eligible minimized windows. Move/state/activation cancels the existing
overview. Rename changes the display name without identity changes. Names are
UTF-8, at most 1024 bytes and cannot contain newline characters.

Overview is the existing compositor-owned modal overview. Show/hide are
idempotent. Show on a different output cancels the old overview first. Empty
workspaces or policy conditions that prohibit overview return `unavailable`.
The overview is global, and its output/selection is reported in the session
entity. Lock and normal compositor cancellation rules remain authoritative.

One outstanding command is allowed per manager. Requests are queued until a
settled transaction and their targets are resolved then, so disappearing objects
produce `not_found`. Pending command storage is bounded. Results contain the
request ID, status and current committed state sequence. `applied` is sent after
committing the operation. Close and exit return `accepted`: close requests do
not force a client to exit; session exit flushes its acknowledgement before
orderly compositor termination. EOF without that acknowledgement is an error.

The CLI prints `{ "ok": true, "status": "applied", "sequence": "15" }` or a
corresponding error object. Errors include `invalid`, `not_found`, `locked`,
`unsupported`, `busy`, `ambiguous_seat` and `unavailable`. JSON goes to stdout;
diagnostics go to stderr. Exit status is 0 on success, 2 for malformed CLI
arguments and 1 for protocol/operation failure. There is no arbitrary command
execution or public raw internal action dispatcher.

### Shortcut inhibition policy

The focused surface's inhibitor is active only for its seat, while unlocked and
outside compositor overview. Focus loss, client destruction and lock deactivate
it. Normal policy and external XKB bindings are bypassed while active. Built-in
VT switching remains reserved; inhibition does not disable secure session lock.
Each key release retains the consumer chosen for its press, including when the
inhibitor disappears between press and release. Existing XWayland grab policy
remains in place. Starting overview refreshes inhibitor eligibility immediately.

### Validation

`zig build test` includes CLI parsing and batch continuity checks. Run
`python3 scripts/test-shell-integration.py` with a Pixman-compatible diagnostic
compositor (or the binary overrides described by the test) for isolated two-output
state/actions, keyboard layout, inhibition, flow control, lock, and frame tests.
No test connects to the user's Wayland display. Hardware capture, DPMS and
suspend/resume remain desktop release checks; this protocol alone does not add
an upstream DMS consumer.

<a id="configuration-contract"></a>

## Configuration and frame contract

This is the A6 contract from the [DMS implementation plan](#dms-plan).
The compositor shell protocol owns runtime observation and typed actions.
`aqueous-config` owns persistent configuration and toolkit synchronization.
The existing Aqueous Settings plugin remains supported alongside future upstream
DMS settings providers. Adding these contracts does not implement those upstream
providers or change user enablement preferences.

### Discover the helper

Helper 0.7.1 adds an additive `capabilities` array to version and snapshot JSON,
retaining protocol version 1. Existing frontends requiring 0.7.0 remain compatible.
A provider should check both protocol version and the capabilities it uses.

```sh
aqueous-config version
aqueous-config snapshot --shell dms
aqueous-config validate --shell dms --request -
aqueous-config apply --shell dms --request -
```

Use JSON stdin for requests. The existing 4 MiB limit and expected-generation
check apply. An old helper without capabilities requires its existing documented
version-specific contract; absence is not permission to silently ignore fields.

| Capability | Existing contract |
| --- | --- |
| `schema_fields` | Snapshot `fields`, categories, defaults, aliases and typed constraints |
| `validate` | Validate the complete request without saving |
| `generation_check` | `expected_generation` prevents saving over external configuration edits |
| `stdin_requests` | `--request -` accepts bounded JSON on stdin |
| `atomic_file_replace` | Individual TOML files are replaced atomically with backups; multi-file saves are not one filesystem transaction |
| `monitor_modes` | Configured monitor changes include mode, position, scale and transform |
| `live_outputs` | Advertised live monitor modes accompany configured/offline monitors |
| `keybinds` | Schema-backed built-ins, unbound actions and custom bindings |
| `window_rules` | Ordered rules and raw configuration access |
| `cursor_sync` | Canonical cursor settings, live compositor update and toolkit adapter reports |
| `typography_sync` | Canonical typography, available fonts/faces and adapter reports |
| `shell_dms` | DMS mode avoids Noctalia writes/reloads |

These are helper capabilities, not a promise that every external toolkit, font,
monitor mode or runtime compositor is available. Inspect individual adapter
reports and live capabilities. For the complete request format, inspect the tested Aqueous helper and plugin
sources (`plugin/helper/` and `dms-plugin/README.md` in the Aqueous repository).
Capture their version/snapshot output as fixtures; reuse the shared helper rather
than introducing a second persistent configuration implementation.

### Preview, Apply and conflict handling

1. Obtain a fresh snapshot and retain its generation with the draft.
2. Stage typed or raw edits. Resolve conflicts between them before validation.
3. Validate the complete intended request.
4. Apply through the helper with the retained `expected_generation`.
5. Read the response and observe the resulting compositor state separately.

The helper does not offer a new persistent display-preview API. A DMS provider
can preview connected displays using existing wlr output management: test the
configuration, retain the live configuration, apply the candidate, and offer
Keep/Revert. Propagate the actual asynchronous apply result. Persist only after
Keep through the helper. A successful file save does not by itself prove that a
physical monitor accepted the configuration; report subsequent runtime failures.

Revert a preview only if the current live configuration still matches that
provider's candidate. If another tool changed it, show a conflict instead of
restoring an obsolete snapshot over newer state. Hotplug and configuration reload
also require a fresh snapshot. Preserve offline entries, EDID identities, custom
modes and fractional refresh rates. DPMS and automatic battery refresh changes
are runtime policy, not changes to canonical preferences.

On stale generation, retain the draft and ask the user to reload/reconcile it.
On uncertain apply timeout, inspect saved state before retrying. On toolkit sync
failure after a successful canonical save, show partial success and use the
existing explicit retry flags (`sync_cursor`, `sync_typography`). Do not overwrite
TOML directly from QML or add a second serializer in DMS core.

### Ownership with multiple frontends

Aqueous TOML is canonical. Both the plugin and an upstream provider may edit it
through the same generation contract; opening either UI does not authorize an
automatic rewrite. Keep DMS-specific typography adaptation in the active DMS
frontend. Do not have two background color/font/cursor synchronizers repeatedly
writing each other's output. Automatic synchronization should be explicitly owned
by one enabled provider; manual Apply remains available through either UI.

The existing plugin maps Aqueous typography into DMS family, weight and scale.
Exact face/slant/width and separately scaled bars are partially represented;
retain that reporting. Cursor control updates the compositor and supported launch
paths, while existing clients that supply cursor surfaces retain their own policy.
The portal plugin has a separate purpose and lifecycle; do not couple screen
sharing to settings-provider enablement.

### Frame reservations and appearance

At audited DMS commit `59a03f450dbf5ae5dd8aa2cd301b89d9293c68a3`,
`Modules/Frame/FrameExclusions.qml` creates one thin layer-shell surface per frame
edge using namespace `dms:frame-exclusion` and a positive exclusive zone. Aqueous's
existing layer-shell arrangement subtracts those reservations from the usable
output area and releases them when the client disappears.

The isolated shell integration test maps all four edge reservations, verifies
width/height shrink by the sum of opposite edges, kills the client, and verifies
full restoration. Therefore this implementation adds no second margin lease.
The normal Wayland resource lifetime already provides the needed lease. Keep
configured Aqueous gaps separate; do not reserve the same frame edge twice.
Physical mixed-scale rendering and the full upstream connected-mode UI remain
release checks.

Use ordered `[[layer]]` rules in `rules.toml` for explicit layer namespaces. The
first match wins. A frame exclusion is an invisible reservation and should not
receive blur. For example, place this before any intentional broader DMS rule:

```toml
[[layer]]
namespace = "dms:frame-exclusion"
blur = false
blur_popups = false
```

Inspect `aqueousctl scene` to identify actual visible DMS surface namespaces on
the target version, then add exact rules for those surfaces where blur is desired.
Do not blanket-match every Quickshell application. For ordinary DMS toplevel
windows, inspect `aqueousctl windows --json` or `inspect --rule` and match the
actual application identity. No user appearance configuration is installed or
rewritten by the shell API implementation.

### Evidence and remaining upstream work

The helper's existing tests cover generation conflicts, validation, raw/typed
writes, monitor modes and adapter retries. The 0.7.1 change adds discovery metadata;
it does not replace those paths. The [DMS implementation plan](#dms-plan)
separates native DMS settings providers and its asynchronous output-apply result
fix. Those changes belong upstream and are not prerequisites for the local
Aqueous Settings plugin.

<a id="json-schema"></a>

## Complete JSON batch schema

If a tooling workflow needs a separate schema file, extract the following code
block verbatim as `aqueous-shell-v1.schema.json`. It is embedded here in full.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Aqueous shell JSON batch schema 1",
  "type": "object",
  "required": [
    "schema",
    "session",
    "sequence",
    "base_sequence",
    "type",
    "upsert",
    "removed"
  ],
  "properties": {
    "schema": {
      "const": 1
    },
    "session": {
      "type": "string",
      "pattern": "^[0-9a-f]{32}$"
    },
    "sequence": {
      "type": "string",
      "pattern": "^[0-9]+$"
    },
    "base_sequence": {
      "type": [
        "string",
        "null"
      ],
      "pattern": "^[0-9]+$"
    },
    "type": {
      "enum": [
        "snapshot",
        "delta"
      ]
    },
    "upsert": {
      "type": "array",
      "items": {
        "oneOf": [
          {
            "$ref": "#/$defs/output"
          },
          {
            "$ref": "#/$defs/workspace"
          },
          {
            "$ref": "#/$defs/window"
          },
          {
            "$ref": "#/$defs/seat"
          },
          {
            "$ref": "#/$defs/keyboard"
          },
          {
            "$ref": "#/$defs/keyboard_device"
          },
          {
            "$ref": "#/$defs/session"
          }
        ]
      }
    },
    "removed": {
      "type": "array",
      "items": {
        "type": "string",
        "pattern": "^(output|workspace|window|seat|keyboard|keyboard_device|session):.+"
      },
      "uniqueItems": true
    }
  },
  "allOf": [
    {
      "if": {
        "properties": {
          "type": {
            "const": "snapshot"
          }
        }
      },
      "then": {
        "properties": {
          "base_sequence": {
            "type": "null"
          },
          "removed": {
            "maxItems": 0
          }
        }
      },
      "else": {
        "properties": {
          "base_sequence": {
            "type": "string"
          }
        }
      }
    }
  ],
  "$defs": {
    "output": {
      "type": "object",
      "required": [
        "kind",
        "id",
        "name",
        "bounds",
        "usable_bounds",
        "scale",
        "transform",
        "active_workspace",
        "enabled",
        "powered"
      ],
      "properties": {
        "kind": {
          "const": "output"
        },
        "id": {
          "type": "string",
          "minLength": 1
        },
        "name": {
          "type": "string"
        },
        "bounds": {
          "type": "object",
          "required": [
            "x",
            "y",
            "width",
            "height"
          ],
          "properties": {
            "x": {
              "type": "integer"
            },
            "y": {
              "type": "integer"
            },
            "width": {
              "type": "integer"
            },
            "height": {
              "type": "integer"
            }
          }
        },
        "usable_bounds": {
          "type": "object",
          "required": [
            "x",
            "y",
            "width",
            "height"
          ],
          "properties": {
            "x": {
              "type": "integer"
            },
            "y": {
              "type": "integer"
            },
            "width": {
              "type": "integer"
            },
            "height": {
              "type": "integer"
            }
          }
        },
        "scale": {
          "type": "number"
        },
        "transform": {
          "type": "string"
        },
        "active_workspace": {
          "type": [
            "string",
            "null"
          ]
        },
        "enabled": {
          "type": "boolean"
        },
        "powered": {
          "type": "boolean"
        }
      }
    },
    "workspace": {
      "type": "object",
      "required": [
        "kind",
        "id",
        "output",
        "name",
        "number",
        "active",
        "urgent"
      ],
      "properties": {
        "kind": {
          "const": "workspace"
        },
        "id": {
          "type": "string",
          "minLength": 1
        },
        "output": {
          "type": "string",
          "minLength": 1
        },
        "name": {
          "type": "string"
        },
        "number": {
          "type": "integer",
          "minimum": 1
        },
        "active": {
          "type": "boolean"
        },
        "urgent": {
          "type": "boolean"
        }
      }
    },
    "window": {
      "type": "object",
      "required": [
        "kind",
        "id",
        "backend",
        "app_id",
        "class",
        "title",
        "workspace",
        "output",
        "geometry",
        "outer_geometry",
        "layout",
        "focused",
        "visible",
        "floating",
        "minimized",
        "maximized",
        "fullscreen",
        "skip_taskbar",
        "skip_switcher",
        "always_above",
        "always_below",
        "snapped",
        "fixed_position",
        "can_minimize",
        "can_maximize",
        "can_activate"
      ],
      "properties": {
        "kind": {
          "const": "window"
        },
        "id": {
          "type": "string",
          "minLength": 1
        },
        "backend": {
          "enum": [
            "xdg",
            "xwayland"
          ]
        },
        "app_id": {
          "type": [
            "string",
            "null"
          ]
        },
        "class": {
          "type": [
            "string",
            "null"
          ]
        },
        "title": {
          "type": [
            "string",
            "null"
          ]
        },
        "workspace": {
          "type": [
            "string",
            "null"
          ]
        },
        "output": {
          "type": [
            "string",
            "null"
          ]
        },
        "geometry": {
          "type": "object",
          "required": [
            "x",
            "y",
            "width",
            "height"
          ],
          "properties": {
            "x": {
              "type": "integer"
            },
            "y": {
              "type": "integer"
            },
            "width": {
              "type": "integer"
            },
            "height": {
              "type": "integer"
            }
          }
        },
        "outer_geometry": {
          "type": "object",
          "required": [
            "x",
            "y",
            "width",
            "height"
          ],
          "properties": {
            "x": {
              "type": "integer"
            },
            "y": {
              "type": "integer"
            },
            "width": {
              "type": "integer"
            },
            "height": {
              "type": "integer"
            }
          }
        },
        "layout": {
          "type": "string"
        },
        "focused": {
          "type": "boolean"
        },
        "visible": {
          "type": "boolean"
        },
        "floating": {
          "type": "boolean"
        },
        "minimized": {
          "type": "boolean"
        },
        "maximized": {
          "type": "boolean"
        },
        "fullscreen": {
          "type": "boolean"
        },
        "skip_taskbar": {
          "type": "boolean"
        },
        "skip_switcher": {
          "type": "boolean"
        },
        "always_above": {
          "type": "boolean"
        },
        "always_below": {
          "type": "boolean"
        },
        "snapped": {
          "type": "boolean"
        },
        "fixed_position": {
          "type": "boolean"
        },
        "can_minimize": {
          "type": "boolean"
        },
        "can_maximize": {
          "type": "boolean"
        },
        "can_activate": {
          "type": "boolean"
        }
      }
    },
    "seat": {
      "type": "object",
      "required": [
        "kind",
        "id",
        "output",
        "window",
        "focus_kind",
        "keyboard"
      ],
      "properties": {
        "kind": {
          "const": "seat"
        },
        "id": {
          "type": "string",
          "minLength": 1
        },
        "output": {
          "type": [
            "string",
            "null"
          ]
        },
        "window": {
          "type": [
            "string",
            "null"
          ]
        },
        "focus_kind": {
          "enum": [
            "window",
            "shell_surface",
            "layer_surface",
            "override_redirect",
            "lock_surface",
            "none"
          ]
        },
        "keyboard": {
          "type": [
            "string",
            "null"
          ]
        }
      }
    },
    "keyboard": {
      "type": "object",
      "required": [
        "kind",
        "id",
        "seat",
        "layouts",
        "index"
      ],
      "properties": {
        "kind": {
          "const": "keyboard"
        },
        "id": {
          "type": "string",
          "minLength": 1
        },
        "seat": {
          "type": "string",
          "minLength": 1
        },
        "layouts": {
          "type": "array",
          "items": {
            "type": "string"
          }
        },
        "index": {
          "type": "integer",
          "minimum": 0
        }
      }
    },
    "keyboard_device": {
      "type": "object",
      "required": [
        "kind",
        "id",
        "name",
        "seat",
        "group",
        "virtual"
      ],
      "properties": {
        "kind": {
          "const": "keyboard_device"
        },
        "id": {
          "type": "string",
          "minLength": 1
        },
        "name": {
          "type": [
            "string",
            "null"
          ]
        },
        "seat": {
          "type": "string",
          "minLength": 1
        },
        "group": {
          "type": [
            "string",
            "null"
          ]
        },
        "virtual": {
          "type": "boolean"
        }
      }
    },
    "session": {
      "type": "object",
      "required": [
        "kind",
        "id",
        "locked",
        "default_seat",
        "overview_output",
        "overview_window"
      ],
      "properties": {
        "kind": {
          "const": "session"
        },
        "id": {
          "type": "string",
          "minLength": 1
        },
        "locked": {
          "type": "boolean"
        },
        "default_seat": {
          "type": [
            "string",
            "null"
          ]
        },
        "overview_output": {
          "type": [
            "string",
            "null"
          ]
        },
        "overview_window": {
          "type": [
            "string",
            "null"
          ]
        }
      }
    }
  }
}
```

<a id="wayland-xml"></a>

## Complete Wayland protocol XML

If generating native bindings, extract the following block verbatim as
`aqueous-shell-v1.xml`. Preserve its copyright and license declaration. Its
`aqueous-shell-v1.md` reference describes the shell contract embedded above.
The imported ext-workspace interface is provided by the standard
`ext-workspace-v1` protocol; use the target build's protocol dependency.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<protocol name="aqueous_shell_v1">
  <copyright>SPDX-FileCopyrightText: © 2026 Seafoam Labs
SPDX-License-Identifier: MIT</copyright>
  <description summary="Aqueous shell state and typed policy operations">
    Privileged same-session shell interface. JSON schema 1 is documented in
    aqueous-shell-v1.md. IDs are opaque strings scoped to the session token.
    State is committed policy state, not animation frame geometry. Clients
    acknowledge each bounded batch before another is sent. Intermediate states
    may be coalesced; base_sequence identifies the state to which a delta applies.
  </description>
  <interface name="aqueous_shell_manager_v1" version="1">
    <enum name="action">
      <entry name="window_activate" value="0"/>
      <entry name="window_close" value="1"/>
      <entry name="window_minimized" value="2"/>
      <entry name="window_maximized" value="3"/>
      <entry name="window_fullscreen" value="4"/>
      <entry name="window_move_workspace" value="5"/>
      <entry name="window_move_output" value="6"/>
      <entry name="workspace_activate" value="7"/>
      <entry name="workspace_rename" value="8"/>
      <entry name="session_exit" value="9"/>
      <entry name="keyboard_set" value="10"/>
      <entry name="keyboard_next" value="11"/>
      <entry name="overview_show" value="12"/>
      <entry name="overview_hide" value="13"/>
      <entry name="overview_toggle" value="14"/>
    </enum>
    <enum name="status">
      <entry name="applied" value="0"/>
      <entry name="accepted" value="1"/>
      <entry name="invalid" value="2"/>
      <entry name="not_found" value="3"/>
      <entry name="locked" value="4"/>
      <entry name="unsupported" value="5"/>
      <entry name="busy" value="6"/>
      <entry name="ambiguous_seat" value="7"/>
      <entry name="unavailable" value="8"/>
    </enum>
    <request name="destroy" type="destructor"/>
    <request name="subscribe">
      <description summary="request an initial snapshot and subsequent changes">
        May be sent once. The server sends at most one unacknowledged batch.
      </description>
    </request>
    <request name="ack">
      <arg name="serial" type="uint"/>
    </request>
    <request name="command">
      <description summary="perform a typed operation">
        One outstanding command per object. Empty strings select documented
        defaults. Targets are opaque window/workspace/group IDs; output values
        are connector names. State values are true/false. Strings are bounded
        to 1024 bytes. Failures are recoverable result events. Window and session
        mutations are unavailable while locked or under external or comparison policy.
      </description>
      <arg name="request_id" type="uint"/>
      <arg name="action" type="uint" enum="action"/>
      <arg name="target" type="string"/>
      <arg name="seat" type="string"/>
      <arg name="value" type="string"/>
    </request>
    <request name="identify_workspace">
      <arg name="request_id" type="uint"/>
      <arg name="workspace" type="object" interface="ext_workspace_handle_v1"/>
    </request>
    <event name="capabilities">
      <arg name="json" type="string"/>
    </event>
    <event name="begin">
      <arg name="serial" type="uint"/>
    </event>
    <event name="data">
      <description summary="UTF-8 JSON batch fragment">
        Concatenate fragments until done. At most 4 MiB per complete batch.
        A fragment may split a UTF-8 codepoint; parse only the complete batch.
      </description>
      <arg name="bytes" type="array"/>
    </event>
    <event name="done">
      <arg name="serial" type="uint"/>
    </event>
    <event name="result">
      <arg name="request_id" type="uint"/>
      <arg name="status" type="uint" enum="status"/>
      <arg name="sequence" type="string"/>
    </event>
    <event name="workspace_id">
      <arg name="request_id" type="uint"/>
      <arg name="id" type="string" summary="empty if removed"/>
    </event>
  </interface>
</protocol>
```
